import Foundation

// Security validation waits for dispatched work. Keep blocking IO off Swift's cooperative pool.
// One serial queue bounds signature checks, file copies, and subprocess waits.
nonisolated final class BlockingIOExecutor: TaskExecutor {
    static let shared = BlockingIOExecutor()
    private let queue = DispatchQueue(label: "com.slateterm.blocking-io", qos: .utility)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }

    /// Cancellation never releases worker-owned resources before the worker finishes.
    static func run<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        let task = Task.detached(executorPreference: shared, priority: .utility) {
            try Task.checkCancellation()
            return try body()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Finalization must finish even when the requesting task has been cancelled.
    static func finish<Value: Sendable>(_ body: @escaping @Sendable () -> Value) async -> Value {
        await Task.detached(executorPreference: shared, priority: .utility) { body() }.value
    }
}
