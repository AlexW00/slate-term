import Foundation
import SlateTermCore

nonisolated struct TerminalRunResult: Encodable, Sendable {
    let paneId: PaneID
    let sessionId: String
    let commandId: String
    let exitCode: Int?
    let text: String
    let truncated: Bool

    init(_ result: TerminalOperationResult) {
        paneId = result.paneId; sessionId = result.sessionId; commandId = result.commandId.uuidString
        exitCode = result.exitCode; text = result.text; truncated = result.truncated
    }
}

nonisolated enum TerminalRunError: Error, Equatable, Sendable, LocalizedError {
    case closed
    case invalidCommand(String)
    case invalidTimeout(Int)
    case overloaded(maximumPending: Int)
    case alreadyRunning(PaneID)
    case replaced, interrupted, editingBufferNotEmpty, timeout
    case unavailable, notReady, submissionFailed

    var errorDescription: String? {
        switch self {
        case .closed: return "Terminal run tracker is closed"
        case .invalidCommand(let reason): return "Invalid terminal command: \(reason)"
        case .invalidTimeout(let milliseconds):
            return "Terminal run timeout must be 1...295000 milliseconds (received \(milliseconds))"
        case .overloaded(let maximum): return "Terminal run tracker has reached its limit of \(maximum) pending runs"
        case .alreadyRunning(let pane): return "A terminal run is already pending for \(pane)"
        case .replaced: return "Terminal run session was removed or replaced"
        case .interrupted: return "Terminal run was interrupted by another shell command"
        case .editingBufferNotEmpty:
            return "Terminal is not at an empty prompt (a draft, continuation line or running program); nothing was submitted"
        case .timeout:
            return "Timed out waiting for terminal run completion; the operation remains tracked and the shell process was not stopped"
        case .unavailable: return "Terminal operation is unknown, expired, evicted, or belongs to another app lifetime"
        case .notReady: return "Terminal operation has no final result yet"
        case .submissionFailed: return "Terminal operation input could not be delivered"
        }
    }
}

/// Native adapter around the shared session-owned coordinator. No transport or
/// plugin lifetime is retained as the owner of an adopted shell operation.
/// The caller authenticates a live prompt before starting and forwards accepted
/// reports, including late ones; TerminalOperationStore pairs them by sequence.
@MainActor
final class TerminalRuns {
    static let maximumCommandBytes = TerminalOperationStore.maximumCommandBytes
    static let maximumTimeoutMilliseconds = TerminalOperations.maximumTimeoutMilliseconds
    static let maximumPendingRuns = TerminalOperationStore.maximumActive
    static let maximumOutputBytes = TerminalOutput.maximumBytes
    private let operations = TerminalOperations()

    var pendingCount: Int { operations.activeCount }
    var waitingCount: Int { operations.waiterCount }
    func displayCommand(pane: PaneID) -> String? { operations.displayCommand(pane: pane) }
    func reserve(_ panes: Set<PaneID>) throws { try mapped { try operations.reserve(panes) } }
    func releaseReservation(_ pane: PaneID) { operations.releaseReservation(pane) }
    /// Called only by the authenticated shell widget, after inspecting its actual edit buffer.
    func claimInput(pane: PaneID, sessionID: String, emptyBuffer: Bool) throws -> String {
        do { return try operations.claimInput(pane: pane, sessionId: sessionID, emptyBuffer: emptyBuffer) }
        catch TerminalOperationError.unavailable { throw TerminalRunError.replaced }
        catch TerminalOperationError.alreadyClaimed { throw TerminalRunError.replaced }
        catch { throw Self.map(error) }
    }
    func start(pane: PaneID, sessionID: String, command: String, shell: ShellKind = .zsh, baseline: Int? = nil,
               usingReservation: Bool = false, validateCaller: @MainActor () throws -> Void = {},
               send: () throws -> Void) throws -> UUID {
        try Self.validate(command)
        return try mapped { try operations.start(pane: pane, sessionId: sessionID, command: command, shell: shell, afterSequence: baseline,
            usingReservation: usingReservation, validateCaller: validateCaller, send: send) }
    }
    /// Blocking compatibility form of start + wait. Timeout and caller cancellation end
    /// only this wait; the adopted operation stays tracked under its commandId.
    func run(pane: PaneID, sessionID: String, command: String, timeoutMilliseconds: Int = 30_000,
             shell: ShellKind = .zsh, baseline: Int? = nil, usingReservation: Bool = false,
             validateCaller: @escaping @MainActor () throws -> Void = {}, send: () throws -> Void) async throws -> TerminalRunResult {
        try Self.validate(command)
        do {
            return TerminalRunResult(try await operations.run(pane: pane, sessionId: sessionID, command: command, shell: shell,
                afterSequence: baseline, timeoutMilliseconds: timeoutMilliseconds, usingReservation: usingReservation,
                validateCaller: validateCaller, send: send))
        } catch { throw Self.map(error) }
    }
    /// Keeps specific rejection reasons; the shared store applies the same bounds.
    private static func validate(_ command: String) throws {
        guard !command.isEmpty else { throw TerminalRunError.invalidCommand("command is empty") }
        guard !command.utf8.contains(0) else { throw TerminalRunError.invalidCommand("command contains NUL") }
        guard command.utf8.count <= maximumCommandBytes else {
            throw TerminalRunError.invalidCommand("command exceeds \(maximumCommandBytes) UTF-8 bytes")
        }
    }
    func wait(_ id: UUID, timeoutMilliseconds: Int, validateCaller: @escaping @MainActor () throws -> Void = {}) async throws -> TerminalRunResult {
        do { return TerminalRunResult(try await operations.wait(id, timeoutMilliseconds: timeoutMilliseconds, validateCaller: validateCaller)) }
        catch { throw Self.map(error) }
    }
    func status(_ id: UUID) throws -> TerminalOperationStatus { try mapped { try operations.status(id) } }
    func result(_ id: UUID) throws -> TerminalRunResult { try mapped { TerminalRunResult(try operations.result(id)) } }
    func list() -> [TerminalOperationStatus] { operations.list() }
    func observe(pane: PaneID, sessionID: String, report: ShellReport, capture: () -> String) {
        operations.observe(pane: pane, sessionId: sessionID, report: report, capture: capture)
    }
    func remove(pane: PaneID) { operations.remove(pane: pane) }
    func close() { operations.close() }

    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw Self.map(error) }
    }
    private static func map(_ error: Error) -> Error {
        switch error {
        case TerminalOperationError.invalidCommand:
            return TerminalRunError.invalidCommand("requires 1...\(maximumCommandBytes) UTF-8 bytes without NUL")
        case TerminalOperationError.alreadyRunning(let pane): return TerminalRunError.alreadyRunning(pane)
        case TerminalOperationError.capacity(let limit): return TerminalRunError.overloaded(maximumPending: limit)
        case TerminalOperationError.closed: return TerminalRunError.closed
        case TerminalOperationError.unavailable: return TerminalRunError.unavailable
        case TerminalOperationError.alreadyClaimed: return TerminalRunError.replaced
        case TerminalOperationError.editingBufferNotEmpty: return TerminalRunError.editingBufferNotEmpty
        case TerminalOperationError.notReady: return TerminalRunError.notReady
        case TerminalOperationError.failed(let failure):
            switch failure {
            case .editingBufferNotEmpty: return TerminalRunError.editingBufferNotEmpty
            case .sessionLost: return TerminalRunError.replaced
            case .otherCommand: return TerminalRunError.interrupted
            case .submissionFailed: return TerminalRunError.submissionFailed
            }
        case TerminalOperationWaitError.invalidTimeout(let value): return TerminalRunError.invalidTimeout(value)
        case TerminalOperationWaitError.capacity: return TerminalRunError.overloaded(maximumPending: TerminalOperations.maximumWaiters)
        case TerminalOperationWaitError.timeout: return TerminalRunError.timeout
        default: return error
        }
    }
}
