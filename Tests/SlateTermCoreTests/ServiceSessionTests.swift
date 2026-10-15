import Foundation
import Testing
@testable import SlateTermCore

struct ServiceSessionTests {
    private func identity() throws -> ServiceIdentity {
        try ServiceIdentity(appInstanceID: "app-1", pluginID: "example.worker", serviceID: "service-1", generation: "generation-1")
    }

    @Test func everyPublicIdentityFieldMustMatchBeforeDispatch() throws {
        let value = try identity()
        try value.validateReply(.object(["protocolVersion": .integer(1), "service": .object(value.info)]))
        for key in value.info.keys {
            var foreign = value.info; foreign[key] = .string("foreign")
            #expect(throws: RPCFailure.self) { try value.validateReply(.object(["protocolVersion": .integer(1), "service": .object(foreign)])) }
            var missing = value.info; missing.removeValue(forKey: key)
            #expect(throws: RPCFailure.self) { try value.validateReply(.object(["protocolVersion": .integer(1), "service": .object(missing)])) }
        }
        #expect(throws: RPCFailure.self) { try value.validateReply(.object(["protocolVersion": .integer(2), "service": .object(value.info)])) }
    }

    @Test func poisonedOrPartialEnvironmentNeverDiscardsOwnership() throws {
        let value = try identity()
        #expect(try ServiceIdentity.inherited(from: [:]) == nil)
        #expect(try ServiceIdentity.inherited(from: ["SLATE_TERM_INSTANCE_ID": "app-1"]) == nil)
        #expect(try ServiceIdentity.inherited(from: value.environment) == value)
        for key in value.environment.keys {
            var partial = value.environment; partial.removeValue(forKey: key)
            #expect(throws: RPCFailure.self) { try ServiceIdentity.inherited(from: partial) }
        }
        #expect(throws: RPCFailure.self) { try ServiceIdentity.inherited(from: ["SLATE_TERM_SERVICE_UNKNOWN": "x"]) }
        var delegated = value.environment; delegated["SLATE_TERM_PLUGIN_ID"] = "other.command-owner"
        #expect(try ServiceIdentity.inherited(from: delegated)?.pluginID == "example.worker")
    }

    @Test func boundedIdentifiers() throws {
        for invalid in ["", " ", "with.dot", String(repeating: "a", count: 129), "é", "x\u{0}"] {
            #expect(throws: RPCFailure.self) {
                try ServiceIdentity(appInstanceID: "app", pluginID: "example.worker", serviceID: invalid, generation: "g")
            }
        }
        for invalid in ["terminal", "browser", "Bad", "a..b", String(repeating: "a", count: 65)] {
            #expect(throws: RPCFailure.self) {
                try ServiceIdentity(appInstanceID: "app", pluginID: invalid, serviceID: "service", generation: "g")
            }
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
