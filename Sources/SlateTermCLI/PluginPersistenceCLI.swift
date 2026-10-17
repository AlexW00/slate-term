import ArgumentParser
import Foundation
import SlateTermCore

extension Plugins {
    func runPersistence() throws {
        guard let verb = id, ["get", "patch", "reset"].contains(verb), manifest == nil, instanceId == nil, !replace, expectedWriteRevision == nil else {
            throw ValidationError("Use plugins data|panel-state get|patch|reset; registration/process/settings options do not apply")
        }
        let data = action == .data
        var params: [String: JSONValue]
        if data {
            guard let namespace, pane == nil, tab == nil, expectedPanelId == nil, expectedStateRevision == nil, expectedWorkspaceRevision == nil else {
                throw ValidationError("plugins data requires a plugin ID, not a pane or workspace")
            }
            try PluginPersistence.validateID(namespace)
            params = ["id": .string(namespace)]
            if verb == "get" {
                guard expectedDataRevision == nil else { throw ValidationError("get does not take a write revision") }
            } else {
                guard let expectedDataRevision else { throw ValidationError("data writes require --expected-data-revision") }
                params["expectedDataRevision"] = .string(expectedDataRevision)
            }
            guard verb == "reset" ? force : !force else { throw ValidationError("Only data reset requires --force") }
            if force { params["force"] = .bool(true) }
        } else {
            guard namespace == nil, expectedDataRevision == nil, !force else { throw ValidationError("panel-state takes a pane, not a namespace, data revision or --force") }
            params = try APITarget.resolve(pane: pane, tab: tab, socket: connection.socket, instance: connection.expectedInstanceId, environment: ProcessInfo.processInfo.environment)
            // Panel content has its own identity guard; it is not a terminal session.
            params.removeValue(forKey: "expectedAnchorSessionId")
            guard params["pane"] != nil else { throw ValidationError("panel-state requires --pane or an inherited pane; focus is never inferred") }
            if let expectedWorkspaceRevision { params["expectedWorkspaceRevision"] = .string(expectedWorkspaceRevision) }
            if verb == "get" {
                guard expectedPanelId == nil, expectedStateRevision == nil else { throw ValidationError("get does not take state write guards") }
            } else {
                guard let expectedPanelId, let expectedStateRevision else { throw ValidationError("panel-state writes require --expected-panel-id and --expected-state-revision") }
                params["expectedPanelId"] = .string(expectedPanelId)
                params["expectedStateRevision"] = .string(expectedStateRevision)
            }
        }
        if verb == "patch" {
            guard let operations else { throw ValidationError("patch requires --operations") }
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(operations.utf8))
            // Shape/per-value bounds can be checked offline; the host checks the resulting document.
            _ = try PluginPersistence.patch([:], operations: value, panel: !data)
            params["operations"] = value
        } else if operations != nil { throw ValidationError("Only patch accepts --operations") }
        try connection.call("plugins.\(data ? "data" : "panelState").\(verb)", params: params)
    }
}
