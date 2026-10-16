import Foundation
import SlateTermCore

extension WorkspaceHost {
    func commitWorkspace(_ transition: WorkspaceTransition, operation: WorkspaceOperationContext,
                         additionalPublications: [EventPublication] = [], beforeCommit: () throws -> Void = {}) throws {
        try operation.validateCaller()
        try transition.requireCurrentBase(workspace: workspace, revisions: revisions)
        let previous = workspace
        let rebindings = Set(workspace.panes.compactMap { pane -> PaneID? in
            guard let before = try? workspace.resolvedTab(pane: pane.id),
                  let after = try? transition.workspace.resolvedTab(pane: pane.id), before.id != after.id else { return nil }
            return pane.id
        })
        let publications = transition.changes.map { change in
            var fields = change.payload
            if change.topic == "host.pane.moved", let pane = change.pane {
                fields["contentRecreated"] = .bool(rebindings.contains(pane) && (leaves[pane] as? PluginPane)?.instance.registration.scope == .tab)
            }
            return operation.publication(topic: change.topic, payload: fields, tab: change.tab, pane: change.pane)
        } + additionalPublications
        try events.commitWorkspace(publications, rebindingPanes: rebindings, beforeCommit: {
            if case .native = operation.origin {} else if rejectNextWorkspacePublication && !publications.isEmpty {
                rejectNextWorkspacePublication = false
                throw RPCFailure(code: APIError.unavailable, message: "Injected workspace publication rejection")
            }
            try beforeCommit()
        }) {
            workspace = transition.workspace
            revisions = transition.revisions
        }
        invalidateTabRename(from: previous)
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
