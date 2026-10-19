import Foundation
import Testing
@testable import SlateTermCore

private func actor(_ name: String = "claude", note: String? = nil, home: String? = "p1") throws -> PresenceActor {
    try PresenceActor(name: name, note: note, home: home)
}

private func requestBytes(metadata: JSONValue) throws -> Data {
    try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("terminal.capture"),
                                               "params": .object([:]), "metadata": metadata]))
}

@Test func actorMetadataRoundTripsAndStaysOutOfParams() throws {
    let metadata = JSONValue.object(["version": .integer(1), "actor": .object(["name": .string("claude"), "note": .string("reading tests"), "home": .string("p1")])])
    let request = try RPCRequest.decode(requestBytes(metadata: metadata))
    #expect(request.metadata?.actor == (try actor(note: "reading tests")))
    #expect(request.params?.isEmpty == true)
    #expect(try JSONValue.encoding(request).object?["metadata"] == metadata)
}

@Test(arguments: [
    JSONValue.string("claude"), .object([:]), .object(["name": .integer(1)]), .object(["name": .string("")]),
    .object(["name": .string("has space")]), .object(["name": .string("-leading")]), .object(["name": .string(String(repeating: "a", count: 33))]),
    .object(["name": .string("claude"), "note": .string("")]), .object(["name": .string("claude"), "note": .string("two\nlines")]),
    .object(["name": .string("claude"), "note": .string(String(repeating: "x", count: 81))]),
    .object(["name": .string("claude"), "home": .string("p 1")]), .object(["name": .string("claude"), "color": .string("red")]),
]) func malformedActorsRejectTheRequest(_ value: JSONValue) throws {
    let bytes = try requestBytes(metadata: .object(["version": .integer(1), "actor": value]))
    #expect(throws: ProtocolError.self) { try RPCRequest.decode(bytes) }
}

@Test func withoutActorKeepsCauseOrDropsMetadata() throws {
    #expect(try RPCMetadata(actor: actor()).withoutActor == nil)
    #expect(try RPCMetadata(cause: "ref", actor: actor()).withoutActor == (try RPCMetadata(cause: "ref")))
    #expect(try RPCMetadata(cause: "ref").withoutActor == (try RPCMetadata(cause: "ref")))
}

@Test func onlyPaneActingMethodsShowPresence() {
    #expect(PresenceAction.forMethod("terminal.capture") == .read)
    #expect(PresenceAction.forMethod("terminal.run") == .run)
    #expect(PresenceAction.forMethod("web.click") == .write)
    #expect(PresenceAction.forMethod("browser.navigate") == .navigate)
    #expect(PresenceAction.forMethod("command.run", commandID: "pane.zoom") == .command)
    #expect(PresenceAction.forMethod("command.run", commandID: "plugins.panelState.reset") == .command)
    for method in ["context.get", "pane.inspect", "workspace.snapshot", "events.poll", "config.patch", "web.get", "browser.get"] {
        #expect(PresenceAction.forMethod(method) == nil)
    }
    #expect(PresenceAction.forMethod("command.run", commandID: "agents.activity.toggle") == nil)
    #expect(PresenceAction.forMethod("command.run") == nil)
}

@Test func shortCallsHoldForTheMinimumThenEndOnce() throws {
    var tracker = PresenceTracker()
    let (call, began) = tracker.begin(actor: try actor(note: "reading"), pane: "p2", action: .read, now: 10)
    #expect(began.map(\.phase) == [.began])
    tracker.end(try #require(call), result: .ok(nil), element: nil, now: 10.04)
    #expect(tracker.expire(now: 14.99).isEmpty)
    #expect(tracker.records.first?.result == nil, "Short calls never show a result")
    let ended = tracker.expire(now: 15.01)
    #expect(ended.map(\.phase) == [.ended])
    #expect(tracker.records.isEmpty)
    #expect(tracker.expire(now: 20).isEmpty)
}

@Test func repeatedCallsMergeAndExtendTheHold() throws {
    var tracker = PresenceTracker()
    let (first, began) = tracker.begin(actor: try actor(note: "reading"), pane: "p2", action: .read, now: 0)
    tracker.end(try #require(first), result: .ok(nil), element: nil, now: 0.01)
    let (second, again) = tracker.begin(actor: try actor(note: "rereading"), pane: "p2", action: .read, now: 1)
    tracker.end(try #require(second), result: .ok(nil), element: nil, now: 1.01)
    #expect(began.count == 1 && again.isEmpty)
    #expect(tracker.records.count == 1)
    #expect(tracker.records[0].count == 2 && tracker.records[0].note == "rereading" && tracker.records[0].pulse == 2)
    #expect(tracker.expire(now: 5.99).isEmpty)
    #expect(tracker.expire(now: 6.01).count == 1)
}

@Test func callWithoutNoteKeepsThePreviousNote() throws {
    var tracker = PresenceTracker()
    _ = tracker.begin(actor: try actor(note: "reading"), pane: "p2", action: .read, now: 0)
    _ = tracker.begin(actor: try actor(), pane: "p2", action: .write, now: 0.5)
    #expect(tracker.records[0].note == "reading" && tracker.records[0].action == .write)
}

@Test func longRunsStayLiveAndShowTheirResult() throws {
    var tracker = PresenceTracker()
    let (call, _) = tracker.begin(actor: try actor(), pane: "p2", action: .run, now: 0)
    #expect(tracker.expire(now: 30).isEmpty, "A live call never expires")
    #expect(tracker.display(now: 4.2).first?.elapsed == 4.2)
    tracker.end(try #require(call), result: .failed("exit 1"), element: nil, now: 4.2)
    #expect(tracker.records[0].result == .failed("exit 1"))
    #expect(tracker.display(now: 4.3).first?.elapsed == nil)
    #expect(tracker.expire(now: 9.19).isEmpty)
    #expect(tracker.expire(now: 9.21).count == 1)
}

@Test func leasesOutliveCallsUntilReleaseOrTTL() throws {
    var tracker = PresenceTracker()
    let (record, began) = tracker.hold(actor: try actor(note: "triaging"), pane: "p4", seconds: 60, now: 0)
    #expect(record?.isLeased == true && began.count == 1)
    let (call, _) = tracker.begin(actor: try actor(note: "reading a card"), pane: "p4", action: .read, now: 50)
    tracker.end(try #require(call), result: .ok(nil), element: nil, now: 50.1)
    #expect(tracker.records[0].note == "triaging", "Calls inside a lease keep the lease's note")
    #expect(tracker.expire(now: 100).isEmpty, "Calls refresh the lease")
    #expect(tracker.release(actor: try actor(), pane: "p4", now: 101))
    #expect(tracker.expire(now: 101).count == 1)
    _ = tracker.hold(actor: try actor(), pane: "p4", seconds: 5, now: 200)
    #expect(tracker.expire(now: 204).isEmpty)
    #expect(tracker.expire(now: 205.01).count == 1)
    #expect(!tracker.release(actor: try actor(), pane: "p4", now: 300))
}

@Test func leaseTTLIsClamped() throws {
    var tracker = PresenceTracker()
    let (record, _) = tracker.hold(actor: try actor(), pane: "p4", seconds: 10_000, now: 0)
    #expect(record?.leaseUntil == PresenceTracker.maximumLeaseSeconds)
}

@Test func agentsAndSessionsGetSeparateRecordsAndLabelsDisambiguateOnlyWhenNeeded() throws {
    var tracker = PresenceTracker()
    _ = tracker.begin(actor: try actor(home: "p1"), pane: "p5", action: .read, now: 0)
    _ = tracker.begin(actor: try actor("codex", home: "p9"), pane: "p5", action: .read, now: 0)
    #expect(tracker.display(now: 0).map(\.label) == ["claude", "codex"])
    _ = tracker.begin(actor: try actor("Claude", home: "p7"), pane: "p5", action: .read, now: 0)
    #expect(tracker.records.count == 3)
    #expect(tracker.display(now: 0).map(\.label) == ["claude · p1", "codex", "Claude · p7"])
}

@Test func elementsAndClosedPanes() throws {
    var tracker = PresenceTracker()
    let (call, _) = tracker.begin(actor: try actor(), pane: "p3", action: .write, now: 0)
    let rect = PresenceRect(x: 10, y: 40, width: 100, height: 30)
    tracker.end(try #require(call), result: .ok(nil), element: rect, now: 0.1)
    #expect(tracker.records[0].element == rect)
    _ = tracker.begin(actor: try actor(), pane: "p3", action: .read, now: 0.5)
    #expect(tracker.records[0].element == nil, "A new call starts at pane level until it reports an element")
    let ended = tracker.removePanes(notIn: ["p1"])
    #expect(ended.map(\.phase) == [.ended] && tracker.records.isEmpty)
}

@Test func transitionPayloadsAreValueFree() throws {
    var tracker = PresenceTracker()
    let (_, began) = tracker.begin(actor: try actor(note: "secret note"), pane: "p2", action: .read, now: 0)
    let payload = try #require(began.first?.payload.object)
    #expect(payload["actor"] == .object(["name": .string("claude"), "claimed": .bool(true)]))
    #expect(payload["pane"] == .string("p2") && payload["phase"] == .string("began") && payload["actionKind"] == .string("read"))
    let encoded = String(decoding: try JSONEncoder().encode(began[0].payload), as: UTF8.self)
    #expect(!encoded.contains("secret"))
}

@Test func colorsAreStablePerAgentType() {
    #expect(PresenceColor.rgb(for: "claude") == 0xFF9466)
    #expect(PresenceColor.rgb(for: "claude:reviewer") == 0xFF9466)
    let unknown = PresenceColor.rgb(for: "my-agent")
    #expect(unknown == PresenceColor.rgb(for: "my-agent") && PresenceColor.fallback.contains(unknown))
}

@Test func overlappingCallsKeepALongRunsSpinnerAndResult() throws {
    var tracker = PresenceTracker()
    let (run, _) = tracker.begin(actor: try actor(), pane: "p2", action: .run, now: 0)
    let (read, _) = tracker.begin(actor: try actor(), pane: "p2", action: .read, now: 1)
    tracker.end(try #require(read), result: .ok(nil), element: nil, now: 1.05)
    #expect(tracker.display(now: 2).first?.elapsed == 2, "A quick read does not reset the run's elapsed time")
    tracker.end(try #require(run), result: .failed("exit 2"), element: nil, now: 3)
    #expect(tracker.records[0].result == .failed("exit 2"))
    let (_, _) = tracker.begin(actor: try actor(), pane: "p2", action: .read, now: 3.2)
    #expect(tracker.records[0].result == .failed("exit 2"), "A quick read keeps the visible outcome")
    tracker.end(try #require(run), result: .ok(nil), element: nil, now: 3.3)
    #expect(tracker.records[0].isLive, "Ending the same call twice is ignored")
}

@Test func callsRefreshALeaseByItsOwnTTL() throws {
    var tracker = PresenceTracker()
    _ = tracker.hold(actor: try actor(), pane: "p4", seconds: 5, now: 0)
    let (call, _) = tracker.begin(actor: try actor(), pane: "p4", action: .read, now: 4)
    tracker.end(try #require(call), result: .ok(nil), element: PresenceRect(x: 0, y: 0, width: 5, height: 5), now: 4.1)
    #expect(tracker.records[0].leaseUntil == 9)
    #expect(tracker.records[0].element == nil, "Held tags stay at the pane corner")
    #expect(tracker.expire(now: 9.01).count == 1)
}
