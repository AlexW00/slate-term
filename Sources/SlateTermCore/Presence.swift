import Foundation

/// A self-declared agent identity carried in request metadata. It is shown to the
/// user and never used for admission, authorization or routing.
public struct PresenceActor: Equatable, Hashable, Sendable {
    public static let maximumNameLength = 32
    public static let maximumNoteCharacters = 80
    public static let maximumNoteBytes = 320

    public let name: String
    public let note: String?
    /// Pane ID of the terminal the agent runs in. It only disambiguates labels.
    public let home: String?

    public init(name: String, note: String? = nil, home: String? = nil) throws {
        guard Self.isValidName(name) else { throw PresenceError.invalidActor("actor name must be 1–32 ASCII letters, digits, '.', '_', '-' or ':' and start with a letter or digit") }
        let trimmed = note?.trimmingCharacters(in: .whitespaces)
        if let trimmed {
            guard !trimmed.isEmpty, trimmed.count <= Self.maximumNoteCharacters, trimmed.utf8.count <= Self.maximumNoteBytes,
                  !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
                throw PresenceError.invalidActor("note must be 1–80 characters on one line without control characters")
            }
        }
        if let home { guard Self.isValidHome(home) else { throw PresenceError.invalidActor("home must be a pane ID") } }
        self.name = name
        self.note = trimmed
        self.home = home
    }

    public static func isValidName(_ value: String) -> Bool {
        guard (1...maximumNameLength).contains(value.utf8.count), let first = value.utf8.first, isAlphanumeric(first) else { return false }
        return value.utf8.allSatisfy { isAlphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 || $0 == 58 }
    }

    public static func isValidHome(_ value: String) -> Bool {
        (1...32).contains(value.utf8.count) && value.utf8.allSatisfy { isAlphanumeric($0) || $0 == 45 || $0 == 95 }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
    }

    /// Labels and colors group by agent type, so "Claude" and "claude" match.
    public var key: String { name.lowercased() }

    init(json: JSONValue) throws {
        guard let fields = json.object, Set(fields.keys).isSubset(of: ["name", "note", "home"]),
              let name = fields["name"]?.string,
              fields["note"] == nil || fields["note"]?.string != nil,
              fields["home"] == nil || fields["home"]?.string != nil else {
            throw PresenceError.invalidActor("actor must be an object with name and optional note and home strings")
        }
        try self.init(name: name, note: fields["note"]?.string, home: fields["home"]?.string)
    }

    var json: JSONValue {
        var fields: [String: JSONValue] = ["name": .string(name)]
        if let note { fields["note"] = .string(note) }
        if let home { fields["home"] = .string(home) }
        return .object(fields)
    }
}

public enum PresenceError: Error, Equatable, CustomStringConvertible {
    case invalidActor(String)
    public var description: String {
        switch self { case .invalidActor(let message): message }
    }
}

/// What an agent is doing to a pane, derived from the public method it called.
public enum PresenceAction: String, Sendable, Codable {
    case read, write, run, wait, navigate, eval, command, hold

    /// Only methods that act on one pane show presence. Workspace metadata reads,
    /// settings and events never do, even when the CLI adds an inherited pane.
    public static func forMethod(_ method: String, commandID: String? = nil) -> Self? {
        switch method {
        case "terminal.capture", "panes.capture", "web.snapshot", "web.screenshot", "browser.snapshot", "browser.screenshot":
            return .read
        case "terminal.send", "terminal.key", "panes.send", "web.click", "web.fill", "web.select", "web.scroll", "web.focus", "web.key",
             "web.check", "web.setValue", "browser.click", "browser.fill", "browser.select", "browser.scroll":
            return .write
        case "terminal.run": return .run
        case "terminal.wait", "web.wait", "browser.wait": return .wait
        case "browser.navigate": return .navigate
        case "browser.eval": return .eval
        case "command.run":
            guard let commandID, !CommandContract.forCommand(commandID).workspaceIndependent else { return nil }
            return .command
        default: return nil
        }
    }

    /// Long operations show their outcome when they settle.
    var reportsResult: Bool { [.run, .wait, .navigate].contains(self) }
}

/// Element bounds in the pane container's coordinate space, top-left origin.
public struct PresenceRect: Equatable, Sendable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum PresenceResult: Equatable, Sendable {
    case ok(String?)
    case failed(String?)
}

/// One agent's activity on one pane. Repeated calls merge into the same record.
public struct PresenceRecord: Equatable, Sendable {
    public struct LiveCall: Equatable, Sendable {
        public let action: PresenceAction
        public let startedAt: Double
    }
    public let id: String
    public let actor: String
    public let actorKey: String
    public let home: String?
    public let pane: String
    public internal(set) var note: String?
    /// The most recent call's action, or `hold` while leased.
    public internal(set) var action: PresenceAction
    public internal(set) var count: Int
    public internal(set) var startedAt: Double
    /// Calls still in flight, keyed by call number. Overlapping calls stay independent.
    public internal(set) var liveCalls: [Int: LiveCall]
    public internal(set) var holdUntil: Double
    public internal(set) var leaseUntil: Double?
    public internal(set) var leaseSeconds: Double?
    public internal(set) var result: PresenceResult?
    public internal(set) var element: PresenceRect?
    /// Increments for each new call, so the UI can pulse once per action.
    public internal(set) var pulse: Int

    public var isLeased: Bool { leaseUntil != nil }
    public var isLive: Bool { !liveCalls.isEmpty }

    /// Start of the oldest in-flight run, wait or navigation, if any.
    var reportingSince: Double? {
        liveCalls.values.filter { $0.action.reportsResult }.map(\.startedAt).min()
    }
}

/// A record prepared for display, with a disambiguated label.
public struct PresenceDisplay: Equatable, Sendable {
    public let record: PresenceRecord
    public let label: String
    public let elapsed: Double?
}

public struct PresenceTransition: Equatable, Sendable {
    public enum Phase: String, Sendable { case began, ended }
    public let phase: Phase
    public let record: PresenceRecord

    /// Value-free event payload. Notes stay out of the journal; read them with presence.list.
    public var payload: JSONValue {
        var fields: [String: JSONValue] = [
            "activityId": .string(record.id), "phase": .string(phase.rawValue),
            "actionKind": .string(record.action.rawValue),
            "actor": .object(["name": .string(record.actor), "claimed": .bool(true)]),
            "pane": .string(record.pane), "count": .integer(record.count), "leased": .bool(record.isLeased),
        ]
        if phase == .ended, let result = record.result {
            switch result {
            case .ok: fields["result"] = .string("ok")
            case .failed: fields["result"] = .string("failed")
            }
        }
        return .object(fields)
    }
}

/// Pure presence bookkeeping with an injected clock in seconds.
public struct PresenceTracker: Sendable {
    public static let minimumHold = 1.6
    public static let resultHold = 1.3
    /// Calls shorter than this never show a spinner or a result.
    public static let liveThreshold = 0.5
    public static let defaultLeaseSeconds = 60.0
    public static let maximumLeaseSeconds = 600.0
    public static let maximumRecords = 256

    public struct Call: Equatable, Sendable {
        let record: String
        let number: Int
        let action: PresenceAction
        let startedAt: Double
    }

    public private(set) var records: [PresenceRecord] = []
    private var nextID = 0
    private var nextCall = 0

    public init() {}

    /// Starts a call. Returns the call token and any began transition.
    public mutating func begin(actor: PresenceActor, pane: String, action: PresenceAction, now: Double) -> (Call?, [PresenceTransition]) {
        nextCall += 1
        let live = PresenceRecord.LiveCall(action: action, startedAt: now)
        if let index = index(actor: actor, pane: pane) {
            var record = records[index]
            record.count += 1
            record.pulse += 1
            record.liveCalls[nextCall] = live
            record.element = nil
            if !record.isLeased {
                record.action = action
                // A quick read must not erase a run's visible outcome.
                if action.reportsResult { record.result = nil }
                if let note = actor.note { record.note = note }
            } else {
                record.leaseUntil = max(record.leaseUntil ?? now, now + (record.leaseSeconds ?? Self.defaultLeaseSeconds))
            }
            record.holdUntil = max(record.holdUntil, now + Self.minimumHold)
            records[index] = record
            return (Call(record: record.id, number: nextCall, action: action, startedAt: now), [])
        }
        guard records.count < Self.maximumRecords else { return (nil, []) }
        nextID += 1
        let record = PresenceRecord(id: "a\(nextID)", actor: actor.name, actorKey: actor.key, home: actor.home, pane: pane,
                                    note: actor.note, action: action, count: 1, startedAt: now, liveCalls: [nextCall: live],
                                    holdUntil: now + Self.minimumHold, leaseUntil: nil, leaseSeconds: nil, result: nil, element: nil, pulse: 1)
        records.append(record)
        return (Call(record: record.id, number: nextCall, action: action, startedAt: now), [PresenceTransition(phase: .began, record: record)])
    }

    /// Ends a call. Long run/wait/navigate calls keep their outcome on screen briefly.
    public mutating func end(_ call: Call, result: PresenceResult?, element: PresenceRect?, now: Double) {
        guard let index = records.firstIndex(where: { $0.id == call.record }),
              records[index].liveCalls.removeValue(forKey: call.number) != nil else { return }
        var record = records[index]
        // A held tag stays at the pane corner; element frames belong to short calls.
        if let element, !record.isLeased { record.element = element }
        if !record.isLeased, call.action.reportsResult, now - call.startedAt >= Self.liveThreshold, let result {
            record.result = result
            record.holdUntil = max(record.holdUntil, now + Self.resultHold)
        }
        record.holdUntil = max(record.holdUntil, call.startedAt + Self.minimumHold)
        records[index] = record
    }

    /// Keeps a tag up across many short calls until release or the TTL passes.
    public mutating func hold(actor: PresenceActor, pane: String, seconds: Double, now: Double) -> (PresenceRecord?, [PresenceTransition]) {
        let ttl = min(max(1, seconds), Self.maximumLeaseSeconds)
        if let index = index(actor: actor, pane: pane) {
            records[index].leaseUntil = now + ttl
            records[index].leaseSeconds = ttl
            records[index].action = .hold
            records[index].result = nil
            records[index].element = nil
            records[index].pulse += 1
            if let note = actor.note { records[index].note = note }
            return (records[index], [])
        }
        guard records.count < Self.maximumRecords else { return (nil, []) }
        nextID += 1
        let record = PresenceRecord(id: "a\(nextID)", actor: actor.name, actorKey: actor.key, home: actor.home, pane: pane,
                                    note: actor.note, action: .hold, count: 0, startedAt: now, liveCalls: [:],
                                    holdUntil: now + Self.minimumHold, leaseUntil: now + ttl, leaseSeconds: ttl, result: nil, element: nil, pulse: 1)
        records.append(record)
        return (record, [PresenceTransition(phase: .began, record: record)])
    }

    /// Ends a lease. The tag fades out once no call is in flight and the minimum hold has passed.
    @discardableResult
    public mutating func release(actor: PresenceActor, pane: String, now: Double) -> Bool {
        guard let index = index(actor: actor, pane: pane), records[index].isLeased else { return false }
        records[index].leaseUntil = nil
        records[index].leaseSeconds = nil
        return true
    }

    /// Removes finished records and reports their ended transitions.
    public mutating func expire(now: Double) -> [PresenceTransition] {
        var ended: [PresenceTransition] = []
        for index in records.indices {
            if let lease = records[index].leaseUntil, now >= lease { records[index].leaseUntil = nil; records[index].leaseSeconds = nil }
        }
        records.removeAll { record in
            guard !record.isLive, !record.isLeased, now >= record.holdUntil else { return false }
            ended.append(PresenceTransition(phase: .ended, record: record))
            return true
        }
        return ended
    }

    /// Drops every record for panes that no longer exist.
    public mutating func removePanes(notIn panes: Set<String>) -> [PresenceTransition] {
        var ended: [PresenceTransition] = []
        records.removeAll { record in
            guard !panes.contains(record.pane) else { return false }
            ended.append(PresenceTransition(phase: .ended, record: record))
            return true
        }
        return ended
    }

    /// The earliest time a record may end, ignoring records with calls in flight.
    public var nextDeadline: Double? {
        records.filter { !$0.isLive }.map { $0.leaseUntil ?? $0.holdUntil }.min()
    }

    /// True while a tag shows a running elapsed time that needs regular redraws.
    public func hasElapsedDisplay(now: Double) -> Bool {
        records.contains { !$0.isLeased && $0.reportingSince != nil }
    }

    /// Labels gain the home pane only while two sessions of the same agent are active.
    public func display(now: Double) -> [PresenceDisplay] {
        var homes: [String: Set<String>] = [:]
        for record in records { homes[record.actorKey, default: []].insert(record.home ?? "") }
        return records.map { record in
            let ambiguous = (homes[record.actorKey]?.count ?? 0) > 1
            let label = ambiguous ? "\(record.actor) · \(record.home ?? "?")" : record.actor
            let elapsed = record.isLeased ? nil : record.reportingSince.flatMap { now - $0 >= Self.liveThreshold ? now - $0 : nil }
            return PresenceDisplay(record: record, label: label, elapsed: elapsed)
        }
    }

    private func index(actor: PresenceActor, pane: String) -> Int? {
        records.firstIndex { $0.actorKey == actor.key && $0.home == actor.home && $0.pane == pane }
    }
}

/// Stable colors per agent type. Unknown agents hash into a palette that avoids
/// the known colors and the red/green used for results.
public enum PresenceColor {
    public static let known: [String: UInt32] = [
        "claude": 0xFF9466, "codex": 0xB79CFF, "gemini": 0x5EC8F0, "cursor": 0xE6E6E6,
        "copilot": 0x7AA2FF, "amp": 0xF2C94C, "opencode": 0x4FD1C5, "aider": 0x9AD47A,
    ]
    public static let fallback: [UInt32] = [0xF78FB3, 0x6FB7FF, 0xD8A657, 0x8BD5CA, 0xC6A0F6, 0xF5A97F]

    public static func rgb(for actorKey: String) -> UInt32 {
        let base = actorKey.split(separator: ":").first.map(String.init) ?? actorKey
        if let color = known[base] { return color }
        // FNV-1a keeps the color stable across launches; Swift's hashValue is seeded.
        var hash: UInt32 = 2_166_136_261
        for byte in base.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return fallback[Int(hash % UInt32(fallback.count))]
    }
}
