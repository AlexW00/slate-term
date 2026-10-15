import Foundation
import Testing
@testable import SlateTermCore

@Test func eventBatchAdmissionRejectsAtomicallyWithoutEvictionOrSequenceConsumption() throws {
    var journal = try EventJournal(maximumEvents: 2)
    let first = try journal.append(topic: "notes.first")
    let head = journal.cursor
    #expect(throws: EventJournalError.self) {
        try journal.appendBatch([
            EventPublication(topic: "notes.second"),
            EventPublication(topic: "notes.third", payload: .string(String(repeating: "x", count: 16_384)))
        ])
    }
    #expect(journal.cursor == head)
    #expect(try journal.batch(after: "\(journal.epoch.uuidString):0").events == [first])
    let accepted = try journal.appendBatch([EventPublication(topic: "notes.second"), EventPublication(topic: "notes.third")])
    #expect(accepted.map(\.sequence) == [2, 3])
    #expect(try journal.batch(after: first.cursor).events == accepted)
}

@Test func deliveryReservationBoundsActualEventAndBatchEnvelopes() throws {
    let epoch = UUID()
    var plain = try EventJournal(epoch: epoch, timestampMillis: { 0 })
    let sample = try plain.append(topic: "notes.changed", payload: .string(""))
    let overhead = try JSONEncoder().encode(sample).count
    var reserved = try EventJournal(epoch: epoch, reservedDeliveryBytes: 128, timestampMillis: { 0 })
    let boundary = try reserved.append(topic: "notes.changed", payload: .string(String(repeating: "x", count: 16_384 - overhead - 128)))
    #expect(try JSONEncoder().encode(boundary).count + 128 == EventJournal.maximumEventBytes)
    var decorated = try #require(JSONValue.encoding(boundary).object)
    decorated["deliveryContext"] = .object(["version": .integer(1), "reference": .string(String(repeating: "a", count: 64))])
    #expect(try JSONEncoder().encode(JSONValue.object(decorated)).count <= EventJournal.maximumEventBytes)
    let head = reserved.cursor
    #expect(throws: EventJournalError.self) {
        try reserved.append(topic: "notes.changed", payload: .string(String(repeating: "x", count: 16_384 - overhead - 127)))
    }
    #expect(reserved.cursor == head)
    for _ in 0..<70 { try reserved.append(topic: "notes.changed", payload: .string(String(repeating: "x", count: 15_000))) }
    let batch = try reserved.batch(after: "\(epoch.uuidString):0")
    let delivered = try #require(JSONValue.encoding(batch).object)
    var actual = delivered
    actual["events"] = .array(try batch.events.map { event in
        var value = try #require(JSONValue.encoding(event).object)
        value["deliveryContext"] = .object(["version": .integer(1), "reference": .string(String(repeating: "a", count: 64))])
        return .object(value)
    })
    #expect(try JSONEncoder().encode(JSONValue.object(actual)).count <= EventJournal.maximumBatchBytes)
    #expect(batch.events.count < 71)
    #expect(try reserved.batch(after: batch.cursor).events.first?.sequence == batch.events.last!.sequence + 1)
}

@Test func privateLineageSurvivesPublicationAndExpiresWithRetainedEvent() throws {
    var journal = try EventJournal(maximumEvents: 1)
    let lineage = OperationLineage()
    let event = try journal.append(topic: "host.workspace.changed", lineage: lineage)
    #expect(journal.lineage(for: event.cursor) == lineage)
    let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
    #expect(!encoded.contains(lineage.rootOperationID.uuidString))
    _ = try journal.append(topic: "notes.next")
    #expect(journal.lineage(for: event.cursor) == nil)
    #expect(journal.lineage(for: "forged") == nil)
}

@Test func deliveryReservationValidatesCapacityAndParticipatesInRetention() throws {
    for bytes in [-1, 129, Int.max] {
        #expect(throws: EventJournalError.invalidCapacity(name: "reservedDeliveryBytes", value: bytes)) {
            try EventJournal(reservedDeliveryBytes: bytes)
        }
    }
    let epoch = UUID()
    var sample = try EventJournal(epoch: epoch, timestampMillis: { 0 })
    let event = try sample.append(topic: "notes.changed")
    let bytes = try JSONEncoder().encode(event).count
    var reserved = try EventJournal(maximumBytes: bytes * 2 + 128, epoch: epoch, reservedDeliveryBytes: 128, timestampMillis: { 0 })
    _ = try reserved.append(topic: "notes.changed")
    _ = try reserved.append(topic: "notes.changed")
    #expect(throws: EventJournalError.expiredCursor(sequence: 0, oldestAvailable: 1)) {
        try reserved.batch(after: "\(epoch.uuidString):0")
    }
}
