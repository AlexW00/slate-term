import Foundation
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    static let welcomeDescriptor: JSONValue = .object([
        "version": .integer(1), "getMethod": .string("welcome.get"),
        "readCommand": .string("welcome.read"), "unreadCommand": .string("welcome.unread"), "resetCommand": .string("welcome.reset"),
        "scope": .string("appStateDirectory"), "presentation": .string("nativeInline"),
        "shellIntegrationRequired": .bool(false), "resetAffects": .string("futureTerminalSessions"),
        "eventTopic": .string("host.welcome.changed"), "guard": .string("expectedInstanceId"),
        "resultFields": .array(["content", "acknowledged", "automaticDisplayEnabled", "revision", "error"].map(JSONValue.string)),
        "errors": .object(["invalid": .integer(-32602), "writeFailed": .integer(APIError.settingsWriteFailed)])
    ])

    func welcomeInfo(_ params: [String: JSONValue]) throws -> JSONValue {
        try validateWelcomeParameters(params)
        return try .encoding(settings.welcome.snapshot)
    }

    func changeWelcome(_ acknowledged: Bool, params: [String: JSONValue], operation: WorkspaceOperationContext) throws -> JSONValue {
        try validateWelcomeParameters(params)
        try operation.validateCaller()
        let store = settings.welcome
        let before = store.snapshot
        let changed = before.acknowledged != acknowledged
        func publication(_ revision: String) -> EventPublication {
            // Like configuration preferences, broadcast state without private caller IDs or paths.
            EventPublication(topic: "host.welcome.changed", payload: .object([
                "operationId": .string(operation.lineage.operationID.uuidString),
                "beforeRevision": .string(before.revision), "revision": .string(revision),
                "acknowledged": .bool(acknowledged)
            ]), source: .host, lineage: operation.lineage)
        }
        if changed {
            try events.preflight([publication(UUID().uuidString)])
            do { try store.setAcknowledged(acknowledged) }
            catch {
                throw RPCFailure(code: APIError.settingsWriteFailed, message: "Could not save the welcome preference; the previous state is retained.",
                                 data: .object(["persisted": .bool(false), "revision": .string(before.revision)]))
            }
            // A page/CLI/service may change this while Cmd-K is already open.
            defer { refreshCommandPicker() }
            // A successful preference save is not a rollbackable workspace mutation.
            // Publish before touching native layout (which may call back into the host).
            do { try events.publishOperation(publication(store.revision)) }
            catch {
                if acknowledged { dismissNativeWelcomes() }
                throw RPCFailure(code: APIError.unavailable, message: "Welcome preference was saved, but event publication failed; read welcome.get before retrying.",
                                 data: .object(["persisted": .bool(true), "revision": .string(store.revision)]))
            }
        }
        if acknowledged { dismissNativeWelcomes() }
        var result = try JSONValue.encoding(store.snapshot).object!
        result["changed"] = .bool(changed)
        result["persisted"] = .bool(true)
        result["operationId"] = .string(operation.lineage.operationID.uuidString)
        return .object(result)
    }

    private func validateWelcomeParameters(_ params: [String: JSONValue]) throws {
        guard Set(params.keys).isSubset(of: ["expectedInstanceId"]) else {
            throw RPCFailure(code: -32602, message: "Welcome operations accept only expectedInstanceId; they do not target a pane or workspace.")
        }
    }

    private func dismissNativeWelcomes() {
        for container in containers.values { container.dismissWelcome() }
    }
}
