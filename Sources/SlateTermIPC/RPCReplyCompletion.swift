import Foundation

/// Defers process-lifetime actions until a transport finishes its current reply.
@MainActor
public final class RPCReplyCompletion {
    @TaskLocal public static var current: RPCReplyCompletion?
    private var completed = false
    private var actions: [@MainActor () -> Void] = []
    private var deadline: Task<Void, Never>?
    private let onTimeout: @MainActor () -> Void

    public init(onTimeout: @escaping @MainActor () -> Void = {}) { self.onTimeout = onTimeout }

    public var hasPendingActions: Bool { !completed && !actions.isEmpty }

    /// Native calls have no reply; schedule their action on the next main-queue turn.
    public static func afterReply(_ action: @escaping @MainActor () -> Void) {
        guard let current, !current.completed else {
            DispatchQueue.main.async(execute: action)
            return
        }
        current.actions.append(action)
        current.armDeadline()
    }

    private func armDeadline() {
        guard deadline == nil else { return }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard let self, !self.completed else { return }
            self.onTimeout()
            self.finish()
        }
    }

    /// A disconnected caller cannot receive a reply, but committed actions still finish.
    public func finish() {
        guard !completed else { return }
        completed = true
        deadline?.cancel()
        deadline = nil
        let pending = actions
        actions.removeAll()
        for action in pending { DispatchQueue.main.async(execute: action) }
    }
}
