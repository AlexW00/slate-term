import Foundation
import Testing
@testable import SlateTermCore

struct ServiceSessionTests {
    private let token = String(repeating: "ab", count: 32)
    private func credentials() throws -> ServiceCredentials {
        try ServiceCredentials(identity: ServiceIdentity(appInstanceID: "app-1", pluginID: "example.worker",
            serviceID: "service-1", generation: "generation-1"), token: token)
    }

    @Test func strictHelloAndReply() throws {
        let value = try credentials()
        try value.authenticateHello(value.helloParams)
        try value.validateReply(.object(value.helloReply))
        #expect(!String(describing: value).contains(token))
        #expect(!String(reflecting: value).contains(token))
        #expect(!String(decoding: try JSONEncoder().encode(value.helloReply), as: UTF8.self).contains(token))
        for key in value.helloParams.keys {
            var missing = value.helloParams; missing.removeValue(forKey: key)
            #expect(throws: RPCFailure.self) { try value.authenticateHello(missing) }
            var null = value.helloParams; null[key] = .null
            #expect(throws: RPCFailure.self) { try value.authenticateHello(null) }
        }
        var foreign = value.helloParams; foreign["generation"] = .string("generation-2")
        #expect(throws: RPCFailure.self) { try value.authenticateHello(foreign) }
        foreign = value.helloParams; foreign["token"] = .string(String(repeating: "cd", count: 32))
        #expect(throws: RPCFailure.self) { try value.authenticateHello(foreign) }
        foreign = value.helloParams; foreign["pluginId"] = .string("claimed.owner")
        #expect(throws: RPCFailure.self) { try value.authenticateHello(foreign) }
        foreign = value.helloParams; foreign["serviceProtocolVersion"] = .integer(2)
        #expect(throws: RPCFailure.self) { try value.authenticateHello(foreign) }
    }

    @Test func administrativeHelloCannotPromoteService() throws {
        let value = try credentials()
        #expect(throws: RPCFailure.self) { try value.validateReply(.object(["protocolVersion": .integer(1)])) }
        for key in ["appInstanceId", "pluginId", "serviceId", "generation"] {
            var reply = value.helloReply; reply[key] = .string("foreign")
            #expect(throws: RPCFailure.self) { try value.validateReply(.object(reply)) }
        }
        var reply = value.helloReply; reply["serviceProtocolVersion"] = .integer(2)
        #expect(throws: RPCFailure.self) { try value.validateReply(.object(reply)) }
    }

    @Test func poisonedOrPartialEnvironmentNeverBecomesAdministrative() throws {
        let value = try credentials()
        #expect(try ServiceCredentials.inherited(from: [:]) == nil)
        #expect(try ServiceCredentials.inherited(from: ["SLATE_TERM_INSTANCE_ID": "app-1"]) == nil)
        let parsed = try #require(try ServiceCredentials.inherited(from: value.environment))
        #expect(parsed.identity == value.identity)
        try value.authenticateHello(parsed.helloParams)
        for key in value.environment.keys {
            var partial = value.environment; partial.removeValue(forKey: key)
            #expect(throws: RPCFailure.self) { try ServiceCredentials.inherited(from: partial) }
        }
        #expect(throws: RPCFailure.self) { try ServiceCredentials.inherited(from: ["SLATE_TERM_SERVICE_UNKNOWN": "x"]) }
        var poisoned = value.environment; poisoned["SLATE_TERM_SERVICE_TOKEN"] = "short"
        #expect(throws: RPCFailure.self) { try ServiceCredentials.inherited(from: poisoned) }
        // The invoked command's plugin identity is not its authenticated service authority.
        poisoned = value.environment; poisoned["SLATE_TERM_PLUGIN_ID"] = "other.command-owner"
        #expect(try ServiceCredentials.inherited(from: poisoned)?.identity.pluginID == "example.worker")
    }

    @Test func boundedIdentifiersAndSecret() throws {
        let identity = try credentials().identity
        for invalid in ["", " ", "with.dot", String(repeating: "a", count: 129), "é", "x\u{0}"] {
            #expect(throws: RPCFailure.self) {
                try ServiceIdentity(appInstanceID: "app", pluginID: "example.worker", serviceID: invalid, generation: "g")
            }
        }
        for invalid in ["", "a", String(repeating: "a", count: 65), String(repeating: "Z", count: 64)] {
            #expect(throws: RPCFailure.self) { try ServiceCredentials(identity: identity, token: invalid) }
        }
    }

    @Test func serviceOnlyAndMixedManifestsPreservePanelRules() throws {
        let base: [String: JSONValue] = ["id": .string("service"), "title": .string("Service fixture"),
            "service": .object(["executable": .string("/usr/bin/true")])]
        func parse(_ object: [String: JSONValue]) throws -> PluginRegistration {
            try PluginRegistration.parse(JSONEncoder().encode(object))
        }
        let serviceOnly = try parse(base)
        #expect(!serviceOnly.hasPanel && serviceOnly.commands.isEmpty && serviceOnly.process == nil)
        #expect(serviceOnly.service?.restartLimit == 3)
        #expect(try PluginRegistration.parse(JSONEncoder().encode(serviceOnly)) == serviceOnly)
        var mixed = base
        mixed["source"] = .object(["kind": .string("directory"), "path": .string("/tmp")])
        #expect(try parse(mixed).hasPanel)
        mixed["process"] = .object(["executable": .string("/usr/bin/true")])
        #expect(throws: (any Error).self) { try parse(mixed) }
        mixed.removeValue(forKey: "source")
        #expect(throws: (any Error).self) { try parse(mixed) }
        mixed = base; mixed["service"] = .object(["executable": .string("relative")])
        #expect(throws: (any Error).self) { try parse(mixed) }
        mixed = base; mixed.removeValue(forKey: "service")
        #expect(throws: (any Error).self) { try parse(mixed) }
    }
}
