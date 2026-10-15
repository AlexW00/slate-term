import Foundation

/// A bounded value-type journal. Callers provide trusted source identities and own synchronization.
/// Byte limits measure compact JSONEncoder output plus any explicitly reserved delivery metadata.
/// The default reservation is zero for existing callers; causation-aware hosts reserve before admission.
public struct EventJournal: Sendable {
    public static let maximumRetainedEvents = 1_024
    public static let maximumRetainedBytes = 2_097_152
    public static let maximumEventBytes = 16_384
    public static let maximumBatchBytes = 524_288
    public static let maximumBatchEvents = 128
    public static let maximumDeliveryMetadataBytes = 128

    public let epoch: UUID
    public var cursor: String { EventCursor(epoch: epoch, sequence: sequence).description }

    private let maximumEvents: Int
    private let maximumBytes: Int
    private let reservedDeliveryBytes: Int
    private let timestampMillis: @Sendable () -> Int64
    private var sequence: UInt64 = 0
    private var retained: [StoredEvent] = []
    private var retainedBytes = 0

    public init(
        maximumEvents: Int = EventJournal.maximumRetainedEvents,
        maximumBytes: Int = EventJournal.maximumRetainedBytes,
        epoch: UUID = UUID(),
        reservedDeliveryBytes: Int = 0,
        timestampMillis: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) throws {
        guard (1...Self.maximumRetainedEvents).contains(maximumEvents) else {
            throw EventJournalError.invalidCapacity(name: "maximumEvents", value: maximumEvents)
        }
        guard (1...Self.maximumRetainedBytes).contains(maximumBytes) else {
            throw EventJournalError.invalidCapacity(name: "maximumBytes", value: maximumBytes)
        }
        guard (0...Self.maximumDeliveryMetadataBytes).contains(reservedDeliveryBytes) else {
            throw EventJournalError.invalidCapacity(name: "reservedDeliveryBytes", value: reservedDeliveryBytes)
        }
        self.maximumEvents = maximumEvents
        self.maximumBytes = maximumBytes
        self.reservedDeliveryBytes = reservedDeliveryBytes
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
        targetInstanceId: String? = nil,
        targetService: ServiceEventRecipient? = nil,
        lineage: OperationLineage? = nil
    ) throws -> WorkspaceEvent {
        let topic = try EventTopic(topic)
        let source = try source.checked()
        guard !topic.value.hasPrefix("host.") || source == .host else {
            throw EventJournalError.reservedTopic(topic.value)
        }
        if let targetInstanceId, !validEventIdentity(targetInstanceId) {
            throw EventJournalError.invalidTargetInstanceId
        }
        guard targetInstanceId == nil || targetService == nil else { throw EventJournalError.invalidServiceRecipient }
        guard sequence < UInt64.max else { throw EventJournalError.sequenceExhausted }
        let next = sequence + 1
        let event = WorkspaceEvent(
            cursor: EventCursor(epoch: epoch, sequence: next).description,
            sequence: next, topic: topic.value, timestampMillis: timestampMillis(),
            source: source, tab: tab, pane: pane, targetInstanceId: targetInstanceId, targetService: targetService, payload: payload
        )
        let encodedBytes: Int
        do { encodedBytes = try JSONEncoder().encode(event).count + reservedDeliveryBytes }
        catch { throw EventJournalError.invalidPayload }
        guard encodedBytes <= Self.maximumEventBytes else {
            throw EventJournalError.eventTooLarge(encodedBytes: encodedBytes, maximumBytes: Self.maximumEventBytes)
        }
        // Small test capacities must not accept an event only to immediately discard it.
        guard encodedBytes <= maximumBytes else {
            throw EventJournalError.eventExceedsRetentionCapacity(encodedBytes: encodedBytes, maximumBytes: maximumBytes)
        }

        sequence = next
        retained.append(StoredEvent(event: event, encodedBytes: encodedBytes, lineage: lineage))
        retainedBytes += encodedBytes
        while retained.count > maximumEvents || retainedBytes > maximumBytes {
            retainedBytes -= retained.removeFirst().encodedBytes
        }
        return event
    }

    /// Atomically preflight an operation's facts. Rejection cannot consume IDs or evict history.
    /// Copying the journal lets a host prepare a candidate before assigning its live model.
    @discardableResult
    public mutating func appendBatch(_ publications: [EventPublication]) throws -> [WorkspaceEvent] {
        var candidate = self
        let events = try publications.map { publication in
            try candidate.append(topic: publication.topic, payload: publication.payload, source: publication.source,
                                 tab: publication.tab, pane: publication.pane, targetInstanceId: publication.targetInstanceId,
                                 targetService: publication.targetService, lineage: publication.lineage)
        }
        self = candidate
        return events
    }

    /// Host-only lineage is not encoded in an event. Snapshot it alongside a returned batch
    /// before yielding, because another publication may evict its retained record.
    public func lineage(for cursor: String) -> OperationLineage? {
        guard let parsed = try? EventCursor(parsing: cursor), parsed.epoch == epoch else { return nil }
        guard let first = retained.first?.event.sequence, parsed.sequence >= first, parsed.sequence <= sequence else { return nil }
        return retained[Int(parsed.sequence - first)].lineage
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
        // Retained sequences are contiguous; validated cursors are never older than
        // the retained prefix. Quiet readers need not walk that prefix on every publish.
        let start = retained.count - Int(sequence - after)
        for stored in retained.dropFirst(start) {
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
        let lineage: OperationLineage?
    }
}

/// Host-created publication input, not a decodable client authority or wire envelope.
public struct EventPublication: Sendable {
    public let topic: String
    public let payload: JSONValue
    public let source: EventSource
    public let tab: TabID?
    public let pane: PaneID?
    public let targetInstanceId: String?
    public let targetService: ServiceEventRecipient?
    public let lineage: OperationLineage?

    public init(topic: String, payload: JSONValue = .null, source: EventSource = .host,
                tab: TabID? = nil, pane: PaneID? = nil, targetInstanceId: String? = nil,
                targetService: ServiceEventRecipient? = nil, lineage: OperationLineage? = nil) {
        self.topic = topic; self.payload = payload; self.source = source
        self.tab = tab; self.pane = pane; self.targetInstanceId = targetInstanceId
        self.targetService = targetService; self.lineage = lineage
    }
}

/// Codable is for journal output, not an authority to select a caller's source in the host.
public enum EventSource: Equatable, Sendable, Codable {
    case host, client
    case plugin(type: String, instanceId: String)
    case service(pluginID: String, recipient: ServiceEventRecipient)

    private enum Keys: String, CodingKey { case kind, type, instanceId, pluginId, serviceId, generation }

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
        case "service":
            try requireEventKeys(decoder, allowed: ["kind", "pluginId", "serviceId", "generation"])
            self = try EventSource.service(pluginID: values.decode(String.self, forKey: .pluginId),
                recipient: ServiceEventRecipient(serviceID: values.decode(String.self, forKey: .serviceId),
                    generation: values.decode(String.self, forKey: .generation))).checked()
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
        case .service(let plugin, let recipient):
            try values.encode("service", forKey: .kind)
            try values.encode(plugin, forKey: .pluginId)
            try values.encode(recipient.serviceID, forKey: .serviceId)
            try values.encode(recipient.generation, forKey: .generation)
        }
    }

    fileprivate func checked() throws -> EventSource {
        if case .plugin(let type, let instanceId) = self,
           !validEventIdentity(type) || !validEventIdentity(instanceId) { throw EventJournalError.invalidSource }
        if case .service(let plugin, _) = self, !validEventIdentity(plugin) { throw EventJournalError.invalidSource }
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
    public let targetService: ServiceEventRecipient?
    public let payload: JSONValue
}

/// Public routing identity, not a credential. Its generation prevents restart delivery leakage.
public struct ServiceEventRecipient: Hashable, Sendable, Codable {
    public let serviceID: String
    public let generation: String
    public init(serviceID: String, generation: String) throws {
        guard ServiceIdentity.opaque(serviceID), ServiceIdentity.opaque(generation) else {
            throw EventJournalError.invalidServiceRecipient
        }
        self.serviceID = serviceID; self.generation = generation
    }
    private enum CodingKeys: String, CodingKey { case serviceID = "serviceId", generation }
    public init(from decoder: any Decoder) throws {
        try requireEventKeys(decoder, allowed: ["serviceId", "generation"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(serviceID: values.decode(String.self, forKey: .serviceID), generation: values.decode(String.self, forKey: .generation))
    }
}

/// A query projection, not a permission tier. Adapters choose defaults; trusted
/// clients may explicitly select all recipients or one target. Causation references
/// remain bound to the actual caller audience regardless of this projection.
public enum EventObserver: Equatable, Sendable {
    case administrator
    case plugin(instanceID: String)
    case service(ServiceEventRecipient)

    public static func selecting(_ value: JSONValue?, default fallback: Self) throws -> Self {
        guard let value else { return fallback }
        if value == .string("all") { return .administrator }
        if let object = value.object {
            if Set(object.keys) == ["instanceId"], let instance = object["instanceId"]?.string, validEventIdentity(instance) {
                return .plugin(instanceID: instance)
            }
            if Set(object.keys) == ["serviceId", "generation"], let service = object["serviceId"]?.string,
               let generation = object["generation"]?.string {
                return .service(try ServiceEventRecipient(serviceID: service, generation: generation))
            }
        }
        throw EventJournalError.invalidFilter("recipient must be all, {instanceId}, or {serviceId,generation}")
    }
}

/// Topics are ORed. Untargeted events with absent tab/pane fields broadcast to scoped recipients.
/// Directed delivery bypasses scope, never topics. The historical `administrator`
/// observer means an all-recipient query; every trusted client may select it.
public struct EventFilter: Equatable, Sendable, Codable {
    public static let all = try! EventFilter()

    public let topics: [String]
    public let tab: TabID?
    public let pane: PaneID?
    public let observer: EventObserver
    public var recipientInstanceId: String? {
        if case .plugin(let instance) = observer { instance } else { nil }
    }
    private let patterns: [TopicPattern]

    public init(topics: [String] = [], tab: TabID? = nil, pane: PaneID? = nil, recipientInstanceId: String? = nil) throws {
        try self.init(topics: topics, tab: tab, pane: pane,
                      observer: recipientInstanceId.map { .plugin(instanceID: $0) } ?? .administrator)
    }

    public init(topics: [String] = [], tab: TabID? = nil, pane: PaneID? = nil, observer: EventObserver) throws {
        patterns = try topics.map { try TopicPattern(parsing: $0) }
        if case .plugin(let instance) = observer, !validEventIdentity(instance) {
            throw EventJournalError.invalidFilter("recipientInstanceId must be nonempty and contain no whitespace or controls")
        }
        self.topics = topics; self.tab = tab; self.pane = pane; self.observer = observer
    }

    private enum Keys: String, CodingKey { case topics, tab, pane, recipientInstanceId, serviceRecipient }

    public init(from decoder: any Decoder) throws {
        try requireEventKeys(decoder, allowed: ["topics", "tab", "pane", "recipientInstanceId", "serviceRecipient"])
        let values = try decoder.container(keyedBy: Keys.self)
        let observer: EventObserver
        if values.contains(.serviceRecipient) {
            guard !values.contains(.recipientInstanceId) else { throw EventJournalError.invalidServiceRecipient }
            observer = .service(try values.decode(ServiceEventRecipient.self, forKey: .serviceRecipient))
        } else {
            observer = try values.decodeIfPresent(String.self, forKey: .recipientInstanceId)
                .map { .plugin(instanceID: $0) } ?? .administrator
        }
        try self.init(
            topics: values.contains(.topics) ? values.decode([String].self, forKey: .topics) : [],
            tab: values.decodeIfPresent(TabID.self, forKey: .tab),
            pane: values.decodeIfPresent(PaneID.self, forKey: .pane), observer: observer
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(topics, forKey: .topics)
        try values.encodeIfPresent(tab, forKey: .tab)
        try values.encodeIfPresent(pane, forKey: .pane)
        try values.encodeIfPresent(recipientInstanceId, forKey: .recipientInstanceId)
        if case .service(let recipient) = observer { try values.encode(recipient, forKey: .serviceRecipient) }
    }

    fileprivate func matches(_ event: WorkspaceEvent) -> Bool {
        guard patterns.isEmpty || patterns.contains(where: { $0.matches(event.topic) }) else { return false }
        if let target = event.targetInstanceId {
            switch observer {
            case .administrator: return true
            case .plugin(let instance): return instance == target
            case .service: return false
            }
        }
        if let target = event.targetService {
            switch observer {
            case .administrator: return true
            case .service(let recipient): return recipient == target
            case .plugin: return false
            }
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
    case invalidServiceRecipient
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

// Shared internally with host-issued causation-reference validation.
struct EventCursor {
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
