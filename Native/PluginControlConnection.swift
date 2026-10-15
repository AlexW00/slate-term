import Foundation
import SlateTermCore

/// Host-owned connection capsule. Credentials never enter operation facts or status output.
struct PluginControlConnection: Sendable {
    let socketPath: String
    let appInstanceID: String
    let cliPath: String
    let service: ServiceCredentials?

    init(socketPath: String, appInstanceID: String, cliPath: String, service: ServiceCredentials? = nil) {
        self.socketPath = socketPath; self.appInstanceID = appInstanceID
        self.cliPath = cliPath; self.service = service
    }

    func commandEnvironment(owner: ServiceIdentity?) throws -> [String: String] {
        guard owner == service?.identity,
              owner == nil || owner?.appInstanceID == appInstanceID,
              socketPath.hasPrefix("/"), !socketPath.contains("\0") else {
            throw RPCFailure(code: APIError.serviceSessionUnavailable, message: "Service session unavailable")
        }
        var environment = ["SLATE_TERM_SOCKET": socketPath, "SLATE_TERM_INSTANCE_ID": appInstanceID, "SLATE_TERM_CLI": cliPath]
        if let service { environment.merge(service.environment) { _, value in value } }
        return environment
    }
}
