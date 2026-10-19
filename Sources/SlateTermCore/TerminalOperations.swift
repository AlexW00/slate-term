import Foundation

public enum TerminalOperationWaitError: Error, Equatable, Sendable {
    case invalidTimeout(Int)
    case capacity
    case timeout
}

/// The app owns this coordinator. Each waiter owns only its continuation/deadline;
/// cancellation never sends terminal input or retires the session's operation.
@MainActor
public final class TerminalOperations {
    public nonisolated static let maximumWaiters = 32
    public nonisolated static let maximumTimeoutMilliseconds = 295_000
    private var store = TerminalOperationStore()
    private var closed = false
    private struct Waiter {
        let operation: UUID
        let continuation: CheckedContinuation<TerminalOperationResult, Error>
        let timer: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]
    private var waitReservations = Set<UUID>()
    // One host callback per adopted operation, bounded by the active operation limit.
    private var completions: [UUID: @MainActor (TerminalOperationStatus) -> Void] = [:]

    public init() {}
    public var activeCount: Int { store.activeCount }
    public var waiterCount: Int { waiters.count }
    public func reserve(_ panes: Set<PaneID>) throws { try store.reserve(panes) }
    public func releaseReservation(_ pane: PaneID) { store.releaseReservation(pane) }
    public func displayCommand(pane: PaneID) -> String? { store.displayCommand(pane: pane) }
    public func status(_ id: UUID) throws -> TerminalOperationStatus { try store.status(id) }
    public func result(_ id: UUID) throws -> TerminalOperationResult { try store.result(id) }
    public func list() -> [TerminalOperationStatus] { store.list() }

    /// Validate before adoption, never again at the editor claim on behalf of the
    /// original caller. Return the handle even when delivery fails after adoption;
    /// its retained status tells the caller what happened without losing identity.
    public func start(pane: PaneID, sessionId: String, command: String, shell: ShellKind = .zsh, afterSequence: Int?,
                      usingReservation: Bool = false,
                      onCompletion: (@MainActor (TerminalOperationStatus) -> Void)? = nil,
                      validateCaller: @MainActor () throws -> Void = {}, send: () throws -> Void) throws -> UUID {
        try Task.checkCancellation()
        try validateCaller()
        try Task.checkCancellation()
        let status = try store.start(pane: pane, sessionId: sessionId, command: command, shell: shell,
                                     afterSequence: afterSequence, usingReservation: usingReservation)
        completions[status.commandId] = onCompletion
        do { try send() }
        catch { store.submissionFailed(status.commandId) }
        resolveFinishedOperations()
        return status.commandId
    }

    public func claimInput(pane: PaneID, sessionId: String, emptyBuffer: Bool) throws -> String {
        defer { resolveFinishedOperations() }
        return try store.claimInput(pane: pane, sessionId: sessionId, emptyBuffer: emptyBuffer)
    }

    public func observe(pane: PaneID, sessionId: String, report: ShellReport, capture: () -> String) {
        if let id = store.observe(pane: pane, sessionId: sessionId, report: report) {
            // Do not hold an inout access to the model across a reentrant capture.
            let text = capture()
            store.completeCapture(id, text: text)
        }
        resolveFinishedOperations()
    }

    public func loseSession(pane: PaneID, sessionId: String) {
        store.loseSession(pane: pane, sessionId: sessionId)
        resolveFinishedOperations()
    }

    /// Authoritative pane disposal, not a stale session callback.
    public func remove(pane: PaneID) {
        store.releaseReservation(pane)
        let sessions = Set(store.list().filter { $0.paneId == pane && !$0.state.isFinished }.map(\.sessionId))
        for session in sessions { store.loseSession(pane: pane, sessionId: session) }
        resolveFinishedOperations()
    }

    public func close() {
        closed = true
        store.close()
        resolveFinishedOperations()
    }

    public func wait(_ id: UUID, timeoutMilliseconds: Int = 30_000,
                     validateCaller: @escaping @MainActor () throws -> Void = {}) async throws -> TerminalOperationResult {
        try await wait(id, timeoutMilliseconds: timeoutMilliseconds, reservation: nil, validateCaller: validateCaller)
    }

    /// Compatibility convenience: reserve wait capacity BEFORE adopting/sending work.
    /// A full waiter queue must not turn a blocking request into an unexpected start.
    public func run(pane: PaneID, sessionId: String, command: String, shell: ShellKind = .zsh, afterSequence: Int?,
                    timeoutMilliseconds: Int = 30_000, usingReservation: Bool = false,
                    validateCaller: @escaping @MainActor () throws -> Void = {}, send: () throws -> Void) async throws -> TerminalOperationResult {
        try Self.validateTimeout(timeoutMilliseconds)
        try Task.checkCancellation()
        guard !closed else { throw TerminalOperationError.closed }
        guard waiters.count + waitReservations.count < Self.maximumWaiters else { throw TerminalOperationWaitError.capacity }
        let reservation = UUID()
        waitReservations.insert(reservation)
        defer { waitReservations.remove(reservation) }
        let id = try start(pane: pane, sessionId: sessionId, command: command, shell: shell, afterSequence: afterSequence,
                           usingReservation: usingReservation, validateCaller: validateCaller, send: send)
        return try await wait(id, timeoutMilliseconds: timeoutMilliseconds, reservation: reservation, validateCaller: validateCaller)
    }

    private func wait(_ operation: UUID, timeoutMilliseconds: Int, reservation: UUID?,
                      validateCaller: @escaping @MainActor () throws -> Void) async throws -> TerminalOperationResult {
        try Self.validateTimeout(timeoutMilliseconds)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        let id = UUID()
        let result: TerminalOperationResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try Task.checkCancellation()
                    try validateCaller()
                    // Recheck inside registration: completion/cancellation can precede
                    // handler installation, and ready results need no wait slot.
                    if try store.status(operation).state.isFinished {
                        continuation.resume(returning: try store.result(operation))
                        return
                    }
                    if let reservation {
                        guard waitReservations.remove(reservation) != nil else { throw TerminalOperationWaitError.capacity }
                    } else {
                        guard waiters.count + waitReservations.count < Self.maximumWaiters else { throw TerminalOperationWaitError.capacity }
                    }
                    let timer = Task { @MainActor [weak self] in
                        do { try await Task.sleep(until: deadline, clock: .continuous) }
                        catch { return }
                        self?.finishWaiter(id, result: .failure(TerminalOperationWaitError.timeout))
                    }
                    waiters[id] = Waiter(operation: operation, continuation: continuation, timer: timer)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.finishWaiter(id, result: .failure(CancellationError())) }
        }
        try Task.checkCancellation()
        try validateCaller()
        return result
    }

    private static func validateTimeout(_ milliseconds: Int) throws {
        guard (1...maximumTimeoutMilliseconds).contains(milliseconds) else { throw TerminalOperationWaitError.invalidTimeout(milliseconds) }
    }
    private func resolveFinishedOperations() {
        // Remove before invocation: a completion may reenter the coordinator.
        for id in Array(completions.keys) {
            guard let status = try? store.status(id), status.state.isFinished else { continue }
            completions.removeValue(forKey: id)?(status)
        }
        for (id, waiter) in waiters {
            do {
                guard try store.status(waiter.operation).state.isFinished else { continue }
                finishWaiter(id, result: .success(try store.result(waiter.operation)))
            } catch { finishWaiter(id, result: .failure(error)) }
        }
    }
    private func finishWaiter(_ id: UUID, result: Result<TerminalOperationResult, Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(with: result)
    }
}
