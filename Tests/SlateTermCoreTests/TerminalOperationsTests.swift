import Foundation
import Testing
@testable import SlateTermCore

private func runtimeReport(_ state: ShellReport.State, _ sequence: Int, command: String? = nil) -> ShellReport {
    ShellReport(state: state, pid: 123, sequence: sequence, workingDirectory: "/tmp", command: command, exitCode: state == .prompt ? 0 : nil)
}

@MainActor private func awaitOperationCondition(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw RuntimeTestError.conditionTimeout }
        try await Task.sleep(for: .milliseconds(1))
    }
}
private enum RuntimeTestError: Error { case send, conditionTimeout }

@Test @MainActor func cancellingAWaitLeavesAdoptedInputClaimableAndResultsReconnectable() async throws {
    let operations = TerminalOperations()
    defer { operations.close() }
    var callerLive = true
    let id = try operations.start(pane: PaneID(1), sessionId: "s", command: "owned by session", afterSequence: 0,
        validateCaller: { if !callerLive { throw CancellationError() } }, send: { callerLive = false })
    let first = Task { try await operations.wait(id) }
    try await awaitOperationCondition { operations.waiterCount == 1 }
    let other = Task { try await operations.wait(id) }
    try await awaitOperationCondition { operations.waiterCount == 2 }
    first.cancel()
    do { _ = try await first.value; Issue.record("cancelled waiter returned a result") }
    catch is CancellationError {}
    #expect(operations.waiterCount == 1 && operations.activeCount == 1)
    let line = try operations.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: true)
    operations.observe(pane: PaneID(1), sessionId: "s", report: runtimeReport(.running, 1, command: line)) { "not completed" }
    operations.observe(pane: PaneID(1), sessionId: "s", report: runtimeReport(.prompt, 2)) { "retained screen" }
    let result = try await other.value
    #expect(result.text == "retained screen")
    #expect(try await operations.wait(id) == result)
    #expect(try operations.result(id) == result)
    #expect(operations.waiterCount == 0)
}

@Test @MainActor func waitTimeoutDoesNotReleaseTheOperationOrStopItsEventualCompletion() async throws {
    let operations = TerminalOperations()
    defer { operations.close() }
    let id = try operations.start(pane: PaneID(1), sessionId: "s", command: "slow", afterSequence: 0, send: {})
    do { _ = try await operations.wait(id, timeoutMilliseconds: 1); Issue.record("wait should time out") }
    catch { #expect(error as? TerminalOperationWaitError == .timeout) }
    #expect(operations.activeCount == 1 && operations.waiterCount == 0)
    let line = try operations.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: true)
    operations.observe(pane: PaneID(1), sessionId: "s", report: runtimeReport(.running, 1, command: line)) { "" }
    operations.observe(pane: PaneID(1), sessionId: "s", report: runtimeReport(.prompt, 2)) { "later result" }
    #expect(try await operations.wait(id).text == "later result")
}

@Test @MainActor func waitCapacityAndInvalidTimeoutDoNotStartUnexpectedBlockingWork() async throws {
    let operations = TerminalOperations()
    defer { operations.close() }
    let id = try operations.start(pane: PaneID(1), sessionId: "s", command: "pending", afterSequence: 0, send: {})
    var waiting: [Task<TerminalOperationResult, Error>] = []
    defer { for task in waiting { task.cancel() } }
    for _ in 0..<TerminalOperations.maximumWaiters { waiting.append(Task { try await operations.wait(id) }) }
    try await awaitOperationCondition { operations.waiterCount == TerminalOperations.maximumWaiters }
    var sends = 0
    do {
        _ = try await operations.run(pane: PaneID(2), sessionId: "s", command: "must not start", afterSequence: 0, send: { sends += 1 })
        Issue.record("full wait queue accepted blocking work")
    } catch { #expect(error as? TerminalOperationWaitError == .capacity) }
    for value in [0, -1, 295_001] {
        do {
            _ = try await operations.run(pane: PaneID(2), sessionId: "s", command: "must not start", afterSequence: 0,
                                         timeoutMilliseconds: value, send: { sends += 1 })
            Issue.record("invalid timeout started work")
        } catch { #expect(error as? TerminalOperationWaitError == .invalidTimeout(value)) }
    }
    #expect(sends == 0 && operations.activeCount == 1)
    operations.loseSession(pane: PaneID(1), sessionId: "s")
    for task in waiting {
        do { _ = try await task.value; Issue.record("lost session returned success") }
        catch { #expect(error as? TerminalOperationError == .failed(.sessionLost)) }
    }
    #expect(operations.waiterCount == 0)
}

@Test @MainActor func synchronousReportsAndLateDeliveryFailureKeepTheFirstObservedOutcome() async throws {
    let operations = TerminalOperations()
    defer { operations.close() }
    let id = try operations.start(pane: PaneID(1), sessionId: "s", command: "instant", afterSequence: 0) {
        let line = try operations.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: true)
        operations.observe(pane: PaneID(1), sessionId: "s", report: runtimeReport(.running, 1, command: line)) { "" }
        operations.observe(pane: PaneID(1), sessionId: "s", report: runtimeReport(.prompt, 2)) { "synchronous" }
        throw RuntimeTestError.send
    }
    #expect(try await operations.wait(id).text == "synchronous")
    let rejected = try operations.start(pane: PaneID(1), sessionId: "s", command: "never claimed", afterSequence: 2) {
        throw RuntimeTestError.send
    }
    #expect(try operations.status(rejected).state == .rejected)
    let ambiguous = try operations.start(pane: PaneID(1), sessionId: "s", command: "claimed", afterSequence: 2) {
        _ = try operations.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: true)
        throw RuntimeTestError.send
    }
    #expect(try operations.status(ambiguous).state == .trackingLost)
    let running = try operations.start(pane: PaneID(1), sessionId: "s", command: "already running", afterSequence: 2) {
        let line = try operations.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: true)
        operations.observe(pane: PaneID(1), sessionId: "s", report: runtimeReport(.running, 3, command: line)) { "" }
        throw RuntimeTestError.send
    }
    #expect(try operations.status(running).state == .running)
    operations.observe(pane: PaneID(1), sessionId: "s", report: runtimeReport(.prompt, 4)) { "still tracked" }
    #expect(try await operations.wait(running).text == "still tracked")
}

@Test @MainActor func preCancelledCallsNeverSendAndCancellationDuringRunOnlyEndsItsWait() async throws {
    let operations = TerminalOperations()
    defer { operations.close() }
    var sends = 0
    let cancelled = Task {
        try await operations.run(pane: PaneID(1), sessionId: "s", command: "cancelled", afterSequence: 0, send: { sends += 1 })
    }
    cancelled.cancel()
    do { _ = try await cancelled.value; Issue.record("pre-cancelled run succeeded") }
    catch is CancellationError {}
    #expect(sends == 0 && operations.activeCount == 0)
    let adopted = Task {
        try await operations.run(pane: PaneID(1), sessionId: "s", command: "adopted", afterSequence: 0, send: { sends += 1 })
    }
    try await awaitOperationCondition { operations.waiterCount == 1 }
    adopted.cancel()
    do { _ = try await adopted.value; Issue.record("cancelled run wait succeeded") }
    catch is CancellationError {}
    #expect(sends == 1 && operations.activeCount == 1 && operations.waiterCount == 0)
    let id = try #require(operations.list().first?.commandId)
    #expect(try operations.status(id).state == .awaitingInput)
    operations.remove(pane: PaneID(1))
    #expect(try operations.status(id).state == .sessionLost)
}
