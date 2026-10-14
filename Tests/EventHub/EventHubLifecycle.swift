import Darwin
import Foundation
import SlateTermCore

@main
@MainActor
struct EventHubLifecycle {
    static func main() async {
        setbuf(stdout, nil)
        do {
            try await checkReplayAndValidation()
            try await checkFilteredPublication()
            try await checkTimeoutAndRetention()
            try await checkCancellation()
            try await checkCloseAndOverload()
            try await checkBurstsAndRaces()
            print("PASS all event hub lifecycle checks")
        } catch {
            fputs("FAIL event hub lifecycle: \(error)\n", stderr)
            exit(1)
        }
    }

    static func checkReplayAndValidation() async throws {
        let epoch = UUID()
        let hub = try EventHub(epoch: epoch)
        defer { hub.close() }
        let start = hub.cursor
        try require(start == "\(epoch.uuidString):0", "initial epoch cursor")
        let first = try hub.publish(topic: "host.ready")
        let second = try hub.publish(topic: "client.changed", payload: .string("second"), source: .client)
        let replay = try await hub.poll(after: start, limit: 1)
        try require(replay.events == [first] && replay.cursor == first.cursor, "bounded replay skipped a matching event")
        let next = try await hub.poll(after: replay.cursor)
        try require(next.events == [second] && next.cursor == hub.cursor, "replay continuation")
        let empty = try await hub.poll(waitMilliseconds: 0)
        try require(empty.events.isEmpty && empty.cursor == second.cursor, "nil must start at current head")
        try require(hub.pendingCount == 0, "immediate requests suspended")
        let filtered = try await hub.poll(after: start, filter: EventFilter(topics: ["quiet.*"]), waitMilliseconds: 0)
        try require(filtered.events.isEmpty && filtered.cursor == second.cursor, "empty scan did not advance cursor")
        try await expectError(EventJournalError.invalidCursor("bogus")) { try await hub.poll(after: "bogus") }
        try await expectError(EventJournalError.epochMismatch(expected: epoch, actual: otherEpoch)) {
            try await hub.poll(after: "\(otherEpoch.uuidString):0")
        }
        try await expectError(EventJournalError.futureCursor(sequence: 3, head: 2)) {
            try await hub.poll(after: "\(epoch.uuidString):3")
        }
        for limit in [0, 129] {
            try await expectError(EventJournalError.invalidLimit(limit)) { try await hub.poll(limit: limit) }
        }
        for milliseconds in [-1, 25_001, Int.max] {
            try await expectError(EventHubError.invalidTimeout(milliseconds)) { try await hub.poll(waitMilliseconds: milliseconds) }
        }
        // EventFilter's initializer/decoder is the journal's validated boundary, not a raw hub input.
        do {
            _ = try EventFilter(topics: ["bad.**"])
            throw Failure(message: "invalid filter accepted")
        } catch let error as EventJournalError {
            try require(error == .invalidFilter("Invalid topic pattern: bad.**"), "filter error changed")
        }
        let beforeRejected = hub.cursor
        do {
            _ = try hub.publish(topic: "host.forbidden", source: .client)
            throw Failure(message: "reserved topic accepted")
        } catch let error as EventJournalError {
            try require(error == .reservedTopic("host.forbidden"), "publish validation error changed")
        }
        try require(hub.cursor == beforeRejected && hub.pendingCount == 0, "invalid input changed hub state")
        let defaultPoll = Task { try await hub.poll() }
        try await pending(hub, count: 1)
        let future = try hub.publish(topic: "host.future")
        let defaultBatch = try await defaultPoll.value
        try require(defaultBatch.events == [future], "default poll replayed old events")
        print("PASS replay, head defaults, immediate scans, cursor/filter/limit/timeout validation and rejected publication")
    }

    static let otherEpoch = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func checkFilteredPublication() async throws {
        let hub = try EventHub()
        defer { hub.close() }
        let filter = try EventFilter(topics: ["plugin.*"], tab: TabID(1), pane: PaneID(1), recipientInstanceId: "reader")
        let filtered = Task { try await hub.poll(filter: filter) }
        let all = Task { try await hub.poll() }
        try await pending(hub, count: 2)
        let unrelated = try hub.publish(topic: "host.changed")
        let allBatch = try await all.value
        try require(allBatch.events == [unrelated], "all-topic reader did not wake")
        try require(hub.pendingCount == 1, "topic nonmatch completed filtered reader")
        _ = try hub.publish(topic: "plugin.changed", tab: TabID(2), pane: PaneID(2))
        _ = try hub.publish(topic: "plugin.changed", targetInstanceId: "someone-else")
        try require(hub.pendingCount == 1, "scope or target nonmatch completed reader")
        let directed = try hub.publish(
            topic: "plugin.changed", payload: .string("directed"),
            source: .plugin(type: "fixture", instanceId: "sender"),
            tab: TabID(2), pane: PaneID(2), targetInstanceId: "reader"
        )
        let result = try await filtered.value
        try require(result.events == [directed] && result.cursor == directed.cursor, "directed matching event or metadata lost")
        try require(hub.pendingCount == 0, "matched waiter leaked")
        let broadcastReader = Task { try await hub.poll(filter: filter) }
        try await pending(hub, count: 1)
        let broadcast = try hub.publish(topic: "plugin.broadcast")
        try require(try await broadcastReader.value.events == [broadcast], "unscoped broadcast failed to wake scoped reader")
        print("PASS actual suspended readers, topic/scope/recipient filtering, directed metadata and broadcast delivery")
    }

    static func checkTimeoutAndRetention() async throws {
        let hub = try EventHub()
        defer { hub.close() }
        let start = hub.cursor
        let quiet = try EventFilter(topics: ["quiet.changed"])
        let clock = ContinuousClock()
        let began = clock.now
        let reader = Task { try await hub.poll(after: start, filter: quiet, waitMilliseconds: 300) }
        try await pending(hub, count: 1)
        for _ in 0..<(EventJournal.maximumRetainedEvents + 17) {
            _ = try hub.publish(topic: "busy.changed")
        }
        try require(hub.pendingCount == 1, "unmatched traffic expired or completed reader")
        let scanned = hub.cursor
        let timeout = try await reader.value
        try require(timeout.events.isEmpty && timeout.cursor == scanned, "timeout lost latest scanned cursor")
        try require(began.duration(to: clock.now) >= .milliseconds(250), "deadline returned too early")
        try require(hub.pendingCount == 0, "deadline did not release waiter")
        try await expectError(EventJournalError.expiredCursor(sequence: 0, oldestAvailable: 17)) {
            try await hub.poll(after: start, waitMilliseconds: 0)
        }
        let matching = Task { try await hub.poll(filter: quiet, waitMilliseconds: 5_000) }
        try await pending(hub, count: 1)
        for _ in 0..<(EventJournal.maximumRetainedEvents + 17) {
            _ = try hub.publish(topic: "busy.changed")
        }
        try require(hub.pendingCount == 1, "second retention-length scan completed prematurely")
        let event = try hub.publish(topic: "quiet.changed")
        let batch = try await matching.value
        try require(batch.events == [event] && batch.cursor == event.cursor, "quiet topic falsely expired under unrelated traffic")
        print("PASS real deadline, latest scanned timeout cursor, explicit history expiry and >retention nonmatches before match/timeout")
    }

    static func checkCancellation() async throws {
        let hub = try EventHub()
        defer { hub.close() }
        let start = hub.cursor
        let cancelled = Task { try await hub.poll(waitMilliseconds: 120) }
        try await pending(hub, count: 1)
        cancelled.cancel()
        try await pending(hub, count: 0)
        try await expectCancellation { try await cancelled.value }
        let successor = Task { try await hub.poll(waitMilliseconds: 5_000) }
        try await pending(hub, count: 1)
        // Cross the removed deadline: it must not complete the successor occupying its former slot.
        try await Task.sleep(for: .milliseconds(180))
        try require(hub.pendingCount == 1, "old timer affected successor")
        let event = try hub.publish(topic: "host.successor")
        try require(try await successor.value.events == [event], "successor did not survive old deadline")
        let alreadyCancelled = Task { try await hub.poll(waitMilliseconds: 25_000) }
        alreadyCancelled.cancel() // MainActor has not yielded, so cancellation precedes poll entry.
        try await expectCancellation { try await alreadyCancelled.value }
        try require(hub.pendingCount == 0, "already-cancelled caller registered")
        let cancelledReplay = Task { try await hub.poll(after: start, waitMilliseconds: 0) }
        cancelledReplay.cancel()
        try await expectCancellation { try await cancelledReplay.value }
        let maximumWait = Task { try await hub.poll(waitMilliseconds: 25_000) }
        try await pending(hub, count: 1)
        maximumWait.cancel()
        try await expectCancellation { try await maximumWait.value }
        try require(hub.pendingCount == 0, "maximum deadline cancellation leaked")
        var ownedHub: EventHub? = try EventHub()
        weak let weakHub = ownedHub
        var ownedTask: Task<EventBatch, Error>? = Task { [hub = ownedHub!] in try await hub.poll(waitMilliseconds: 25_000) }
        try await pending(ownedHub!, count: 1)
        ownedTask!.cancel()
        try await expectCancellation { try await ownedTask!.value }
        ownedTask = nil
        ownedHub = nil
        try await eventually("cancelled deadline retains hub") { weakHub == nil }
        print("PASS disconnect and pre-entry cancellation, max wait boundary, stale deadline isolation and no deadline self-cycle")
    }

    static func checkCloseAndOverload() async throws {
        let hub = try EventHub()
        let initialCursor = hub.cursor
        let retained = try hub.publish(topic: "host.retained")
        var readers: [Task<EventBatch, Error>] = []
        for _ in 0..<128 { readers.append(Task { try await hub.poll() }) }
        try await pending(hub, count: 128)
        try await expectError(EventHubError.overloaded(maximumPending: 128)) { try await hub.poll() }
        try await expectError(EventJournalError.invalidCursor("bad")) { try await hub.poll(after: "bad") }
        let saturatedReplay = try await hub.poll(after: initialCursor)
        try require(saturatedReplay.events == [retained] && hub.pendingCount == 128, "saturation rejected immediate replay")
        readers[0].cancel()
        try await expectCancellation { try await readers[0].value }
        try require(hub.pendingCount == 127, "disconnect did not release capacity")
        readers[0] = Task { try await hub.poll() }
        try await pending(hub, count: 128)
        let head = hub.cursor
        let immediate = try await hub.poll(waitMilliseconds: 0)
        try require(immediate.events.isEmpty && immediate.cursor == head && hub.pendingCount == 128, "zero-wait request rejected or dropped a pending caller")
        let event = try hub.publish(topic: "host.capacity")
        for reader in readers { try require(try await reader.value.events == [event], "overload dropped an existing caller") }
        try require(hub.pendingCount == 0, "publication did not release all capacity")
        let replay = try await hub.poll(after: head)
        try require(replay.events == [event], "replay after saturation")
        let short = Task { try await hub.poll(waitMilliseconds: 50) }
        let long = Task { try await hub.poll() }
        try await pending(hub, count: 2)
        hub.close()
        hub.close()
        try require(hub.pendingCount == 0, "close retained waiters")
        try await expectError(EventHubError.closed) { try await short.value }
        try await expectError(EventHubError.closed) { try await long.value }
        try await expectError(EventHubError.closed) { try await hub.poll(waitMilliseconds: 0) }
        do {
            _ = try hub.publish(topic: "host.closed")
            throw Failure(message: "publish after close succeeded")
        } catch let error as EventHubError { try require(error == .closed, "publish after close error") }
        try await Task.sleep(for: .milliseconds(80))
        try require(hub.pendingCount == 0 && hub.cursor == event.cursor, "old deadline modified closed hub")
        print("PASS 128-caller capacity, overload rejection without drops, fan-out, idempotent close and future-operation failures")
    }

    static func checkBurstsAndRaces() async throws {
        let hub = try EventHub()
        defer { hub.close() }
        let filter = try EventFilter(topics: ["burst.match"])
        let reader = Task { try await hub.poll(filter: filter, limit: 2) }
        try await pending(hub, count: 1)
        var expected: [WorkspaceEvent] = []
        for index in 0..<40 {
            _ = try hub.publish(topic: "burst.other")
            expected.append(try hub.publish(topic: "burst.match", payload: .string("\(index)")))
        }
        _ = try hub.publish(topic: "burst.trailing")
        let initial = try await reader.value
        var received = initial.events
        var cursor = initial.cursor
        while cursor != hub.cursor {
            let batch = try await hub.poll(after: cursor, filter: filter, limit: 2, waitMilliseconds: 0)
            try require(batch.events.count <= 2 && batch.cursor != cursor, "burst replay made no progress or exceeded limit")
            received += batch.events
            cursor = batch.cursor
        }
        try require(received == expected, "coalesced burst lost, duplicated or reordered events")
        for iteration in 0..<30 {
            let before = hub.cursor
            let racer = Task { try await hub.poll(waitMilliseconds: 100) }
            try await pending(hub, count: 1)
            // Some iterations cross the deadline; others resolve on publication or cancellation.
            if iteration.isMultiple(of: 5) { try await Task.sleep(for: .milliseconds(100)) }
            if iteration.isMultiple(of: 2) { racer.cancel() }
            let event = try hub.publish(topic: "host.race")
            racer.cancel()
            do {
                let batch = try await racer.value
                try require(
                    (batch.events == [event] && batch.cursor == event.cursor) ||
                    (batch.events.isEmpty && batch.cursor == before), "race produced invalid batch"
                )
            } catch is CancellationError { }
            try require(hub.pendingCount == 0, "race left unresolved continuation")
        }
        print("PASS coalesced filtered burst replay with no skips/duplicates and publication/cancellation/deadline races")
    }

    static func pending(_ hub: EventHub, count: Int) async throws {
        try await eventually("expected \(count) pending readers, got \(hub.pendingCount)") { hub.pendingCount == count }
    }

    static func eventually(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(message: "timeout: \(label)") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    static func expectError<E: Error & Equatable>(_ expected: E, _ operation: () async throws -> EventBatch) async throws {
        do {
            _ = try await operation()
            throw Failure(message: "expected error: \(expected)")
        } catch let actual as E {
            try require(actual == expected, "expected \(expected), got \(actual)")
        }
    }

    static func expectCancellation(_ operation: () async throws -> EventBatch) async throws {
        do {
            _ = try await operation()
            throw Failure(message: "expected CancellationError")
        } catch is CancellationError { }
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    struct Failure: Error { let message: String }
}
