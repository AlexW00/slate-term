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
        case .editingBufferNotEmpty: return "Terminal editing buffer is not empty; the draft was not submitted"
        case .timeout: return "Timed out waiting for terminal run completion; the shell process was not stopped"
        }
    }
}

/// Tracks trusted shell transitions, not processes or output. The caller authenticates a live zsh
/// prompt before run and synchronously forwards accepted reports, including transitions during send.
@MainActor
final class TerminalRuns {
    static let maximumCommandBytes = 16_384
    static let maximumTimeoutMilliseconds = 295_000
    static let maximumPendingRuns = 32
    static let maximumOutputBytes = TerminalOutput.maximumBytes

    var pendingCount: Int { pending.count }
    func displayCommand(pane: PaneID) -> String? { pending[pane]?.command }

    /// Called only by the authenticated shell widget, after inspecting its actual ZLE buffer.
    func claimInput(pane: PaneID, sessionID: String, emptyBuffer: Bool) throws -> String {
        guard var run = pending[pane], run.sessionID == sessionID, !run.inputClaimed else { throw TerminalRunError.replaced }
        guard emptyBuffer else {
            finish(pane: pane, id: run.id, with: .failure(TerminalRunError.editingBufferNotEmpty))
            throw TerminalRunError.editingBufferNotEmpty
        }
        run.inputClaimed = true
        pending[pane] = run
        return run.line
    }

    private var pending: [PaneID: PendingRun] = [:]
    private var isClosed = false

    func run(
        pane: PaneID,
        sessionID: String,
        command: String,
        timeoutMilliseconds: Int = 30_000,
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
        guard pending[pane] == nil else { throw TerminalRunError.alreadyRunning(pane) }
        guard pending.count < Self.maximumPendingRuns else {
            throw TerminalRunError.overloaded(maximumPending: Self.maximumPendingRuns)
        }
        let id = UUID()
        let prefix = ": __SLATE_RUN_\(id.uuidString);"
        let line = "\(prefix) builtin eval $'\(Self.quote(command))'\r"
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
                    continuation: continuation, timer: timer
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
        switch report.state {
        case .running:
            guard report.command?.hasPrefix(run.prefix) == true else {
                finish(pane: pane, id: run.id, with: .failure(TerminalRunError.interrupted))
                return
            }
            run.runningSequence = report.sequence
            pending[pane] = run
        case .prompt:
            guard let sequence = run.runningSequence, report.sequence > sequence else { return }
            // Release before capture as well as resume: even capture may synchronously re-enter us.
            guard take(pane: pane, id: run.id) != nil else { return }
            let output = TerminalOutput(capture())
            run.continuation.resume(returning: TerminalRunResult(
                paneId: pane, sessionId: run.sessionID, commandId: run.id.uuidString,
                exitCode: report.exitCode, text: output.text, truncated: output.truncated
            ))
        }
    }

    func remove(pane: PaneID) {
        guard let run = pending[pane] else { return }
        finish(pane: pane, id: run.id, with: .failure(TerminalRunError.replaced))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
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

    private static func quote(_ command: String) -> String {
        var quoted = ""
        for scalar in command.unicodeScalars {
            let value = scalar.value
            if value < 32 || value == 127 || value == 39 || value == 92 {
                quoted += String(format: "\\x%02x", value)
            } else {
                quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted
    }

    private struct PendingRun {
        let id: UUID
        let sessionID: String
        let prefix: String
        let command: String
        let line: String
        var inputClaimed = false
        var runningSequence: Int?
        let continuation: CheckedContinuation<TerminalRunResult, Error>
        let timer: Task<Void, Never>
    }
}
