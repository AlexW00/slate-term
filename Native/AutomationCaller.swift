import Foundation
import SlateTermCore

/// Created only by a transport/lifetime adapter after its native binding checks.
/// Context supplies defaults and ownership, never a different set of API powers.
struct AutomationCaller: Sendable {
    let origin: WorkspaceOperationContext.Origin
    let audience: CausationAudience
    let defaults: AutomationDefaults
    let validate: @MainActor @Sendable () throws -> Void

    init(origin: WorkspaceOperationContext.Origin, audience: CausationAudience,
         defaults: AutomationDefaults = .init(), validate: @escaping @MainActor @Sendable () throws -> Void = {}) {
        self.origin = origin; self.audience = audience; self.defaults = defaults; self.validate = validate
    }

    @MainActor
    func admit(_ method: String, metadata: RPCMetadata?, through operations: OperationControl) throws -> WorkspaceOperationContext {
        try validate()
        return try operations.admit(method, metadata: metadata, origin: origin, audience: audience, validateCaller: validate)
    }
}
