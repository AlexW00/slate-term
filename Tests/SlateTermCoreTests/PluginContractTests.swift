import Foundation
import Testing
@testable import SlateTermCore
import SlateTermTestSupport

@Test func pluginContractsPreserveSubmittedDefaultsAndNormalizedEncoderShape() throws {
    let definitions = AutomationContracts.pluginDefinitions
    let input = definitions["PluginRegistrationInput"]!
    let output = definitions["PluginRegistration"]!
    let manifests: [JSONValue] = [
        .object(["id": .string("notes"), "title": .string("Notes"), "source": .object(["kind": .string("directory"), "path": .string("/tmp/notes")])]),
        .object(["id": .string("service"), "title": .string("Service"), "service": .object(["executable": .string("/bin/sh"), "arguments": .null]), "scope": .null]),
        .object(["id": .string("tools"), "title": .string("Tools"), "commands": .array([
            .object(["id": .string("run"), "title": .string("Run"), "executable": .string("/bin/sh"), "environment": .null])
        ]), "headerButtons": .array([.object(["id": .string("run"), "title": .string("Run"), "symbol": .string("play.fill"), "command": .string("run")])])])
    ]
    for manifest in manifests {
        let registration = try PluginRegistration.parse(JSONEncoder().encode(manifest))
        #expect(schemaAccepts(input, manifest, definitions: definitions))
        #expect(!schemaAccepts(output, manifest, definitions: definitions))
        let encoded = try JSONValue.encoding(registration)
        #expect(schemaAccepts(output, encoded, definitions: definitions))
        var listed = encoded.object!
        listed.merge(["enabled": .bool(false), "enabledOverride": .null, "installationID": .string(UUID().uuidString), "available": .bool(true),
            "diagnostic": .null, "packageRoot": .string("/tmp/managed/contents"), "cleanupPending": .bool(false)]) { _, v in v }
        listed["compatibilityStatus"] = try .encoding(registration.compatibilityReport())
        #expect(schemaAccepts(definitions["ListedPlugin"]!, .object(listed), definitions: definitions))
        #expect(!schemaAccepts(output, .object(listed), definitions: definitions))
    }
}

@Test func pluginManifestContractsMatchContributionAndCompatibilityRules() throws {
    let definitions = AutomationContracts.pluginDefinitions
    let schema = definitions["PluginRegistrationInput"]!
    let base: [String: JSONValue] = ["id": .string("notes"), "title": .string("Notes"),
        "source": .object(["kind": .string("url"), "url": .string("https://example.test/")])]
    let command: JSONValue = .object(["id": .string("run"), "title": .string("Run"), "executable": .string("/bin/sh")])
    let samples: [[String: JSONValue]] = [[:], ["source": .null], ["title": .string(" \n")], ["id": .string("notes\n")],
        ["manifestVersion": .null], ["version": .null], ["version": .string("release 1")], ["manifestVersion": .integer(2)],
        ["compatibility": .null], ["compatibility": .object(["minimumAPIVersion": .integer(2)])],
        ["compatibility": .object(["minimumAPIVersion": .integer(2), "maximumAPIVersion": .integer(2)])],
        ["compatibility": .object(["requiredMethods": .array([.string("version"), .string("version")])])],
        ["compatibility": .object(["requiredMethods": .array([.string("unknown.publicMethod")])])],
        ["commands": .array([command, command])], ["commands": .null],
        ["source": .null, "service": .object(["executable": .string("/bin/sh")])],
        ["process": .object(["executable": .string("/bin/sh")])],
        ["source": .object(["kind": .string("url"), "url": .string("http://127.0.0.1:0/")]), "process": .object(["executable": .string("/bin/sh")])],
        ["source": .object(["kind": .string("url"), "url": .string("http://127.0.0.1:0/")])],
        ["source": .object(["kind": .string("url"), "url": .string("http://remote.test/")])],
        ["source": .object(["kind": .string("directory"), "path": .string("/tmp"), "entry": .string("../escape")])],
        ["headerButtons": .array([.object(["id": .string("run"), "title": .string("Run"), "symbol": .string("play"), "command": .string("missing")])])],
        ["service": .object(["executable": .string("/bin/sh"), "readyTimeoutSeconds": .number(0.09)])]]
    for changes in samples {
        let value = JSONValue.object(base.merging(changes) { _, value in value })
        let accepted = (try? PluginRegistration.parse(JSONEncoder().encode(value))) != nil
        #expect(schemaAccepts(schema, value, definitions: definitions) == accepted)
    }
}

@Test func pluginFieldContractsKeepDefaultsKindSpecificAndOptionalNullDistinct() throws {
    let definitions = AutomationContracts.pluginDefinitions
    let input = definitions["SavedLayoutFieldInput"]!
    let output = definitions["SavedLayoutField"]!
    let base: [String: JSONValue] = ["id": .string("choice"), "label": .string("Choice"), "kind": .string("choice"), "options": .array([.string("a"), .string("b")])]
    let samples: [[String: JSONValue]] = [[:], ["defaultValue": .null], ["defaultValue": .string("a")], ["defaultValue": .string("other")],
        ["required": .bool(true), "defaultValue": .string("")], ["kind": .string("boolean"), "options": .null, "defaultValue": .bool(false)],
        ["options": .array([.string("a"), .string("a")])], ["id": .string("choice\n")]]
    for changes in samples {
        let value = JSONValue.object(base.merging(changes) { _, value in value })
        let parsed = try? JSONDecoder().decode(SavedLayoutField.self, from: JSONEncoder().encode(value))
        #expect(schemaAccepts(input, value, definitions: definitions) == (parsed != nil))
        if let parsed { #expect(schemaAccepts(output, try .encoding(parsed), definitions: definitions)) }
    }
}

@Test func pluginManagementContractsKeepLegacyAndStrictBoundariesDistinct() {
    let definitions = AutomationContracts.pluginDefinitions
    #expect(AutomationContracts.plugins.count == 9)
    #expect(schemaAccepts(AutomationContracts.plugins[.pluginsStatus]!.input, .object(["id": .null, "ignored": .bool(true)])))
    #expect(!schemaAccepts(AutomationContracts.plugins[.pluginsEnable]!.input, .object(["id": .string("notes"), "pane": .string("p1")])))
    #expect(!schemaAccepts(AutomationContracts.plugins[.pluginsDisable]!.input, .object(["id": .string("notes"), "force": .string("true")])))
    #expect(AutomationContracts.plugins[.pluginsRegister]!.errors.contains(APIError.incompatible))
    let result: JSONValue = .object(["id": .string("notes"), "enabled": .bool(false), "operationId": .string(UUID().uuidString),
        "workspaceRevision": .string("revision"), "outcome": .string("unchanged"), "workspacePersistence": .string("notRequired")])
    #expect(schemaAccepts(AutomationContracts.plugins[.pluginsDisable]!.result, result, definitions: definitions))
    #expect(!schemaAccepts(AutomationContracts.plugins[.pluginsDisable]!.result, .object(["id": .string("notes"), "enabled": .bool(false)]), definitions: definitions))
}
