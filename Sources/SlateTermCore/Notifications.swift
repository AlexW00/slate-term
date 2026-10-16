import Foundation

/// Application policy shared by API, shell completion and OSC requests. No caller can bypass it.
public struct NotificationPolicy: Codable, Equatable, Sendable {
    public enum Banner: String, Codable, CaseIterable, Sendable { case otherPanes = "other_panes", otherApps = "other_apps", off }
    public var automatic = true
    public var minimumSeconds = 30
    public var tools = true
    public var banners: Banner = .otherPanes
    public var sound = false
    public var commandDetails = false
    public init() {}
    enum CodingKeys: String, CodingKey, CaseIterable {
        case automatic, minimumSeconds = "minimum_seconds", tools, banners, sound, commandDetails = "command_details"
    }
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    public init(from decoder: any Decoder) throws {
        self.init()
        let keys = try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)
        guard Set(keys).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw RPCFailure(code: -32602, message: "Unknown notification setting")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? automatic
        minimumSeconds = try c.decodeIfPresent(Int.self, forKey: .minimumSeconds) ?? minimumSeconds
        tools = try c.decodeIfPresent(Bool.self, forKey: .tools) ?? tools
        banners = try c.decodeIfPresent(Banner.self, forKey: .banners) ?? banners
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? sound
        commandDetails = try c.decodeIfPresent(Bool.self, forKey: .commandDetails) ?? commandDetails
        guard (1...86400).contains(minimumSeconds) else {
            throw RPCFailure(code: -32602, message: "notifications.minimum_seconds must be an integer in 1...86400")
        }
    }

    /// A nil reason means the banner may be submitted, subject to OS authorization.
    public func suppression(automatic isAutomatic: Bool, durationNanoseconds: UInt64? = nil,
                            appActive: Bool, sourceFocused: Bool) -> String? {
        if isAutomatic {
            if !automatic { return "automaticDisabled" }
            if (durationNanoseconds ?? 0) < UInt64(minimumSeconds) * 1_000_000_000 { return "belowThreshold" }
        } else if !tools { return "toolsDisabled" }
        if sourceFocused { return "sourceFocused" }
        if banners == .off { return "bannersDisabled" }
        if banners == .otherApps && appActive { return "appActive" }
        return nil
    }
}

public struct NotificationAnchor: Codable, Equatable, Sendable {
    public let paneId: PaneID?
    public let tabId: TabID?
    /// Host-owned content lifetime, never a caller-selected identifier.
    public let lifetime: String?
    public var rateDestination: String {
        if let paneId { return "pane:\(paneId):\(lifetime ?? "")" }
        if let tabId { return "tab:\(tabId)" }
        return "application"
    }
    public func hasSameDestination(as other: Self) -> Bool {
        if paneId != nil || other.paneId != nil { return paneId == other.paneId && lifetime == other.lifetime }
        return tabId == other.tabId
    }
    public init(pane: PaneID? = nil, tab: TabID? = nil, lifetime: String? = nil) {
        paneId = pane; tabId = tab; self.lifetime = lifetime
    }
}

public struct SlateNotification: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let key: String?
    public let source: JSONValue
    public let anchor: NotificationAnchor
    public let automatic: Bool
    public let createdAt: Double
    public var disposition: String
    public var reason: String?
}

/// Outstanding unread notifications only, not durable history. Oldest entries are evicted.
public struct NotificationStore: Sendable {
    public static let capacity = 100
    public static let titleBytes = 256
    public static let bodyBytes = 4096
    public static let keyBytes = 128
    public private(set) var records: [SlateNotification] = []
    private struct Budget: Sendable { var tokens: Double; var updated: Double }
    private var global = Budget(tokens: 10, updated: 0)
    private var budgets: [String: Budget] = [:]
    public init() {}

    public static func text(_ value: String, title: Bool) -> String {
        String(value.unicodeScalars.filter { scalar in
            if !title && scalar == "\n" { return true }
            return !CharacterSet.controlCharacters.contains(scalar)
                && ![0x061c, 0x200b, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e,
                     0x2060, 0x2066, 0x2067, 0x2068, 0x2069, 0xfeff].contains(scalar.value)
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func validate(title: String, body: String, key: String?) throws {
        guard !text(title, title: true).isEmpty, title.utf8.count <= titleBytes, body.utf8.count <= bodyBytes,
              key.map({ !$0.isEmpty && $0.utf8.count <= keyBytes && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) ?? true else {
            throw RPCFailure(code: -32602, message: "Notification requires a nonempty title <=256 UTF-8 bytes, body <=4096 bytes and optional key of 1...128 bytes")
        }
    }

    /// Monotonic seconds supplied by the host. Rate admission is separate from insertion.
    public mutating func admit(source: String, now: Double) -> Bool {
        func refill(_ budget: Budget, rate: Double, capacity: Double) -> Budget {
            Budget(tokens: min(capacity, budget.tokens + max(0, now - budget.updated) * rate), updated: max(now, budget.updated))
        }
        global = refill(global, rate: 5, capacity: 10)
        var local = refill(budgets[source] ?? Budget(tokens: 5, updated: now), rate: 1, capacity: 5)
        guard global.tokens >= 1, local.tokens >= 1 else { return false }
        global.tokens -= 1; local.tokens -= 1
        if budgets[source] == nil, budgets.count >= 128, let oldest = budgets.min(by: { $0.value.updated < $1.value.updated })?.key {
            budgets.removeValue(forKey: oldest)
        }
        budgets[source] = local
        return true
    }

    @discardableResult
    public mutating func insert(title: String, body: String, key: String?, source: JSONValue, anchor: NotificationAnchor,
                                automatic: Bool, now: Double, disposition: String, reason: String?) -> (record: SlateNotification, removed: [String]) {
        var removed: [String] = []
        if let key {
            removed = remove { $0.key == key && $0.source == source && $0.anchor.hasSameDestination(as: anchor) }
        }
        if records.count >= Self.capacity { removed.append(records.removeFirst().id) }
        let record = SlateNotification(id: UUID().uuidString, title: Self.text(title, title: true), body: Self.text(body, title: false),
            key: key, source: source, anchor: anchor, automatic: automatic, createdAt: now, disposition: disposition, reason: reason)
        records.append(record)
        return (record, removed)
    }

    public mutating func updateDelivery(id: String, disposition: String, reason: String?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].disposition = disposition; records[index].reason = reason
    }

    @discardableResult
    public mutating func remove(where predicate: (SlateNotification) -> Bool) -> [String] {
        let ids = records.filter(predicate).map(\.id)
        records.removeAll(where: predicate)
        return ids
    }
}
