import Foundation
import SlateTermCore

nonisolated enum EventHubError: Error, Equatable, Sendable, LocalizedError {
    case closed
    case preparationConflict
    case invalidTimeout(Int)
    case overloaded(maximumPending: Int)

    var errorDescription: String? {
        switch self {
        case .closed: return "Event hub is closed"
        case .preparationConflict: return "Event publication changed during preparation or commit"
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
    private var committing = false
    private var closeAfterCommit = false
    private var publicationGeneration = UUID()
    private let identity = UUID()

    init(epoch: UUID = UUID(), reservedDeliveryBytes: Int = 0) throws {
        journal = try EventJournal(epoch: epoch, reservedDeliveryBytes: reservedDeliveryBytes)
    }

    struct PreparedBatch {
        fileprivate let owner: UUID
        fileprivate let expectedCursor: String
        fileprivate let generation: UUID
        fileprivate let journal: EventJournal
    }
    struct DeliveryBatch: Sendable {
        let batch: EventBatch
        let lineages: [String: OperationLineage]
    }

    func prepare(_ publications: [EventPublication]) throws -> PreparedBatch {
        guard !isClosed else { throw EventHubError.closed }
        guard !committing else { throw EventHubError.preparationConflict }
        var candidate = journal
        try candidate.appendBatch(publications)
        return PreparedBatch(owner: identity, expectedCursor: cursor, generation: publicationGeneration, journal: candidate)
    }

    /// No suspension or fallible work inside updatingModel: only assign the prepared model
    /// and revision values. Readers resume only after all three authoritative values agree.
    // preparingEffects is reserved for short synchronous, failure-atomic prerequisites (such
    // as catalog replacement). It must not publish, mutate the model or spin a run loop.
    func commit(_ prepared: PreparedBatch, preparingEffects: () throws -> Void = {}, updatingModel: () -> Void) throws {
        guard !isClosed else { throw EventHubError.closed }
        guard !committing, prepared.owner == identity, prepared.expectedCursor == cursor,
              prepared.generation == publicationGeneration else { throw EventHubError.preparationConflict }
        committing = true
        defer {
            committing = false
            if closeAfterCommit { closeAfterCommit = false; close() }
        }
        // An admitted attempt consumes the preparation even if a prerequisite fails. The
        // caller must freshly prepare, never implicitly replay possibly external effects.
        publicationGeneration = UUID()
        try preparingEffects()
        updatingModel()
        journal = prepared.journal
        resumeReaders()
    }

    @discardableResult
    func publish(
        topic: String,
        payload: JSONValue = .null,
        source: EventSource = .host,
        tab: TabID? = nil,
        pane: PaneID? = nil,
        targetInstanceId: String? = nil,
        lineage: OperationLineage? = nil
    ) throws -> WorkspaceEvent {
        guard !isClosed else { throw EventHubError.closed }
        guard !committing else { throw EventHubError.preparationConflict }
        let event = try journal.append(
            topic: topic, payload: payload, source: source, tab: tab, pane: pane,
            targetInstanceId: targetInstanceId, lineage: lineage
        )
        publicationGeneration = UUID()
        resumeReaders()
        return event
    }

    private func resumeReaders() {
        for id in Array(pending.keys) {
            guard var reader = pending[id] else { continue }
            do {
                let batch = try journal.batch(after: reader.cursor, filter: reader.filter, limit: reader.limit)
                if batch.events.isEmpty {
                    // Scan every publication, not just matches, before unrelated traffic can evict history.
                    reader.cursor = batch.cursor
                    pending[id] = reader
                } else {
                    finish(id, with: .success(delivery(batch)))
                }
            } catch {
                finish(id, with: .failure(error))
            }
        }
    }

    private func delivery(_ batch: EventBatch) -> DeliveryBatch {
        DeliveryBatch(batch: batch, lineages: Dictionary(uniqueKeysWithValues: batch.events.compactMap { event in
            journal.lineage(for: event.cursor).map { (event.cursor, $0) }
        }))
    }

    func poll(
        after: String? = nil,
        filter: EventFilter = .all,
        limit: Int = 128,
        waitMilliseconds: Int = 20_000
    ) async throws -> EventBatch {
        try await pollDelivery(after: after, filter: filter, limit: limit, waitMilliseconds: waitMilliseconds).batch
    }

    func pollDelivery(after: String? = nil, filter: EventFilter = .all, limit: Int = 128,
                      waitMilliseconds: Int = 20_000) async throws -> DeliveryBatch {
        guard !isClosed else { throw EventHubError.closed }
        guard (0...Self.maximumWaitMilliseconds).contains(waitMilliseconds) else {
            throw EventHubError.invalidTimeout(waitMilliseconds)
        }
        try Task.checkCancellation()
        // EventFilter validates at construction; the journal owns cursor and batch-limit validation.
        let batch = try journal.batch(after: after, filter: filter, limit: limit)
        if !batch.events.isEmpty || waitMilliseconds == 0 { return delivery(batch) }
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
        if committing { closeAfterCommit = true; return }
        isClosed = true
        for id in Array(pending.keys) { finish(id, with: .failure(EventHubError.closed)) }
    }

    private func expire(_ id: UUID) {
        guard let reader = pending[id] else { return }
        do {
            let batch = try journal.batch(after: reader.cursor, filter: reader.filter, limit: reader.limit)
            finish(id, with: .success(delivery(batch)))
        } catch {
            finish(id, with: .failure(error))
        }
    }

    private func finish(_ id: UUID, with result: Result<DeliveryBatch, Error>) {
        // Remove before resuming; old deadline/cancellation tasks can never resolve a successor.
        guard let reader = pending.removeValue(forKey: id) else { return }
        reader.timer.cancel()
        reader.continuation.resume(with: result)
    }

    private struct PendingPoll {
        var cursor: String
        let filter: EventFilter
        let limit: Int
        let continuation: CheckedContinuation<DeliveryBatch, Error>
        let timer: Task<Void, Never>
    }
}
