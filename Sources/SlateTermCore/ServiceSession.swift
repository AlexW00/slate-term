import Foundation

/// Host-owned identity for one app-level service generation; never a pane/session identity.
public struct ServiceIdentity: Equatable, Sendable, Encodable {
    public let appInstanceID: String
    public let pluginID: String
    public let serviceID: String
    public let generation: String

    public init(appInstanceID: String, pluginID: String, serviceID: String, generation: String) throws {
        guard [appInstanceID, serviceID, generation].allSatisfy(Self.opaque),
              pluginID.utf8.count <= 64,
              pluginID.range(of: "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$", options: .regularExpression) == pluginID.startIndex..<pluginID.endIndex,
              !["terminal", "browser"].contains(pluginID) else { throw unavailableServiceSession() }
        self.appInstanceID = appInstanceID; self.pluginID = pluginID
        self.serviceID = serviceID; self.generation = generation
    }

    public var info: [String: JSONValue] {
        ["appInstanceId": .string(appInstanceID), "pluginId": .string(pluginID),
         "serviceId": .string(serviceID), "generation": .string(generation)]
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

/// Credentials are intentionally not Codable or included in operation/event context.
/// Environment is delivery, not authority: only the bound endpoint authenticates it.
public struct ServiceCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let identity: ServiceIdentity
    private let token: String
    private static let environmentKeys: Set<String> = [
        "SLATE_TERM_SERVICE_ID", "SLATE_TERM_SERVICE_GENERATION", "SLATE_TERM_SERVICE_TOKEN", "SLATE_TERM_SERVICE_PLUGIN_ID"
    ]
    private static let helloKeys: Set<String> = ["protocolVersion", "serviceProtocolVersion", "serviceId", "generation", "token"]

    public init(identity: ServiceIdentity, token: String) throws {
        guard token.utf8.count == 64,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw unavailableServiceSession() }
        self.identity = identity; self.token = token
    }

    public var description: String { "ServiceCredentials(service: \(identity.serviceID), generation: \(identity.generation), token: <redacted>)" }
    public var debugDescription: String { description }

    public var helloParams: [String: JSONValue] {
        ["protocolVersion": .integer(1), "serviceProtocolVersion": .integer(1),
         "serviceId": .string(identity.serviceID), "generation": .string(identity.generation), "token": .string(token)]
    }
    public var helloReply: [String: JSONValue] {
        identity.info.merging(["protocolVersion": .integer(1), "serviceProtocolVersion": .integer(1)]) { _, value in value }
    }

    public func authenticateHello(_ params: [String: JSONValue]) throws {
        guard params.count == Self.helloKeys.count, Set(params.keys) == Self.helloKeys,
              params["protocolVersion"] == .integer(1), params["serviceProtocolVersion"] == .integer(1),
              params["serviceId"] == .string(identity.serviceID), params["generation"] == .string(identity.generation),
              let supplied = params["token"]?.string, supplied.utf8.count == 64 else { throw unavailableServiceSession() }
        // Do not exit at the first mismatching secret byte.
        var difference: UInt8 = 0
        for (left, right) in zip(supplied.utf8, token.utf8) { difference |= left ^ right }
        guard difference == 0 else { throw unavailableServiceSession() }
    }

    /// An administrative endpoint may ignore extra hello params. Its generic reply
    /// must never promote this client to administrative dispatch.
    public func validateReply(_ result: JSONValue) throws {
        guard let reply = result.object,
              helloReply.allSatisfy({ reply[$0.key] == $0.value }) else { throw unavailableServiceSession() }
    }

    /// This is only the credential portion; caller installs/checks the socket and CLI path.
    public var environment: [String: String] {
        ["SLATE_TERM_INSTANCE_ID": identity.appInstanceID, "SLATE_TERM_SERVICE_ID": identity.serviceID,
         "SLATE_TERM_SERVICE_GENERATION": identity.generation, "SLATE_TERM_SERVICE_TOKEN": token,
         "SLATE_TERM_SERVICE_PLUGIN_ID": identity.pluginID]
    }

    public static func inherited(from environment: [String: String]) throws -> ServiceCredentials? {
        let present = Set(environment.keys.filter { $0.hasPrefix("SLATE_TERM_SERVICE_") })
        guard !present.isEmpty else { return nil }
        guard present == environmentKeys, let app = environment["SLATE_TERM_INSTANCE_ID"],
              let plugin = environment["SLATE_TERM_SERVICE_PLUGIN_ID"], let service = environment["SLATE_TERM_SERVICE_ID"],
              let generation = environment["SLATE_TERM_SERVICE_GENERATION"], let token = environment["SLATE_TERM_SERVICE_TOKEN"] else {
            throw unavailableServiceSession()
        }
        return try ServiceCredentials(identity: ServiceIdentity(appInstanceID: app, pluginID: plugin,
            serviceID: service, generation: generation), token: token)
    }
}

private func unavailableServiceSession() -> RPCFailure {
    RPCFailure(code: APIError.serviceSessionUnavailable, message: "Service session unavailable")
}
