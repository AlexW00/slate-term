import AppKit
import Foundation
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    static let pluginPersistenceDescriptor: JSONValue = AutomationCapabilities.pluginPersistence

    func callPluginPersistence(_ method: AutomationMethod, params: [String: JSONValue], operation: WorkspaceOperationContext) throws -> JSONValue {
        try operation.validateCaller()
        func string(_ key: String) throws -> String {
            guard let text = params[key]?.string, !text.isEmpty else { throw RPCFailure(code: -32602, message: "\(key) is required") }
            return text
        }
        func keys(_ allowed: Set<String>) throws {
            guard Set(params.keys).isSubset(of: allowed) else { throw RPCFailure(code: -32602, message: "Unknown \(method.rawValue) parameter") }
        }
        let data = [.pluginDataGet, .pluginDataPatch, .pluginDataReset].contains(method)
        let get = method == .pluginDataGet || method == .panelStateGet
        let reset = method == .pluginDataReset || method == .panelStateReset
        if data {
            var allowed: Set<String> = ["id", "expectedInstanceId"]
            if !get { allowed.insert("expectedDataRevision"); allowed.insert(reset ? "force" : "operations") }
            try keys(allowed)
            let id = try string("id")
            try PluginPersistence.validateID(id)
            let directory = settings.base.appendingPathComponent("state/plugin-data-v2")
            guard hasPluginRegistration(id) || FileManager.default.fileExists(atPath: directory.appendingPathComponent(id + ".json").path) else {
                throw RPCFailure(code: APIError.unavailable, message: "No registered plugin or retained data for this ID")
            }
            let store: PluginDataStore
            if let cached = pluginDataStores[id] { store = cached }
            else {
                do { store = try PluginDataStore(directory: directory, id: id) }
                catch { throw RPCFailure(code: APIError.incompatible, message: "Plugin data is unreadable or incompatible; its file has been preserved") }
                pluginDataStores[id] = store
            }
            let before = store.document
            if get { return .object(["id": .string(id), "values": .object(before.values), "revision": .string(before.revision)]) }
            if reset, params["force"] != .bool(true) { throw RPCFailure(code: -32602, message: "Deleting shared plugin data requires force:true") }
            if !reset, params["operations"] == nil { throw RPCFailure(code: -32602, message: "operations is required") }
            let candidate = try before.changing(operations: reset ? nil : params["operations"], expectedRevision: string("expectedDataRevision"))
            if candidate != before {
                var fields = PluginPersistence.summary(before: before.values, after: candidate.values)
                fields["pluginId"] = .string(id); fields["beforeRevision"] = .string(before.revision)
                fields["revision"] = .string(candidate.revision); fields["reset"] = .bool(reset)
                // One untargeted invalidation reaches all scopes and services, with no live-instance fan-out.
                let publication = operation.publication(topic: "host.plugin.data.changed", payload: fields)
                if rejectNextPluginDataPublication {
                    rejectNextPluginDataPublication = false
                    throw RPCFailure(code: APIError.unavailable, message: "Injected plugin data publication rejection")
                }
                try events.commitWorkspace([publication], beforeCommit: {
                    try operation.validateCaller()
                    do { try store.persist(candidate) }
                    catch { throw RPCFailure(code: APIError.settingsWriteFailed, message: "Could not save plugin data; previous state is retained", data: .object(["persisted": .bool(false), "revision": .string(before.revision)])) }
                }) { store.accept(candidate) }
            }
            return .object(["id": .string(id), "revision": .string(candidate.revision), "changed": .bool(candidate != before),
                "persisted": .bool(true), "operationId": .string(operation.lineage.operationID.uuidString)])
        }
        guard [.panelStateGet, .panelStatePatch, .panelStateReset].contains(method) else { throw RPCFailure(code: -32601, message: "Unknown plugin persistence method") }
        var allowed: Set<String> = ["pane", "tab", "expectedInstanceId", "expectedWorkspaceRevision"]
        if !get { allowed.formUnion(["expectedPanelId", "expectedStateRevision"]); if !reset { allowed.insert("operations") } }
        try keys(allowed)
        let paneID = try PaneID(parsing: string("pane")) // Deliberately no active/focused-pane fallback.
        guard let pane = workspace.panes.first(where: { $0.id == paneID }), let before = pane.pluginPanel else {
            throw RPCFailure(code: APIError.unavailable, message: "A registered-plugin pane is required")
        }
        _ = try workspace.resolvedTab(pane: paneID, tab: params["tab"]?.string.map(TabID.init(parsing:)))
        func result(_ record: PluginPanelRecord) -> [String: JSONValue] {
            ["pluginId": .string(pane.type.identifier), "paneId": .string(paneID.description), "panelId": .string(record.panelId), "revision": .string(record.stateRevision)]
        }
        if get { var fields = result(before); fields["values"] = .object(before.state); return .object(fields) }
        if !reset, params["operations"] == nil { throw RPCFailure(code: -32602, message: "operations is required") }
        var next = workspace
        try next.patchPluginState(paneID, expectedPanelId: string("expectedPanelId"), expectedRevision: string("expectedStateRevision"), operations: reset ? nil : params["operations"])
        let transition = try WorkspaceTransition(observing: next, from: workspace, revisions: revisions, action: reset ? .pluginPanelReset : .pluginPanelPatch)
        try commitWorkspace(transition, operation: operation)
        let record = next.panes.first { $0.id == paneID }!.pluginPanel!
        var fields = result(record); fields["changed"] = .bool(transition.changed)
        // No native reconciliation/focus. Even an equal patch can recover a previous failed save.
        return operationResult(.object(fields), transition: transition, operation: operation, workspacePersistence: persistWorkspace())
    }

    /// Called before constructing the final transition, never during native reconciliation.
    func preparePluginConfigurations(_ next: inout Workspace, recipes: [PaneID: SavedLayoutPane] = [:]) throws {
        for pane in next.panes {
            guard let panel = pane.pluginPanel,
                  workspace.panes.first(where: { $0.id == pane.id })?.pluginPanel?.panelId != panel.panelId else { continue }
            guard let registration = pluginPanelRegistration(pane.type.identifier) else { throw RPCFailure(code: -32602, message: "Plugin panel type is unavailable") }
            let defaults = Dictionary(uniqueKeysWithValues: registration.layoutFields.compactMap { field in field.defaultValue.map { (field.id, $0) } })
            let configuration = defaults.merging(recipes[pane.id]?.configuration ?? panel.configuration) { _, explicit in explicit }
            for field in registration.layoutFields {
                if let problem = field.problem(configuration[field.id]) {
                    throw RPCFailure(code: -32602, message: "\(problem). Open a saved layout with the required plugin configuration.")
                }
            }
            try next.setPluginConfiguration(configuration, for: pane.id)
        }
        try next.validatePluginPanels()
    }
}
