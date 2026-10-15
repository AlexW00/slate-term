import Foundation

/// Public routing identity for one host-owned lifetime, never a credential or pane identity.
/// Only the endpoint's immutable host binding determines request ownership.
public struct ServiceIdentity: Equatable, Sendable, Encodable {
    public let appInstanceID: String
    public let pluginID: String
    public let serviceID: String
    public let generation: String

    public init(appInstanceID: String, pluginID: String, serviceID: String, generation: String) throws {
        guard [appInstanceID, serviceID, generation].allSatisfy(Self.opaque),
              pluginID.utf8.count <= 64,
              pluginID.range(of: "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$", options: .regularExpression) == pluginID.startIndex..<pluginID.endIndex,
              !["terminal", "browser", "private-browser"].contains(pluginID) else { throw unavailableServiceSession() }
        self.appInstanceID = appInstanceID; self.pluginID = pluginID
        self.serviceID = serviceID; self.generation = generation
    }

    public var info: [String: JSONValue] {
        ["appInstanceId": .string(appInstanceID), "pluginId": .string(pluginID),
         "serviceId": .string(serviceID), "generation": .string(generation)]
    }

    /// Validate routing on the same peer used for dispatch. A generic/root reply
    /// must not silently discard an inherited service owner.
    public func validateReply(_ result: JSONValue) throws {
        guard let reply = result.object, reply["protocolVersion"] == .integer(1),
              reply["service"] == .object(info) else { throw unavailableServiceSession() }
    }

    public var environment: [String: String] {
        ["SLATE_TERM_INSTANCE_ID": appInstanceID, "SLATE_TERM_SERVICE_ID": serviceID,
         "SLATE_TERM_SERVICE_GENERATION": generation, "SLATE_TERM_SERVICE_PLUGIN_ID": pluginID]
    }

    public static func inherited(from environment: [String: String]) throws -> ServiceIdentity? {
        let present = Set(environment.keys.filter { $0.hasPrefix("SLATE_TERM_SERVICE_") })
        guard !present.isEmpty else { return nil }
        // Unknown/partial fields, including the retired bearer bundle, cannot fall
        // back to an unowned connection. Restart with the current bundled context.
        guard present == ["SLATE_TERM_SERVICE_ID", "SLATE_TERM_SERVICE_GENERATION", "SLATE_TERM_SERVICE_PLUGIN_ID"],
              let app = environment["SLATE_TERM_INSTANCE_ID"], let plugin = environment["SLATE_TERM_SERVICE_PLUGIN_ID"],
              let service = environment["SLATE_TERM_SERVICE_ID"], let generation = environment["SLATE_TERM_SERVICE_GENERATION"] else {
            throw unavailableServiceSession()
        }
        return try ServiceIdentity(appInstanceID: app, pluginID: plugin, serviceID: service, generation: generation)
    }

    private enum CodingKeys: String, CodingKey {
        case appInstanceID = "appInstanceId", pluginID = "pluginId", serviceID = "serviceId", generation
    }
    static func opaque(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

private func unavailableServiceSession() -> RPCFailure {
    RPCFailure(code: APIError.serviceSessionUnavailable, message: "Service session unavailable")
}
