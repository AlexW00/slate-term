import Foundation
import SlateTermCore

nonisolated struct TerminalRunResult: Encodable, Sendable {
    let paneId: PaneID
    let sessionId: String
    let commandId: String
    let exitCode: Int?
    let text: String
    let truncated: Bool
}

nonisolated enum TerminalRunError: Error, Equatable, Sendable, LocalizedError {
    case closed
    case invalidCommand(String)
    case invalidTimeout(Int)
    case overloaded(maximumPending: Int)
    case alreadyRunning(PaneID)
    case replaced
    case interrupted
    case editingBufferNotEmpty
    case timeout

    var errorDescription: String? {
        switch self {
        case .closed: return "Terminal run tracker is closed"
        case .invalidCommand(let reason): return "Invalid terminal command: \(reason)"
        case .invalidTimeout(let milliseconds):
            return "Terminal run timeout must be 1...295000 milliseconds (received \(milliseconds))"
        case .overloaded(let maximumPending):
            return "Terminal run tracker has reached its limit of \(maximumPending) pending runs"
        case .alreadyRunning(let pane): return "A terminal run is already pending for \(pane)"
        case .replaced: return "Terminal run session was removed or replaced"
        case .interrupted: return "Terminal run was interrupted by another shell command"
        case .editingBufferNotEmpty:
            return "Terminal is not at an empty prompt (a draft, continuation line or running program); nothing was submitted"
        case .timeout: return "Timed out waiting for terminal run completion; the shell process was not stopped"
        }
    }
}

/// Tracks trusted shell transitions, not processes or output. The caller authenticates a live
/// prompt before run and forwards accepted reports, including late ones and transitions during send.
/// Reports can arrive out of order. A run completes on the prompt numbered exactly one after its
/// running report, which every integrated shell guarantees.
@MainActor
final class TerminalRuns {
    static let maximumCommandBytes = 16_384
    static let maximumTimeoutMilliseconds = 295_000
    static let maximumPendingRuns = 32
    static let maximumOutputBytes = TerminalOutput.maximumBytes

    var pendingCount: Int { pending.count }
    func displayCommand(pane: PaneID) -> String? { pending[pane]?.command }

    /// Called only by the authenticated shell widget, after inspecting its actual edit buffer.
    func claimInput(pane: PaneID, sessionID: String, emptyBuffer: Bool) throws -> String {
        guard var run = pending[pane], run.sessionID == sessionID, !run.inputClaimed else { throw TerminalRunError.replaced }
        do { try run.validateCaller() }
        catch {
            finish(pane: pane, id: run.id, with: .failure(error))
            throw error
        }
        guard emptyBuffer else {
            finish(pane: pane, id: run.id, with: .failure(TerminalRunError.editingBufferNotEmpty))
            throw TerminalRunError.editingBufferNotEmpty
        }
        run.inputClaimed = true
        pending[pane] = run
        return run.line
    }

    private var pending: [PaneID: PendingRun] = [:]
    private var reserved = Set<PaneID>()

    /// Reserve capacity before a layout replaces any live workspace resources.
    func reserve(_ panes: Set<PaneID>) throws {
        guard !isClosed else { throw TerminalRunError.closed }
        guard panes.isDisjoint(with: reserved), panes.isDisjoint(with: pending.keys),
              panes.count + reserved.count + pending.count <= Self.maximumPendingRuns else {
            throw TerminalRunError.overloaded(maximumPending: Self.maximumPendingRuns)
        }
        reserved.formUnion(panes)
    }
    func releaseReservation(_ pane: PaneID) { reserved.remove(pane) }
    private var isClosed = false

    func run(
        pane: PaneID,
        sessionID: String,
        command: String,
        timeoutMilliseconds: Int = 30_000,
        shell: ShellKind = .zsh,
        baseline: Int? = nil,
        usingReservation: Bool = false,
        validateCaller: @escaping @MainActor () throws -> Void = {},
        send: (String) throws -> Void
    ) async throws -> TerminalRunResult {
        guard !isClosed else { throw TerminalRunError.closed }
        guard !command.isEmpty else { throw TerminalRunError.invalidCommand("command is empty") }
        guard !command.utf8.contains(0) else { throw TerminalRunError.invalidCommand("command contains NUL") }
        guard command.utf8.count <= Self.maximumCommandBytes else {
            throw TerminalRunError.invalidCommand("command exceeds \(Self.maximumCommandBytes) UTF-8 bytes")
        }
        guard (1...Self.maximumTimeoutMilliseconds).contains(timeoutMilliseconds) else {
            throw TerminalRunError.invalidTimeout(timeoutMilliseconds)
        }
        try Task.checkCancellation()
        try validateCaller()
        guard pending[pane] == nil else { throw TerminalRunError.alreadyRunning(pane) }
        if usingReservation {
            guard reserved.remove(pane) != nil else { throw TerminalRunError.replaced }
        } else {
            guard !reserved.contains(pane) else { throw TerminalRunError.alreadyRunning(pane) }
            guard pending.count + reserved.count < Self.maximumPendingRuns else {
                throw TerminalRunError.overloaded(maximumPending: Self.maximumPendingRuns)
            }
        }
        let id = UUID()
        let prefix = shell.runMarker(id)
        let line = shell.runLine(id, command: command) + "\r"
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation can precede registration, including handler installation.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    self?.finish(pane: pane, id: id, with: .failure(TerminalRunError.timeout))
                }
                pending[pane] = PendingRun(
                    id: id, sessionID: sessionID, prefix: prefix, command: command, line: String(line.dropLast()),
                    baseline: baseline, continuation: continuation, timer: timer, validateCaller: validateCaller
                )
                // Register before sending: send may synchronously deliver running AND prompt.
                do { try send(line) }
                catch { finish(pane: pane, id: id, with: .failure(error)) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish(pane: pane, id: id, with: .failure(CancellationError()))
            }
        }
    }

    func observe(pane: PaneID, sessionID: String, report: ShellReport, capture: () -> String) {
        guard var run = pending[pane] else { return }
        guard sessionID == run.sessionID else {
            finish(pane: pane, id: run.id, with: .failure(TerminalRunError.replaced))
            return
        }
        // Reports up to the baseline were sent before this run and belong to earlier commands.
        if let baseline = run.baseline, report.sequence <= baseline { return }
        switch report.state {
        case .running:
            guard report.command?.hasPrefix(run.prefix) == true else {
                // A later command starts after this run's prompt (running + 1), which may still be in flight.
                if let running = run.runningSequence, report.sequence > running + 1 { return }
                // The shell claims only at an empty primary prompt, so after a claim another
                // command's report belongs to one that finished before it; this run still ran.
                if run.inputClaimed, report.sequence < (run.runningSequence ?? .max) { return }
                // Before the claim, another command means the user got there first.
                finish(pane: pane, id: run.id, with: .failure(TerminalRunError.interrupted))
                return
            }
            run.runningSequence = report.sequence
            pending[pane] = run
            if let prompt = run.prompts.first(where: { $0.sequence > report.sequence }) {
                complete(pane: pane, run: run, prompt: prompt, capture: capture)
            }
        case .prompt:
            guard let sequence = run.runningSequence else {
                // The prompt overtook its running report; keep it until that report arrives.
                run.prompts.append(report)
                run.prompts.sort { $0.sequence < $1.sequence }
                pending[pane] = run
                return
            }
            guard report.sequence > sequence else { return }
            complete(pane: pane, run: run, prompt: report, capture: capture)
        }
    }

    /// Only the immediate successor carries this run's status. A later prompt that overtook it
    /// still ends the run, without claiming a status that may belong to another command.
    private func complete(pane: PaneID, run: PendingRun, prompt: ShellReport, capture: () -> String) {
        let exitCode = prompt.sequence == run.runningSequence.map({ $0 + 1 }) ? prompt.exitCode : nil
        // Release before capture as well as resume: even capture may synchronously re-enter us.
        guard take(pane: pane, id: run.id) != nil else { return }
        let output = TerminalOutput(capture())
        run.continuation.resume(returning: TerminalRunResult(
            paneId: pane, sessionId: run.sessionID, commandId: run.id.uuidString,
            exitCode: exitCode, text: output.text, truncated: output.truncated
        ))
    }

    func remove(pane: PaneID) {
        reserved.remove(pane)
        guard let run = pending[pane] else { return }
        finish(pane: pane, id: run.id, with: .failure(TerminalRunError.replaced))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        reserved.removeAll()
        for (pane, run) in pending {
            finish(pane: pane, id: run.id, with: .failure(TerminalRunError.closed))
        }
    }

    private func finish(pane: PaneID, id: UUID, with result: Result<TerminalRunResult, Error>) {
        guard let run = take(pane: pane, id: id) else { return }
        run.continuation.resume(with: result)
    }

    private func take(pane: PaneID, id: UUID) -> PendingRun? {
        // An old cancellation/deadline must never consume a successor occupying the same pane.
        guard let run = pending[pane], run.id == id else { return nil }
        pending.removeValue(forKey: pane)
        run.timer.cancel()
        return run
    }

    private struct PendingRun {
        let id: UUID
        let sessionID: String
        let prefix: String
        let command: String
        let line: String
        var inputClaimed = false
        let baseline: Int?
        var runningSequence: Int?
        /// Prompts that arrived before the running report, oldest first.
        var prompts: [ShellReport] = []
        let continuation: CheckedContinuation<TerminalRunResult, Error>
        let timer: Task<Void, Never>
        let validateCaller: @MainActor () throws -> Void
    }
}
