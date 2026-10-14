import Foundation
import Testing
@testable import SlateTermCore

@Test func eventJournalOrdersEventsAndStartsNilPollsAtTheHead() throws {
    var journal = try EventJournal(timestampMillis: { 1_234 })
    let beginning = journal.cursor
    let first = try journal.append(topic: "notes.changed", payload: .integer(2))
    let second = try journal.append(topic: "notes.changed", payload: .integer(1), source: .client)
    #expect(first.sequence == 1)
    #expect(second.sequence == 2)
    #expect(first.cursor == "\(journal.epoch.uuidString):1")
    #expect(first.timestampMillis == 1_234)
    #expect(first.source == .host)
    #expect(journal.cursor == second.cursor)
    #expect(try journal.batch().events.isEmpty)
    #expect(try journal.batch().cursor == second.cursor)
    let replay = try journal.batch(after: beginning)
    #expect(replay.events == [first, second])
    #expect(replay.cursor == second.cursor)
    #expect(try journal.batch(after: first.cursor).events == [second])
}

@Test func eventJournalDistinguishesMalformedFutureRestartAndExpiredCursors() throws {
    var journal = try EventJournal(maximumEvents: 2)
    let beginning = journal.cursor
    let first = try journal.append(topic: "notes.changed")
    _ = try journal.append(topic: "notes.changed")
    let third = try journal.append(topic: "notes.changed")
    for value in ["", "1", "not-a-uuid:0", "\(journal.epoch):", "\(journal.epoch):-1", "\(journal.epoch):+1", "\(journal.epoch):01", "\(journal.epoch):1:2", "\(journal.epoch): 1", "\(journal.epoch):18446744073709551616"] {
        #expect(throws: EventJournalError.invalidCursor(value)) { try journal.batch(after: value) }
    }
    #expect(throws: EventJournalError.futureCursor(sequence: 4, head: 3)) {
        try journal.batch(after: "\(journal.epoch):4")
    }
    let other = UUID()
    #expect(throws: EventJournalError.epochMismatch(expected: journal.epoch, actual: other)) {
        try journal.batch(after: "\(other):0")
    }
    #expect(throws: EventJournalError.expiredCursor(sequence: 0, oldestAvailable: 1)) {
        try journal.batch(after: beginning)
    }
    #expect(try journal.batch(after: first.cursor).events.map(\.sequence) == [2, 3])
    #expect(try journal.batch(after: third.cursor).events.isEmpty)
}

@Test func eventJournalEvictsByEncodedBytesAsWellAsCount() throws {
    var sizing = try EventJournal(timestampMillis: { 0 })
    let sample = try sizing.append(topic: "notes.changed", payload: .string(String(repeating: "日", count: 100)))
    let bytes = try JSONEncoder().encode(sample).count
    var journal = try EventJournal(maximumBytes: bytes * 2, timestampMillis: { 0 })
    let beginning = journal.cursor
    let first = try journal.append(topic: sample.topic, payload: sample.payload)
    _ = try journal.append(topic: sample.topic, payload: sample.payload)
    _ = try journal.append(topic: sample.topic, payload: sample.payload)
    #expect(throws: EventJournalError.expiredCursor(sequence: 0, oldestAvailable: 1)) {
        try journal.batch(after: beginning)
    }
    let retained = try journal.batch(after: first.cursor)
    #expect(retained.events.map(\.sequence) == [2, 3])
    #expect(try retained.events.reduce(0) { try $0 + JSONEncoder().encode($1).count } <= bytes * 2)

    var tiny = try EventJournal(maximumBytes: bytes - 1, timestampMillis: { 0 })
    let before = tiny.cursor
    #expect(throws: EventJournalError.eventExceedsRetentionCapacity(encodedBytes: bytes, maximumBytes: bytes - 1)) {
        try tiny.append(topic: sample.topic, payload: sample.payload)
    }
    #expect(tiny.cursor == before)
}

@Test func eventJournalEnforcesDefaultRetentionCount() throws {
    var journal = try EventJournal()
    let beginning = journal.cursor
    let first = try journal.append(topic: "notes.changed")
    for _ in 0..<1_024 { _ = try journal.append(topic: "notes.changed") }
    #expect(throws: EventJournalError.expiredCursor(sequence: 0, oldestAvailable: 1)) {
        try journal.batch(after: beginning)
    }
    #expect(try journal.batch(after: first.cursor).events.count == 128)
}

@Test func eventJournalTopicAndScopeFiltersBroadcastWithoutPrefixCollisions() throws {
    var journal = try EventJournal()
    let beginning = journal.cursor
    let global = try journal.append(topic: "notes.changed")
    let tab = try journal.append(topic: "notes.selection.updated", tab: TabID(1))
    let pane = try journal.append(topic: "notes.changed", tab: TabID(1), pane: PaneID(1))
    _ = try journal.append(topic: "notes.changed", tab: TabID(2), pane: PaneID(2))
    _ = try journal.append(topic: "notes", tab: TabID(1))
    _ = try journal.append(topic: "notes-other.changed", tab: TabID(1))
    let filter = try EventFilter(topics: ["notes.*"], tab: TabID(1), pane: PaneID(1))
    let batch = try journal.batch(after: beginning, filter: filter)
    #expect(batch.events == [global, tab, pane])
    #expect(batch.cursor == journal.cursor)
    #expect(try journal.batch(after: beginning, filter: EventFilter(topics: ["notes.changed"], tab: TabID(1))).events == [global, pane])
    #expect(try journal.batch(after: beginning, filter: EventFilter(topics: ["missing.*"])).events.isEmpty)
    #expect(try journal.batch(after: beginning, filter: EventFilter(topics: ["missing.*"])).cursor == journal.cursor)
}

@Test func eventJournalDirectedDeliveryBypassesScopeButNeverTopicOrRecipient() throws {
    var journal = try EventJournal()
    let beginning = journal.cursor
    let directed = try journal.append(topic: "notes.changed", tab: TabID(2), pane: PaneID(2), targetInstanceId: "a")
    _ = try journal.append(topic: "notes.changed", tab: TabID(1), pane: PaneID(1), targetInstanceId: "b")
    _ = try journal.append(topic: "other.changed", targetInstanceId: "a")
    let broadcast = try journal.append(topic: "notes.changed")
    _ = try journal.append(topic: "notes.changed", tab: TabID(2))
    let scoped = try EventFilter(topics: ["notes.*"], tab: TabID(1), pane: PaneID(1), recipientInstanceId: "a")
    #expect(try journal.batch(after: beginning, filter: scoped).events == [directed, broadcast])
    let administrator = try EventFilter(topics: ["notes.*"])
    #expect(try journal.batch(after: beginning, filter: administrator).events.map(\.sequence) == [1, 2, 4, 5])
    let scopedAdministrator = try EventFilter(topics: ["notes.*"], tab: TabID(1), pane: PaneID(1))
    #expect(try journal.batch(after: beginning, filter: scopedAdministrator).events.map(\.sequence) == [1, 2, 4])
}

@Test func eventJournalCannotSpoofHostTopicsAndRejectsInvalidAppendAtomically() throws {
    var journal = try EventJournal()
    let beginning = journal.cursor
    for source in [EventSource.client, .plugin(type: "notes", instanceId: "a")] {
        #expect(throws: EventJournalError.reservedTopic("host.changed")) {
            try journal.append(topic: "host.changed", source: source)
        }
    }
    for topic in ["", "Notes.changed", ".notes", "notes.", "notes..changed", "notes.*", "notes/changéd", "1notes", String(repeating: "a", count: 129)] {
        #expect(throws: EventJournalError.invalidTopic(topic)) { try journal.append(topic: topic) }
    }
    #expect(throws: EventJournalError.self) {
        try journal.append(topic: "notes.changed", payload: .string(String(repeating: "x", count: 16_384)))
    }
    #expect(throws: EventJournalError.invalidPayload) { try journal.append(topic: "notes.changed", payload: .number(.nan)) }
    #expect(throws: EventJournalError.invalidSource) { try journal.append(topic: "notes.changed", source: .plugin(type: "", instanceId: "a")) }
    #expect(throws: EventJournalError.invalidTargetInstanceId) { try journal.append(topic: "notes.changed", targetInstanceId: "") }
    #expect(journal.cursor == beginning)
    #expect(try journal.batch(after: beginning).events.isEmpty)
    let accepted = try journal.append(topic: "host.pane_split-updated", payload: .object(["source": .string("plugin")]))
    #expect(accepted.sequence == 1)
    #expect(accepted.source == .host)
    #expect(try journal.append(topic: String(repeating: "a", count: 128)).sequence == 2)
}

@Test func eventJournalMeasuresCompleteEncodedEventAtThe16KiBBoundary() throws {
    var journal = try EventJournal(timestampMillis: { 0 })
    let sample = try journal.append(topic: "notes.changed", payload: .string(""))
    let overhead = try JSONEncoder().encode(sample).count
    let boundary = try journal.append(topic: sample.topic, payload: .string(String(repeating: "x", count: 16_384 - overhead)))
    #expect(try JSONEncoder().encode(boundary).count == 16_384)
    let before = journal.cursor
    #expect(throws: EventJournalError.eventTooLarge(encodedBytes: 16_385, maximumBytes: 16_384)) {
        try journal.append(topic: sample.topic, payload: .string(String(repeating: "x", count: 16_385 - overhead)))
    }
    #expect(journal.cursor == before)
    #expect(try journal.append(topic: sample.topic).sequence == 3)
    #expect(throws: EventJournalError.self) {
        try journal.append(topic: sample.topic, payload: .string(String(repeating: "\n", count: 8_192)))
    }
}

@Test func eventJournalCountLimitedBatchesNeverSkipUnreturnedMatchingEvents() throws {
    var journal = try EventJournal()
    let beginning = journal.cursor
    for index in 1...9 {
        _ = try journal.append(topic: index.isMultiple(of: 2) ? "other.changed" : "notes.changed", payload: .integer(index))
    }
    let filter = try EventFilter(topics: ["notes.*"])
    var cursor = beginning
    var sequences: [UInt64] = []
    for expected in [[UInt64(1), 3], [5, 7], [9]] {
        let batch = try journal.batch(after: cursor, filter: filter, limit: 2)
        #expect(batch.events.map(\.sequence) == expected)
        cursor = batch.cursor
        sequences += batch.events.map(\.sequence)
    }
    #expect(sequences == [1, 3, 5, 7, 9])
    #expect(cursor == journal.cursor)
    #expect(try journal.batch(after: cursor, filter: filter, limit: 2).events.isEmpty)
}

@Test func eventJournalDefaultCountLimitCanReplayAcrossMultipleBatches() throws {
    var journal = try EventJournal()
    var cursor = journal.cursor
    for index in 1...260 { _ = try journal.append(topic: "notes.changed", payload: .integer(index)) }
    var sequences: [UInt64] = []
    for count in [128, 128, 4] {
        let batch = try journal.batch(after: cursor)
        #expect(batch.events.count == count)
        sequences += batch.events.map(\.sequence)
        cursor = batch.cursor
    }
    #expect(sequences == (1...260).map { UInt64($0) })
    #expect(cursor == journal.cursor)
}

@Test func eventJournalRejectedAppendsDoNotEvictAFullyRetainedJournal() throws {
    var journal = try EventJournal(maximumEvents: 2)
    let beginning = journal.cursor
    let first = try journal.append(topic: "notes.changed", payload: .string("first"))
    let second = try journal.append(topic: "notes.changed", payload: .string("second"))
    #expect(throws: EventJournalError.self) {
        try journal.append(topic: "notes.changed", payload: .string(String(repeating: "x", count: 16_384)))
    }
    #expect(throws: EventJournalError.invalidPayload) {
        try journal.append(topic: "notes.changed", payload: .object(["nested": .array([.number(.infinity)])]))
    }
    #expect(throws: EventJournalError.reservedTopic("host.changed")) {
        try journal.append(topic: "host.changed", source: .client)
    }
    #expect(journal.cursor == second.cursor)
    #expect(try journal.batch(after: beginning).events == [first, second])
    let third = try journal.append(topic: "notes.changed")
    #expect(third.sequence == 3)
    #expect(try journal.batch(after: first.cursor).events == [second, third])
}

@Test func eventJournalByteLimitedBatchesIncludeEnvelopeAndNeverSkipEvents() throws {
    var journal = try EventJournal()
    let beginning = journal.cursor
    for index in 1...80 {
        _ = try journal.append(topic: "notes.changed", payload: .object([
            "index": .integer(index), "text": .string(String(repeating: "日", count: 5_000)),
        ]))
    }
    var cursor = beginning
    var sequences: [UInt64] = []
    var batchCount = 0
    while cursor != journal.cursor {
        let batch = try journal.batch(after: cursor)
        #expect(!batch.events.isEmpty)
        guard !batch.events.isEmpty else { break }
        #expect(batch.events.count <= 128)
        #expect(try JSONEncoder().encode(batch).count <= 524_288)
        sequences += batch.events.map(\.sequence)
        cursor = batch.cursor
        batchCount += 1
    }
    #expect(batchCount >= 3)
    #expect(sequences == (1...80).map { UInt64($0) })
}

@Test func eventJournalRejectsInvalidFiltersLimitsAndCapacities() throws {
    for pattern in ["*", "notes*", "notes.**", "notes.*.changed", "Notes.*", "notes..*", "", String(repeating: "a", count: 129)] {
        #expect(throws: EventJournalError.self) { try EventFilter(topics: [pattern]) }
    }
    #expect(throws: EventJournalError.self) { try EventFilter(recipientInstanceId: "") }
    let journal = try EventJournal()
    for limit in [Int.min, -1, 0, 129, Int.max] {
        #expect(throws: EventJournalError.invalidLimit(limit)) { try journal.batch(limit: limit) }
    }
    for capacity in [-1, 0, 1_025, Int.max] {
        #expect(throws: EventJournalError.self) { try EventJournal(maximumEvents: capacity) }
    }
    for capacity in [-1, 0, 2_097_153, Int.max] {
        #expect(throws: EventJournalError.self) { try EventJournal(maximumBytes: capacity) }
    }
    for json in [#"{"topics":["*"]}"#, #"{"topic":"notes.changed"}"#, #"{"recipientInstanceId":""}"#, #"{"tab":"t0"}"#, #"{"topics":null}"#] {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EventFilter.self, from: Data(json.utf8)) }
    }
    #expect(try JSONDecoder().decode(EventFilter.self, from: Data("{}".utf8)) == EventFilter())
    #expect(throws: EventJournalError.unknownField("topic")) {
        try JSONDecoder().decode(EventFilter.self, from: Data(#"{"topic":"notes.changed"}"#.utf8))
    }
}

@Test func eventJournalCodableHasStableWireShapesAndRoundTrips() throws {
    var journal = try EventJournal(timestampMillis: { 1_234 })
    let beginning = journal.cursor
    for source in [EventSource.host, .client, .plugin(type: "notes", instanceId: "a")] {
        let value = try JSONValue.encoding(source)
        let expected: JSONValue = switch source {
        case .host: .object(["kind": .string("host")])
        case .client: .object(["kind": .string("client")])
        case .plugin: .object(["kind": .string("plugin"), "type": .string("notes"), "instanceId": .string("a")])
        }
        #expect(value == expected)
        #expect(try JSONDecoder().decode(EventSource.self, from: JSONEncoder().encode(source)) == source)
    }
    let event = try journal.append(topic: "notes.changed", payload: .object(["text": .string("日本"), "null": .null]), source: .plugin(type: "notes", instanceId: "a"), tab: TabID(1), pane: PaneID(2), targetInstanceId: "b")
    #expect(try JSONValue.encoding(event) == .object([
        "cursor": .string(event.cursor), "sequence": .integer(1), "topic": .string("notes.changed"),
        "timestampMillis": .integer(1_234), "source": .object(["kind": .string("plugin"), "type": .string("notes"), "instanceId": .string("a")]),
        "tab": .string("t1"), "pane": .string("p2"), "targetInstanceId": .string("b"), "payload": event.payload,
    ]))
    #expect(try JSONDecoder().decode(WorkspaceEvent.self, from: JSONEncoder().encode(event)) == event)
    let batch = try journal.batch(after: beginning)
    #expect(try JSONValue.encoding(batch) == .object(["cursor": .string(event.cursor), "events": .array([try JSONValue.encoding(event)])]))
    #expect(try JSONDecoder().decode(EventBatch.self, from: JSONEncoder().encode(batch)) == batch)
    let filter = try EventFilter(topics: ["notes.*"], tab: TabID(1), pane: PaneID(2), recipientInstanceId: "b")
    #expect(try JSONDecoder().decode(EventFilter.self, from: JSONEncoder().encode(filter)) == filter)
    let unscoped = try journal.append(topic: "notes.changed")
    #expect(try JSONValue.encoding(unscoped).object?.keys.sorted() == ["cursor", "payload", "sequence", "source", "timestampMillis", "topic"])
    for json in [#"{"kind":"unknown"}"#, #"{"kind":"host","type":"notes"}"#, #"{"kind":"plugin","type":"notes"}"#, #"{"kind":"plugin","type":"notes","instanceId":""}"#] {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EventSource.self, from: Data(json.utf8)) }
    }
}
