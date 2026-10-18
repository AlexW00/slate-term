import Foundation
import Testing
@testable import SlateTermCore

private func operationReport(_ state: ShellReport.State, sequence: Int, command: String? = nil, exitCode: Int? = nil) -> ShellReport {
    ShellReport(state: state, pid: 123, sequence: sequence, workingDirectory: "/tmp", command: command, exitCode: exitCode)
}

@Test func operationHandleRetainsRepeatableBoundedResultsWithoutAWaiter() throws {
    var store = TerminalOperationStore()
    let now = ContinuousClock.now
    let handle = try store.start(pane: PaneID(1), sessionId: "original", command: "printf '日本語'\nfalse", afterSequence: 4, now: now)
    #expect(handle.state == .awaitingInput)
    #expect(throws: TerminalOperationError.notReady) { try store.result(handle.commandId, now: now) }
    let line = try store.claimInput(pane: PaneID(1), sessionId: "original", emptyBuffer: true, now: now)
    #expect(line.contains("\\x27日本語\\x27\\x0afalse"))
    #expect(store.observe(pane: PaneID(1), sessionId: "original", report: operationReport(.running, sequence: 5, command: line), now: now) == nil)
    let capture = store.observe(pane: PaneID(1), sessionId: "original", report: operationReport(.prompt, sequence: 6, exitCode: 1), now: now)
    #expect(capture == handle.commandId)
    #expect(store.activeCount == 0)
    #expect(try store.status(handle.commandId, now: now).state == .capturing)
    store.completeCapture(handle.commandId, text: String(repeating: "日本語", count: 20_000), now: now)
    let first = try store.result(handle.commandId, now: now)
    let again = try store.result(handle.commandId, now: now.advanced(by: .seconds(100)))
    #expect(first == again)
    #expect(first.exitCode == 1 && first.truncated)
    #expect(first.text.utf8.count <= TerminalOutput.maximumBytes)
    #expect(!first.text.contains("\u{fffd}"))
    #expect(try store.status(handle.commandId, now: now).state == .completed)
    #expect(try store.result(handle.commandId, now: now.advanced(by: .seconds(899))) == first)
    #expect(throws: TerminalOperationError.unavailable) {
        try store.result(handle.commandId, now: now.advanced(by: TerminalOperationStore.retention))
    }
}

@Test func operationDraftRefusalIsRetainedAndDoesNotConsumeTheNextRun() throws {
    var store = TerminalOperationStore()
    let first = try store.start(pane: PaneID(1), sessionId: "s", command: "first", afterSequence: 1)
    #expect(throws: TerminalOperationError.editingBufferNotEmpty) {
        try store.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: false)
    }
    #expect(try store.status(first.commandId).state == .rejected)
    #expect(throws: TerminalOperationError.failed(.editingBufferNotEmpty)) { try store.result(first.commandId) }
    let next = try store.start(pane: PaneID(1), sessionId: "new", command: "next", afterSequence: 1)
    #expect(throws: TerminalOperationError.unavailable) { try store.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: true) }
    store.loseSession(pane: PaneID(1), sessionId: "s")
    #expect(try store.status(next.commandId).state == .awaitingInput)
    let line = try store.claimInput(pane: PaneID(1), sessionId: "new", emptyBuffer: true)
    #expect(line.contains(next.commandId.uuidString))
    #expect(throws: TerminalOperationError.alreadyClaimed) { try store.claimInput(pane: PaneID(1), sessionId: "new", emptyBuffer: true) }
}

@Test func operationPairsReorderedReportsAndIgnoresReportsBeforeItsBaseline() throws {
    var store = TerminalOperationStore()
    let handle = try store.start(pane: PaneID(1), sessionId: "s", command: "sleep 5", afterSequence: 10)
    let line = try store.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: true)
    #expect(store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.running, sequence: 9, command: line)) == nil)
    #expect(try store.status(handle.commandId).state == .submitted)
    // The prompt overtook its running report: keep it rather than guessing completion.
    #expect(store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.prompt, sequence: 12, exitCode: 3)) == nil)
    #expect(try store.status(handle.commandId).state == .submitted)
    #expect(store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.running, sequence: 11, command: line)) == handle.commandId)
    store.completeCapture(handle.commandId, text: "done")
    #expect(try store.result(handle.commandId).exitCode == 3)
    let next = try store.start(pane: PaneID(1), sessionId: "s", command: "expected", afterSequence: 12)
    #expect(store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.running, sequence: 13, command: "manual command")) == nil)
    #expect(try store.status(next.commandId).state == .interrupted)
    #expect(throws: TerminalOperationError.failed(.otherCommand)) { try store.result(next.commandId) }
}

@Test func operationOnlyClaimsTheImmediatePromptStatusAndLosesReplacedSessions() throws {
    var store = TerminalOperationStore()
    let handle = try store.start(pane: PaneID(1), sessionId: "s", command: "x", shell: .fish, afterSequence: 0)
    let line = try store.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: true)
    #expect(line.hasPrefix("true __SLATE_RUN_\(handle.commandId.uuidString);"))
    _ = store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.running, sequence: 1, command: line))
    // A later command's running report (after this operation's prompt) is not an interruption.
    #expect(store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.running, sequence: 3, command: "later")) == nil)
    #expect(store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.prompt, sequence: 4, exitCode: 9)) == handle.commandId)
    store.completeCapture(handle.commandId, text: "after later")
    #expect(try store.result(handle.commandId).exitCode == nil)
    let replaced = try store.start(pane: PaneID(1), sessionId: "old", command: "x", afterSequence: 0)
    #expect(store.observe(pane: PaneID(1), sessionId: "new", report: operationReport(.prompt, sequence: 1, exitCode: 0)) == nil)
    #expect(try store.status(replaced.commandId).state == .sessionLost)
}

@Test func sessionLossDuringCaptureCannotPublishOverASuccessorOrStealItsReservation() throws {
    var store = TerminalOperationStore()
    let first = try store.start(pane: PaneID(1), sessionId: "old", command: "first", afterSequence: 1)
    let line = try store.claimInput(pane: PaneID(1), sessionId: "old", emptyBuffer: true)
    _ = store.observe(pane: PaneID(1), sessionId: "old", report: operationReport(.running, sequence: 2, command: line))
    #expect(store.observe(pane: PaneID(1), sessionId: "old", report: operationReport(.prompt, sequence: 3, exitCode: 0)) == first.commandId)
    try store.reserve([PaneID(1)])
    store.loseSession(pane: PaneID(1), sessionId: "old")
    let next = try store.start(pane: PaneID(1), sessionId: "new", command: "next", afterSequence: 1, usingReservation: true)
    store.completeCapture(first.commandId, text: "obsolete output")
    #expect(try store.status(first.commandId).state == .sessionLost)
    #expect(try store.status(next.commandId).state == .awaitingInput)
    #expect(store.activeCount == 1)
    store.close()
    #expect(try store.status(next.commandId).state == .sessionLost)
    #expect(throws: TerminalOperationError.closed) { try store.start(pane: PaneID(2), sessionId: "other", command: "no", afterSequence: 1) }
}

@Test func terminalOperationRetentionExpiresOnlyFinishedWorkAndNeverEvictsActiveHandles() throws {
    var store = TerminalOperationStore()
    let now = ContinuousClock.now
    let active = try store.start(pane: PaneID(1), sessionId: "active", command: "long running", afterSequence: 1, now: now)
    var completed: [UUID] = []
    for index in 0..<TerminalOperationStore.maximumRecords {
        let time = now.advanced(by: .milliseconds(index + 1))
        let item = try store.start(pane: PaneID(2), sessionId: "s", command: "short", afterSequence: 1, now: time)
        store.submissionFailed(item.commandId, now: time)
        completed.append(item.commandId)
    }
    #expect(store.list(now: now).count == TerminalOperationStore.maximumRecords)
    #expect(throws: TerminalOperationError.unavailable) { try store.status(completed[0], now: now) }
    #expect(try store.status(active.commandId, now: now.advanced(by: .seconds(10_000))).state == .awaitingInput)
    #expect(store.list(now: now.advanced(by: .seconds(10_000))).map(\.commandId) == [active.commandId])
}

@Test func successfulCaptureCannotConsumeItsSameSessionSuccessor() throws {
    var store = TerminalOperationStore()
    let first = try store.start(pane: PaneID(1), sessionId: "s", command: "first", afterSequence: 1)
    let line = try store.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: true)
    _ = store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.running, sequence: 2, command: line))
    _ = store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.prompt, sequence: 3, exitCode: 0))
    let next = try store.start(pane: PaneID(1), sessionId: "s", command: "next", afterSequence: 3)
    store.completeCapture(first.commandId, text: "first screen")
    store.completeCapture(first.commandId, text: "late duplicate must not win")
    _ = store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.prompt, sequence: 3, exitCode: 0))
    #expect(try store.result(first.commandId).text == "first screen")
    #expect(try store.status(next.commandId).state == .awaitingInput)
    #expect(store.activeCount == 1)
}

@Test func unfinishedCapturesCannotBeSilentlyEvictedToMakeRoom() throws {
    var store = TerminalOperationStore()
    var captures: [UUID] = []
    for index in 0..<TerminalOperationStore.maximumRecords {
        let first = try store.start(pane: PaneID(1), sessionId: "s", command: "capture", afterSequence: index * 2)
        let line = try store.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: true)
        _ = store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.running, sequence: index * 2 + 1, command: line))
        _ = store.observe(pane: PaneID(1), sessionId: "s", report: operationReport(.prompt, sequence: index * 2 + 2, exitCode: 0))
        captures.append(first.commandId)
    }
    #expect(store.activeCount == 0)
    #expect(throws: TerminalOperationError.capacity(limit: 128)) {
        try store.start(pane: PaneID(2), sessionId: "next", command: "blocked", afterSequence: 0)
    }
    #expect(store.list().allSatisfy { $0.state == .capturing })
    store.completeCapture(captures[0], text: "finished")
    _ = try store.start(pane: PaneID(2), sessionId: "next", command: "fits", afterSequence: 0)
    #expect(throws: TerminalOperationError.unavailable) { try store.status(captures[0]) }
    #expect(try store.status(captures[1]).state == .capturing)
    #expect(store.list().count == 128)
}

@Test func activeOperationsAndStartupReservationsShareABoundedCapacity() throws {
    var store = TerminalOperationStore()
    let reserved = Set((1...TerminalOperationStore.maximumActive).map(PaneID.init))
    try store.reserve(reserved)
    #expect(throws: TerminalOperationError.capacity(limit: 32)) { try store.start(pane: PaneID(99), sessionId: "s", command: "x", afterSequence: 1) }
    #expect(throws: TerminalOperationError.invalidCommand) { try store.start(pane: PaneID(1), sessionId: "s", command: "bad\0command", afterSequence: 1, usingReservation: true) }
    #expect(store.reservedCount == 32)
    _ = try store.start(pane: PaneID(1), sessionId: "s", command: "ok", afterSequence: 1, usingReservation: true)
    #expect(store.activeCount == 1 && store.reservedCount == 31)
    #expect(throws: TerminalOperationError.alreadyRunning(PaneID(1))) { try store.start(pane: PaneID(1), sessionId: "s", command: "second", afterSequence: 1) }
    store.releaseReservation(PaneID(2))
    _ = try store.start(pane: PaneID(99), sessionId: "s", command: "now fits", afterSequence: 1)
    #expect(store.activeCount + store.reservedCount == 32)
}
