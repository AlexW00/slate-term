import Foundation
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    static let serviceControlMethods = ["plugins.service.start", "plugins.service.stop", "plugins.service.list", "plugins.service.status", "plugins.service.logs"]
    static let serviceMethods = ["api.describe", "workspace.snapshot", "pane.inspect", "settings.get", "plugins.settings.get", "events.head", "events.poll", "command.list", "command.run", "service.ready"]

    static var serviceDescriptor: JSONValue {
        .object(["version": .integer(1), "mode": .string("manual"), "automaticStartup": .bool(false), "automaticRestart": .bool(false),
                 "maximumReservations": .integer(16), "maximumPeers": .integer(4), "maximumPolls": .integer(1),
                 "logBytesPerStream": .integer(65_536), "explicitPaneTargets": .bool(true),
                 "states": .array(["stopped", "starting", "ready", "stopping", "failed"].map(JSONValue.string)),
                 "topic": .string("host.service.state.changed")])
    }

    func describeServiceAPI() throws -> JSONValue {
        // Do not advertise broader page/administrative capabilities on this endpoint.
        .object(["apiVersion": .integer(1), "appInstanceId": .string(instanceID), "surface": .string("service"),
                 "identityGuards": .bool(true), "guards": .array(["expectedInstanceId", "expectedWorkspaceRevision", "expectedLayoutRevision", "expectedAnchorSessionId"].map(JSONValue.string)),
                 "methods": .array(Self.serviceMethods.map(JSONValue.string)), "backgroundServices": Self.serviceDescriptor,
                 "causation": OperationControl.descriptor])
    }

    func callService(_ method: String, params: [String: JSONValue], operation: WorkspaceOperationContext) async throws -> JSONValue {
        guard let owner = operation.serviceOwner, Self.serviceMethods.contains(method) else {
            throw RPCFailure(code: APIError.forbidden, message: "Method is not exposed to services")
        }
        try operation.validateCaller()
        if params["expectedLayoutRevision"] != nil && params["pane"] == nil && params["tab"] == nil {
            throw RPCFailure(code: -32602, message: "Service layout guards require an explicit target")
        }
        try validateAPIGuards(params, method: method)
        let input = withoutAPIGuards(params)
        switch method {
        case "api.describe":
            guard input.isEmpty else { throw RPCFailure(code: -32602, message: "api.describe takes no parameters") }
            return try describeServiceAPI()
        case "workspace.snapshot":
            if params["scope"] != nil && params["scope"] != .string("global") && params["pane"] == nil {
                throw RPCFailure(code: -32602, message: "Scoped service snapshots require an explicit pane")
            }
            return try workspaceSnapshot(params)
        case "pane.inspect":
            guard params["pane"] != nil else { throw RPCFailure(code: -32602, message: "An explicit pane is required") }
            return try inspectPane(targetPaneID(params))
        case "settings.get", "plugins.settings.get":
            guard Set(input.keys).isSubset(of: ["id"]), input["id"] == nil || input["id"] == .string(owner.pluginID) else {
                throw RPCFailure(code: APIError.forbidden, message: "Service settings are bound to the caller's namespace")
            }
            if method == "settings.get" { return .object(settings.current.plugins[owner.pluginID] ?? [:]) }
            do { return try pluginSettingsInfo(["id": .string(owner.pluginID)]) }
            catch { throw pluginSettingsFailure(error) }
        case "events.head":
            guard input.isEmpty else { throw RPCFailure(code: -32602, message: "events.head takes no parameters") }
            return events.head
        case "events.poll":
            let audience = CausationAudience.service(epoch: operations.epoch, registrationID: owner.pluginID,
                recipient: try ServiceEventRecipient(serviceID: owner.serviceID, generation: owner.generation))
            return try await events.poll(input, audience: audience, validateCaller: operation.validateCaller)
        case "command.list":
            guard input.isEmpty else { throw RPCFailure(code: -32602, message: "command.list takes no parameters") }
            return try .encoding(availableCommands.filter { $0.id.hasPrefix("plugin.") })
        case "command.run":
            guard let id = params["id"]?.string, id.hasPrefix("plugin.") else {
                throw RPCFailure(code: APIError.forbidden, message: "Only contributed commands are exposed to services")
            }
            return try await runServiceCommand(id, params: params, operation: operation)
        default: throw RPCFailure(code: APIError.forbidden, message: "Method is not exposed to services")
        }
    }
}
