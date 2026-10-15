import Foundation
import SlateTermCore

extension WorkspaceHost {
    func commitWorkspace(_ transition: WorkspaceTransition, operation: WorkspaceOperationContext,
                         additionalPublications: [EventPublication] = [], beforeCommit: () throws -> Void = {}) throws {
        try operation.validateCaller()
        try transition.requireCurrentBase(workspace: workspace, revisions: revisions)
        let publications = transition.changes.map(operation.publication) + additionalPublications
        try events.commitWorkspace(publications, beforeCommit: {
            if case .native = operation.origin {} else if rejectNextWorkspacePublication && !publications.isEmpty {
                rejectNextWorkspacePublication = false
                throw RPCFailure(code: APIError.unavailable, message: "Injected workspace publication rejection")
            }
            try beforeCommit()
        }) {
            workspace = transition.workspace
            revisions = transition.revisions
        }
    }

    func operationResult(_ result: JSONValue, transition: WorkspaceTransition,
                         operation: WorkspaceOperationContext, workspacePersistence: WorkspacePersistence,
                         committedExternalEffect: Bool = false) -> JSONValue {
        guard var object = result.object else { return result }
        object["operationId"] = .string(operation.lineage.operationID.uuidString)
        // A separately attributed native editor completion may follow reconciliation before
        // the reply is sent. Correlate this result with this operation, not that later revision.
        object["workspaceRevision"] = .string(transition.revisions.revision)
        object["outcome"] = .string(transition.changed || committedExternalEffect ? "committed" : "unchanged")
        object["workspacePersistence"] = .string(workspacePersistence.rawValue)
        return .object(object)
    }
}
