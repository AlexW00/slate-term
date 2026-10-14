import Foundation

/// A bounded value-type journal. Callers provide trusted source identities and own synchronization.
/// Byte limits measure compact JSONEncoder output, including event metadata and the batch envelope.
public struct EventJournal: Sendable {
    public static let maximumRetainedEvents = 1_024
    public static let maximumRetainedBytes = 2_097_152
    public static let maximumEventBytes = 16_384
    public static let maximumBatchBytes = 524_288
    public static let maximumBatchEvents = 128

    public let epoch: UUID
    public var cursor: String { EventCursor(epoch: epoch, sequence: sequence).description }

    private let maximumEvents: Int
    private let maximumBytes: Int
    private let timestampMillis: @Sendable () -> Int64
    private var sequence: UInt64 = 0
    private var retained: [StoredEvent] = []
    private var retainedBytes = 0

    public init(
        maximumEvents: Int = EventJournal.maximumRetainedEvents,
        maximumBytes: Int = EventJournal.maximumRetainedBytes,
        epoch: UUID = UUID(),
        timestampMillis: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) throws {
        guard (1...Self.maximumRetainedEvents).contains(maximumEvents) else {
            throw EventJournalError.invalidCapacity(name: "maximumEvents", value: maximumEvents)
        }
        guard (1...Self.maximumRetainedBytes).contains(maximumBytes) else {
            throw EventJournalError.invalidCapacity(name: "maximumBytes", value: maximumBytes)
        }
        self.maximumEvents = maximumEvents
        self.maximumBytes = maximumBytes
        self.epoch = epoch
        self.timestampMillis = timestampMillis
    }

    /// Rejected appends never consume a sequence or evict retained events.
    @discardableResult
    public mutating func append(
        topic: String,
        payload: JSONValue = .null,
        source: EventSource = .host,
        tab: TabID? = nil,
        pane: PaneID? = nil,
        targetInstanceId: String? = nil
    ) throws -> WorkspaceEvent {
        let topic = try EventTopic(topic)
        let source = try source.checked()
        guard !topic.value.hasPrefix("host.") || source == .host else {
            throw EventJournalError.reservedTopic(topic.value)
        }
        if let targetInstanceId, !validEventIdentity(targetInstanceId) {
            throw EventJournalError.invalidTargetInstanceId
        }
        guard sequence < UInt64.max else { throw EventJournalError.sequenceExhausted }
        let next = sequence + 1
        let event = WorkspaceEvent(
            cursor: EventCursor(epoch: epoch, sequence: next).description,
            sequence: next, topic: topic.value, timestampMillis: timestampMillis(),
            source: source, tab: tab, pane: pane, targetInstanceId: targetInstanceId, payload: payload
        )
        let encodedBytes: Int
        do { encodedBytes = try JSONEncoder().encode(event).count }
        catch { throw EventJournalError.invalidPayload }
        guard encodedBytes <= Self.maximumEventBytes else {
            throw EventJournalError.eventTooLarge(encodedBytes: encodedBytes, maximumBytes: Self.maximumEventBytes)
        }
        // Small test capacities must not accept an event only to immediately discard it.
        guard encodedBytes <= maximumBytes else {
            throw EventJournalError.eventExceedsRetentionCapacity(encodedBytes: encodedBytes, maximumBytes: maximumBytes)
        }

        sequence = next
        retained.append(StoredEvent(event: event, encodedBytes: encodedBytes))
        retainedBytes += encodedBytes
        while retained.count > maximumEvents || retainedBytes > maximumBytes {
            retainedBytes -= retained.removeFirst().encodedBytes
        }
        return event
    }

    /// Nil starts at the current head; an explicit epoch:0 requests replay, subject to retention.
    /// The returned cursor includes scanned nonmatches, but never an unreturned matching event.
    public func batch(
        after: String? = nil,
        filter: EventFilter = .all,
        limit: Int = EventJournal.maximumBatchEvents
    ) throws -> EventBatch {
        guard (1...Self.maximumBatchEvents).contains(limit) else { throw EventJournalError.invalidLimit(limit) }
        let after = try startingSequence(after)
        var scanned = after
        var events: [WorkspaceEvent] = []
        var eventBytes = 0
        // Reserve the largest cursor envelope so scanning nonmatches cannot overflow a full batch.
        let envelopeBytes = try JSONEncoder().encode(EventBatch(
            cursor: EventCursor(epoch: epoch, sequence: UInt64.max).description, events: []
        )).count
        for stored in retained where stored.event.sequence > after {
            let event = stored.event
            if filter.matches(event) {
                let commaBytes = events.isEmpty ? 0 : 1
                guard events.count < limit,
                      envelopeBytes + eventBytes + commaBytes + stored.encodedBytes <= Self.maximumBatchBytes else { break }
                events.append(event)
                eventBytes += commaBytes + stored.encodedBytes
            }
            scanned = event.sequence
        }
        return EventBatch(cursor: EventCursor(epoch: epoch, sequence: scanned).description, events: events)
    }

    private func startingSequence(_ value: String?) throws -> UInt64 {
        guard let value else { return sequence }
        let parsed = try EventCursor(parsing: value)
        guard parsed.epoch == epoch else { throw EventJournalError.epochMismatch(expected: epoch, actual: parsed.epoch) }
        guard parsed.sequence <= sequence else { throw EventJournalError.futureCursor(sequence: parsed.sequence, head: sequence) }
        let oldestAvailable = retained.first.map { $0.event.sequence - 1 } ?? sequence
        guard parsed.sequence >= oldestAvailable else {
            throw EventJournalError.expiredCursor(sequence: parsed.sequence, oldestAvailable: oldestAvailable)
        }
        return parsed.sequence
    }

    private struct StoredEvent: Sendable {
        let event: WorkspaceEvent
        let encodedBytes: Int
    }
}

/// Codable is for journal output, not an authority to select a caller's source in the host.
public enum EventSource: Equatable, Sendable, Codable {
    case host, client
    case plugin(type: String, instanceId: String)

    private enum Keys: String, CodingKey { case kind, type, instanceId }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "host", "client":
            try requireEventKeys(decoder, allowed: ["kind"])
            self = kind == "host" ? .host : .client
        case "plugin":
            try requireEventKeys(decoder, allowed: ["kind", "type", "instanceId"])
            self = try EventSource.plugin(
                type: values.decode(String.self, forKey: .type),
                instanceId: values.decode(String.self, forKey: .instanceId)
            ).checked()
        default: throw EventJournalError.invalidSource
        }
    }

    public func encode(to encoder: any Encoder) throws {
        let source = try checked()
        var values = encoder.container(keyedBy: Keys.self)
        switch source {
        case .host: try values.encode("host", forKey: .kind)
        case .client: try values.encode("client", forKey: .kind)
        case .plugin(let type, let instanceId):
            try values.encode("plugin", forKey: .kind)
            try values.encode(type, forKey: .type)
            try values.encode(instanceId, forKey: .instanceId)
        }
    }

    fileprivate func checked() throws -> EventSource {
        if case .plugin(let type, let instanceId) = self,
           !validEventIdentity(type) || !validEventIdentity(instanceId) { throw EventJournalError.invalidSource }
        return self
    }
}

public struct WorkspaceEvent: Equatable, Sendable, Codable {
    public let cursor: String
    public let sequence: UInt64
    public let topic: String
    public let timestampMillis: Int64
    public let source: EventSource
    public let tab: TabID?
    public let pane: PaneID?
    public let targetInstanceId: String?
    public let payload: JSONValue
}

/// Topics are ORed. Untargeted events with absent tab/pane fields broadcast to scoped recipients.
/// Nil recipientInstanceId monitors all recipients. Directed delivery bypasses scope, never topics.
public struct EventFilter: Equatable, Sendable, Codable {
    public static let all = try! EventFilter()

    public let topics: [String]
    public let tab: TabID?
    public let pane: PaneID?
    public let recipientInstanceId: String?
    private let patterns: [TopicPattern]

    public init(topics: [String] = [], tab: TabID? = nil, pane: PaneID? = nil, recipientInstanceId: String? = nil) throws {
        patterns = try topics.map { try TopicPattern(parsing: $0) }
        if let recipientInstanceId, !validEventIdentity(recipientInstanceId) {
            throw EventJournalError.invalidFilter("recipientInstanceId must be nonempty and contain no whitespace or controls")
        }
        self.topics = topics
        self.tab = tab
        self.pane = pane
        self.recipientInstanceId = recipientInstanceId
    }

    private enum Keys: String, CodingKey { case topics, tab, pane, recipientInstanceId }

    public init(from decoder: any Decoder) throws {
        try requireEventKeys(decoder, allowed: ["topics", "tab", "pane", "recipientInstanceId"])
        let values = try decoder.container(keyedBy: Keys.self)
        try self.init(
            topics: values.contains(.topics) ? values.decode([String].self, forKey: .topics) : [],
            tab: values.decodeIfPresent(TabID.self, forKey: .tab),
            pane: values.decodeIfPresent(PaneID.self, forKey: .pane),
            recipientInstanceId: values.decodeIfPresent(String.self, forKey: .recipientInstanceId)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(topics, forKey: .topics)
        try values.encodeIfPresent(tab, forKey: .tab)
        try values.encodeIfPresent(pane, forKey: .pane)
        try values.encodeIfPresent(recipientInstanceId, forKey: .recipientInstanceId)
    }

    fileprivate func matches(_ event: WorkspaceEvent) -> Bool {
        guard patterns.isEmpty || patterns.contains(where: { $0.matches(event.topic) }) else { return false }
        if let target = event.targetInstanceId {
            return recipientInstanceId == nil || recipientInstanceId == target
        }
        if let tab, let eventTab = event.tab, tab != eventTab { return false }
        if let pane, let eventPane = event.pane, pane != eventPane { return false }
        return true
    }
}

public struct EventBatch: Equatable, Sendable, Codable {
    public let cursor: String
    public let events: [WorkspaceEvent]
}

public enum EventJournalError: Error, Equatable, Sendable {
    case invalidCapacity(name: String, value: Int)
    case invalidTopic(String)
    case reservedTopic(String)
    case invalidSource
    case invalidTargetInstanceId
    case invalidPayload
    case eventTooLarge(encodedBytes: Int, maximumBytes: Int)
    case eventExceedsRetentionCapacity(encodedBytes: Int, maximumBytes: Int)
    case invalidFilter(String)
    case unknownField(String)
    case invalidLimit(Int)
    case invalidCursor(String)
    case epochMismatch(expected: UUID, actual: UUID)
    case futureCursor(sequence: UInt64, head: UInt64)
    /// oldestAvailable is the earliest usable *after* sequence, one before the oldest retained event.
    case expiredCursor(sequence: UInt64, oldestAvailable: UInt64)
    case sequenceExhausted
}

private struct EventCursor {
    let epoch: UUID
    let sequence: UInt64
    var description: String { "\(epoch.uuidString):\(sequence)" }

    init(epoch: UUID, sequence: UInt64) {
        self.epoch = epoch
        self.sequence = sequence
    }

    init(parsing value: String) throws {
        guard (38...57).contains(value.utf8.count) else { throw EventJournalError.invalidCursor(value) }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].utf8.count == 36,
              let epoch = UUID(uuidString: String(parts[0])),
              epoch.uuidString.lowercased() == parts[0].lowercased(),
              !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
              let sequence = UInt64(parts[1]), String(sequence) == parts[1] else {
            throw EventJournalError.invalidCursor(value)
        }
        self.epoch = epoch
        self.sequence = sequence
    }
}

/// ASCII components start with a lowercase letter, followed by lowercase letters, digits, '-' or '_'.
private struct EventTopic {
    let value: String

    init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128 else { throw EventJournalError.invalidTopic(value) }
        var componentStart = true
        for byte in value.utf8 {
            if byte == 46 {
                guard !componentStart else { throw EventJournalError.invalidTopic(value) }
                componentStart = true
            } else if componentStart {
                guard (97...122).contains(byte) else { throw EventJournalError.invalidTopic(value) }
                componentStart = false
            } else {
                guard (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95 else {
                    throw EventJournalError.invalidTopic(value)
                }
            }
        }
        guard !componentStart else { throw EventJournalError.invalidTopic(value) }
        self.value = value
    }
}

private enum TopicPattern: Equatable, Sendable {
    case exact(String), namespace(String)

    init(parsing value: String) throws {
        do {
            guard value.utf8.count <= 128 else { throw EventJournalError.invalidTopic(value) }
            if value.hasSuffix(".*") {
                let topic = try EventTopic(String(value.dropLast(2)))
                self = .namespace(topic.value + ".")
            } else {
                self = .exact(try EventTopic(value).value)
            }
        } catch {
            throw EventJournalError.invalidFilter("Invalid topic pattern: \(value)")
        }
    }

    func matches(_ topic: String) -> Bool {
        switch self {
        case .exact(let value): topic == value
        case .namespace(let prefix): topic.hasPrefix(prefix)
        }
    }
}

private func validEventIdentity(_ value: String) -> Bool {
    !value.isEmpty && !value.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
}

private struct EventKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireEventKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let keys = try decoder.container(keyedBy: EventKey.self).allKeys.map(\.stringValue).sorted()
    if let unknown = keys.first(where: { !allowed.contains($0) }) { throw EventJournalError.unknownField(unknown) }
}
