import Foundation
import Testing
@testable import SlateTermCore

@Test func presenceOriginRoundTripsAndRequiresAHome() throws {
    let origin = try PresenceOrigin(instanceID: "app-1", sessionID: "session-1")
    let actor = try PresenceActor(name: "claude", home: "p1", origin: origin)
    let metadata = try RPCMetadata(actor: actor)
    #expect(try JSONDecoder().decode(RPCMetadata.self, from: JSONEncoder().encode(metadata)) == metadata)
    #expect(throws: PresenceError.self) { try PresenceActor(name: "claude", origin: origin) }
    #expect(throws: PresenceError.self) { try PresenceOrigin(instanceID: "", sessionID: "session-1") }
    #expect(throws: PresenceError.self) { try PresenceOrigin(instanceID: "app-1", sessionID: "bad session") }
}

@Test func differentTerminalSessionsNeverMergeOrReleaseEachOthersHolds() throws {
    let first = try PresenceActor(name: "claude", home: "p1", origin: PresenceOrigin(instanceID: "app", sessionID: "old"))
    let replacement = try PresenceActor(name: "claude", home: "p1", origin: PresenceOrigin(instanceID: "app", sessionID: "new"))
    var tracker = PresenceTracker()
    let old = tracker.hold(actor: first, pane: "p2", seconds: 60, now: 0).0
    let new = tracker.hold(actor: replacement, pane: "p2", seconds: 60, now: 1).0
    #expect(old?.id != new?.id)
    #expect(tracker.records.map(\.origin) == [first.origin, replacement.origin])
    let released = tracker.release(actor: replacement, pane: "p2", now: 2)
    #expect(released)
    #expect(tracker.records.first?.isLeased == true)
    #expect(tracker.records.last?.isLeased == false)
}

@Test func malformedPresenceOriginsAreNotSilentlyDiscarded() throws {
    for origin in [JSONValue.null, .object([:]), .object(["instanceId": .string("app"), "sessionId": .string("s"), "extra": .bool(true)])] {
        let bytes = try JSONEncoder().encode(JSONValue.object([
            "version": .integer(1), "actor": .object(["name": .string("claude"), "home": .string("p1"), "origin": origin])
        ]))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RPCMetadata.self, from: bytes) }
    }
}
