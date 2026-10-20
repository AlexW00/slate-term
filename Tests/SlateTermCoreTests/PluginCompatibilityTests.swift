import Foundation
import Testing
@testable import SlateTermCore

private func plugin(_ fields: [String: JSONValue] = [:]) throws -> PluginRegistration {
    let base: [String: JSONValue] = ["id": .string("compatible"), "title": .string("Compatible"),
        "commands": .array([.object(["id": .string("run"), "title": .string("Run"), "executable": .string("/usr/bin/true")])])]
    return try PluginRegistration.parse(JSONEncoder().encode(base.merging(fields) { _, new in new }))
}

@Test func pluginRequirementsUseTheSamePublicCatalogAndSurviveEncoding() throws {
    let registration = try plugin(["manifestVersion": .integer(1), "version": .string("1.2.0-beta.1"),
        "compatibility": .object(["minimumAPIVersion": .integer(1), "maximumAPIVersion": .integer(1),
            "requiredMethods": .array([.string("terminal.capture")]),
            "requiredCommands": .array([.string("terminal.find")])])])
    try registration.requireCompatibility()
    #expect(registration.version == "1.2.0-beta.1")
    #expect(try PluginRegistration.parse(JSONEncoder().encode(registration)) == registration)
    #expect(!registration.compatibilityReport(methods: []).compatible)
    #expect(!registration.compatibilityReport(commands: []).compatible)
    #expect(!registration.compatibilityReport(apiVersion: 2).compatible)
    // An omitted declaration always means the original API generation, not any
    // future host version. Old unversioned manifests cannot silently opt in.
    #expect(try plugin().compatibilityReport().compatible)
    #expect(try !plugin().compatibilityReport(apiVersion: 2).compatible)
}

@Test func pluginIncompatibilityIsDistinctFromMalformedDeclarations() throws {
    for fields: [String: JSONValue] in [
        ["manifestVersion": .integer(2)],
        ["compatibility": .object(["minimumAPIVersion": .integer(2), "maximumAPIVersion": .integer(3)])],
        ["compatibility": .object(["requiredMethods": .array([.string("shell.update")])])],
        ["compatibility": .object(["requiredMethods": .array([.string("debug.inspect")])])],
        ["compatibility": .object(["requiredCommands": .array([.string("plugin.other.run")])])]
    ] {
        let candidate = try plugin(fields)
        #expect(!candidate.compatibilityReport().compatible)
        do {
            try candidate.requireCompatibility()
            Issue.record("Incompatible plugin accepted")
        } catch let failure as RPCFailure { #expect(failure.code == APIError.incompatible) }
    }
    for fields: [String: JSONValue] in [
        ["manifestVersion": .null], ["version": .null], ["version": .string("")], ["compatibility": .null],
        ["compatibility": .object(["minimumAPIVersion": .integer(0)])],
        ["compatibility": .object(["minimumAPIVersion": .integer(2), "maximumAPIVersion": .integer(1)])],
        ["compatibility": .object(["requiredMethods": .null])],
        ["compatibility": .object(["requiredMethods": .array([.string("version"), .string("version")])])],
        ["compatibility": .object(["requiredMethods": .array([.string("bad id")])])],
        ["compatibility": .object(["unknown": .bool(true)])]
    ] { #expect(throws: (any Error).self) { try plugin(fields) } }
}
