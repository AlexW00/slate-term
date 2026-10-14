import Foundation
import SlateTermCore

nonisolated enum EventHubError: Error, Equatable, Sendable, LocalizedError {
    case closed
    case invalidTimeout(Int)
    case overloaded(maximumPending: Int)

    var errorDescription: String? {
        switch self {
        case .closed: return "Event hub is closed"
        case .invalidTimeout(let milliseconds):
            return "Event poll wait must be 0...25000 milliseconds (received \(milliseconds))"
        case .overloaded(let maximumPending):
            return "Event hub has reached its limit of \(maximumPending) pending polls"
        }
    }
}

/// Owns journal synchronization and bounded long polls; publication scans readers on the main actor.
@MainActor
final class EventHub {
    static let maximumWaitMilliseconds = 25_000
    static let maximumPendingCallers = 128

    var cursor: String { journal.cursor }
    var pendingCount: Int { pending.count }

    private var journal: EventJournal
    private var pending: [UUID: PendingPoll] = [:]
    private var isClosed = false

    init(epoch: UUID = UUID()) throws {
        journal = try EventJournal(epoch: epoch)
    }

    @discardableResult
    func publish(
        topic: String,
        payload: JSONValue = .null,
        source: EventSource = .host,
        tab: TabID? = nil,
        pane: PaneID? = nil,
        targetInstanceId: String? = nil
    ) throws -> WorkspaceEvent {
        guard !isClosed else { throw EventHubError.closed }
        let event = try journal.append(
            topic: topic, payload: payload, source: source, tab: tab, pane: pane,
            targetInstanceId: targetInstanceId
        )
        for id in Array(pending.keys) {
            guard var reader = pending[id] else { continue }
            do {
                let batch = try journal.batch(after: reader.cursor, filter: reader.filter, limit: reader.limit)
                if batch.events.isEmpty {
                    // Scan every publication, not just matches, before unrelated traffic can evict history.
                    reader.cursor = batch.cursor
                    pending[id] = reader
                } else {
                    finish(id, with: .success(batch))
                }
            } catch {
                finish(id, with: .failure(error))
            }
        }
        return event
    }

    func poll(
        after: String? = nil,
        filter: EventFilter = .all,
        limit: Int = 128,
        waitMilliseconds: Int = 20_000
    ) async throws -> EventBatch {
        guard !isClosed else { throw EventHubError.closed }
        guard (0...Self.maximumWaitMilliseconds).contains(waitMilliseconds) else {
            throw EventHubError.invalidTimeout(waitMilliseconds)
        }
        try Task.checkCancellation()
        // EventFilter validates at construction; the journal owns cursor and batch-limit validation.
        let batch = try journal.batch(after: after, filter: filter, limit: limit)
        if !batch.events.isEmpty || waitMilliseconds == 0 { return batch }
        guard pending.count < Self.maximumPendingCallers else {
            throw EventHubError.overloaded(maximumPending: Self.maximumPendingCallers)
        }
        let id = UUID()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(waitMilliseconds))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Cancellation can precede handler installation or race registration.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    self?.expire(id)
                }
                pending[id] = PendingPoll(
                    cursor: batch.cursor, filter: filter, limit: limit,
                    continuation: continuation, timer: timer
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish(id, with: .failure(CancellationError()))
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        for id in Array(pending.keys) { finish(id, with: .failure(EventHubError.closed)) }
    }

    private func expire(_ id: UUID) {
        guard let reader = pending[id] else { return }
        do {
            let batch = try journal.batch(after: reader.cursor, filter: reader.filter, limit: reader.limit)
            finish(id, with: .success(batch))
        } catch {
            finish(id, with: .failure(error))
        }
    }

    private func finish(_ id: UUID, with result: Result<EventBatch, Error>) {
        // Remove before resuming; old deadline/cancellation tasks can never resolve a successor.
        guard let reader = pending.removeValue(forKey: id) else { return }
        reader.timer.cancel()
        reader.continuation.resume(with: result)
    }

    private struct PendingPoll {
        var cursor: String
        let filter: EventFilter
        let limit: Int
        let continuation: CheckedContinuation<EventBatch, Error>
        let timer: Task<Void, Never>
    }
}
