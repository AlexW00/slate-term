import Foundation
import Testing
@testable import SlateTermCore

struct ServiceEventTests {
    @Test func directedDeliveryHasExplicitCrossKindIsolation() throws {
        let service = try ServiceEventRecipient(serviceID: "runtime", generation: "g1")
        let successor = try ServiceEventRecipient(serviceID: "runtime", generation: "g2")
        var journal = try EventJournal()
        let cursor = journal.cursor
        let global = try journal.append(topic: "test.global")
        let page = try journal.append(topic: "test.page", targetInstanceId: "page")
        let own = try journal.append(topic: "test.service", targetService: service)
        let later = try journal.append(topic: "test.successor", targetService: successor)
        #expect(try journal.batch(after: cursor).events == [global, page, own, later])
        #expect(try journal.batch(after: cursor, filter: EventFilter(recipientInstanceId: "page")).events == [global, page])
        #expect(try journal.batch(after: cursor, filter: EventFilter(observer: .service(service))).events == [global, own])
        #expect(try journal.batch(after: cursor, filter: EventFilter(observer: .service(successor))).events == [global, later])
        // Directed delivery bypasses tab scope, never the topic filter.
        #expect(try journal.batch(after: cursor, filter: EventFilter(topics: ["test.service"], tab: TabID(99), observer: .service(service))).events == [own])
        let scanned = try journal.batch(after: cursor, filter: EventFilter(topics: ["test.page"], observer: .service(service)))
        #expect(scanned.events.isEmpty && scanned.cursor == journal.cursor)
    }

    @Test func ambiguousTargetsRejectAtomicallyAndFiltersRoundTrip() throws {
        let recipient = try ServiceEventRecipient(serviceID: "runtime", generation: "g1")
        var journal = try EventJournal()
        let before = journal.cursor
        #expect(throws: EventJournalError.self) {
            try journal.appendBatch([EventPublication(topic: "test.first"),
                EventPublication(topic: "test.bad", targetInstanceId: "page", targetService: recipient)])
        }
        #expect(journal.cursor == before)
        for filter in [try EventFilter(), try EventFilter(recipientInstanceId: "page"), try EventFilter(observer: .service(recipient))] {
            #expect(try JSONDecoder().decode(EventFilter.self, from: JSONEncoder().encode(filter)) == filter)
        }
        let ambiguous = Data(#"{"recipientInstanceId":"page","serviceRecipient":{"serviceId":"runtime","generation":"g1"}}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EventFilter.self, from: ambiguous) }
        #expect(throws: (any Error).self) { try ServiceEventRecipient(serviceID: "", generation: "g1") }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(EventFilter.self, from: Data(#"{"serviceRecipient":null}"#.utf8)) }
    }

    @Test func serviceCausationCannotCrossGenerationsOrPageAudiences() throws {
        let epoch = UUID()
        let recipient = try ServiceEventRecipient(serviceID: "runtime", generation: "g1")
        let audience = CausationAudience.service(epoch: epoch, registrationID: "example.worker", recipient: recipient)
        var journal = try EventJournal(epoch: epoch)
        let event = try journal.append(topic: "test.event")
        var references = try CausationReferences(epoch: epoch)
        let lineage = OperationLineage()
        let token = try references.issue(for: audience, eventCursor: event.cursor, lineage: lineage, now: 0)
        #expect(try references.derive(from: token, audience: audience, now: 1).parentOperationID == lineage.operationID)
        let successor = CausationAudience.service(epoch: epoch, registrationID: "example.worker",
            recipient: try ServiceEventRecipient(serviceID: "runtime", generation: "g2"))
        let page = CausationAudience.plugin(epoch: epoch, registrationID: "example.worker", instanceID: "runtime", viewID: UUID(), documentGeneration: UUID())
        for foreign in [successor, page, .administrative(epoch: epoch)] {
            #expect(throws: OperationAdmissionError.self) { try references.derive(from: token, audience: foreign, now: 2) }
        }
    }
}
