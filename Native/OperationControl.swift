import Foundation
import SlateTermCore

/// Outer-adapter admission only. Shared dispatch receives the resulting immutable context
/// and must not charge again. Native actions and transport cancellation bypass this adapter.
@MainActor
final class OperationControl {
    let epoch: UUID
    var administrativeAudience: CausationAudience { .administrative(epoch: epoch) }
    private var references: CausationReferences
    private var admission: MutationAdmission

    init(epoch: UUID) throws {
        self.epoch = epoch
        references = try CausationReferences(epoch: epoch)
        admission = try MutationAdmission()
    }

    static let descriptor: JSONValue = AutomationCapabilities.causation

    func admit(_ method: String, metadata: RPCMetadata?, origin: WorkspaceOperationContext.Origin,
               audience: CausationAudience, validateCaller: @escaping @MainActor @Sendable () throws -> Void = {}) throws -> WorkspaceOperationContext {
        try validateCaller()
        if case .service(let owner) = origin {
            guard case .service(let boundEpoch, let registration, let recipient) = audience,
                  boundEpoch == epoch, registration == owner.pluginID,
                  recipient.serviceID == owner.serviceID, recipient.generation == owner.generation else {
                throw RPCFailure(code: APIError.serviceSessionUnavailable, message: "Service session unavailable")
            }
        }
        do {
            let time = Self.now
            let lineage = try metadata?.cause.map { try references.derive(from: $0, audience: audience, now: time) } ?? OperationLineage()
            let mutationOrigin: MutationOrigin
            switch origin {
            case .native: mutationOrigin = .native
            case .administrative: mutationOrigin = .administrative
            case .plugin(let id, _, _): mutationOrigin = .plugin(id)
            case .service(let owner): mutationOrigin = .plugin(owner.pluginID)
            }
            try admission.admit(mutationOrigin, action: AdmissionAction.forMethod(method), now: time)
            // Presence is for agents driving the CLI. Plugin pages and services never show it, and
            // event-caused work never does either, so subscribers cannot loop on presence events.
            var actor: PresenceActor?
            if case .administrative = origin, metadata?.cause == nil { actor = metadata?.actor }
            return WorkspaceOperationContext(origin: origin, lineage: lineage, actor: actor, validateCaller: validateCaller)
        } catch { throw Self.failure(error) }
    }

    func deliveryContext(cursor: String, lineage: OperationLineage, audience: CausationAudience) throws -> String {
        do { return try references.issue(for: audience, eventCursor: cursor, lineage: lineage, now: Self.now) }
        catch { throw Self.failure(error) }
    }

    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
    private static func failure(_ error: any Error) -> RPCFailure {
        switch error {
        case OperationAdmissionError.contextUnavailable, OperationAdmissionError.invalidContext:
            return RPCFailure(code: -32055, message: "Delivery context is unavailable; inspect current state before starting new work")
        case OperationAdmissionError.depthExceeded:
            return RPCFailure(code: -32056, message: "Causal chain depth limit reached; stop the automation loop")
        case OperationAdmissionError.rateLimited(let retry):
            return RPCFailure(code: -32057, message: "Automation mutation rate limit reached", data: .object(["retryAfterMilliseconds": .integer(Int(retry))]))
        default:
            return RPCFailure(code: -32058, message: "Operation admission is unavailable")
        }
    }
}
