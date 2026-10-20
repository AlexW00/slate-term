import Foundation
import Testing
@testable import SlateTermCore
import SlateTermTestSupport

@Test func portablePackageContractsMatchManifestResolution() throws {
    let definitions = AutomationContracts.pluginDefinitions
    let schema = definitions["PluginPackageManifest"]!
    let command: JSONValue = .object(["id": .string("run"), "title": .string("Run"), "executable": .string("/bin/sh")])
    let base: [String: JSONValue] = ["id": .string("tools"), "title": .string("Tools"), "commands": .array([command])]
    var samples: [[String: JSONValue]] = [[:], ["service": .null], ["process": .null], ["source": .null], ["commands": .null],
        ["compatibility": .object(["requiredMethods": .array([.string("future.method")])])],
        ["packageRoot": .string("/tmp/injected")]]
    for path in [".", "./web", "web", "../escape", "/absolute", "web//nested", "web/./nested", "web\\nested"] {
        samples.append(["source": .object(["kind": .string("directory"), "path": .string(path)])])
    }
    for field in ["executable", "directory", "arguments"] {
        let values: [JSONValue] = field == "arguments"
            ? ["{pluginRoot}", "{pluginRoot}/script.sh", "{pluginRoot}/../escape", "prefix{pluginRoot}", "{pluginRoot}/./script.sh"].map { .array([.string($0)]) }
            : [.null, .string("."), .string("./script.sh"), .string("script.sh"), .string("/bin/sh"), .string("../escape")]
        for value in values {
            var spec = command.object!
            spec[field] = value
            samples.append(["commands": .array([.object(spec)])])
        }
    }
    for changes in samples {
        let value = JSONValue.object(base.merging(changes) { _, value in value })
        let parsed = try? PluginManifest(data: JSONEncoder().encode(value))
        #expect(schemaAccepts(schema, value, definitions: definitions) == (parsed != nil))
        if let parsed {
            let registration = try parsed.registration(root: URL(fileURLWithPath: "/tmp/managed/contents"), validateFiles: false)
            let normalized = try JSONValue.encoding(registration)
            #expect(normalized.object?["packageRoot"] == nil)
            #expect(schemaAccepts(definitions["PluginRegistration"]!, normalized, definitions: definitions))
        }
    }
}

@Test func packageAPIContractsRejectLooseManifestsAndDescribeUnavailableAndCleanupRows() {
    let definitions = AutomationContracts.pluginDefinitions
    for method in [AutomationMethod.pluginsRegister, .pluginsValidate] {
        let input = AutomationContracts.plugins[method]!.input
        #expect(schemaAccepts(input, .object(["packagePath": .string("/tmp/plugin.zip")]), definitions: definitions))
        #expect(!schemaAccepts(input, .object(["manifest": .object([:])]), definitions: definitions))
        #expect(!schemaAccepts(input, .object(["packagePath": .string("relative.zip")]), definitions: definitions))
        #expect(!schemaAccepts(input, .object(["packagePath": .string("/tmp/plugin.zip"), "pane": .string("p1")]), definitions: definitions))
        #expect(!schemaAccepts(input, .object(["packagePath": .string("/tmp/plugin.zip"), "replace": .string("true")]), definitions: definitions))
    }
    #expect(!schemaAccepts(AutomationContracts.plugins[.pluginsValidate]!.input,
        .object(["packagePath": .string("/tmp/plugin.zip"), "replace": .bool(false)]), definitions: definitions))
    for method in [AutomationMethod.pluginsEnable, .pluginsDisable, .pluginsUnregister] {
        #expect(AutomationContracts.plugins[method]!.errors.contains(APIError.unavailable))
        #expect(AutomationContracts.plugins[method]!.errors.contains(APIError.settingsWriteFailed))
    }
    let unavailable: JSONValue = .object(["id": .string("tools"), "title": .string("tools"), "enabled": .bool(true), "enabledOverride": .null,
        "installationID": .string(UUID().uuidString), "packageRoot": .string("/tmp/managed/contents"),
        "available": .bool(false), "diagnostic": .string("Missing plugin.json"), "compatibilityStatus": .null, "cleanupPending": .bool(false)])
    #expect(schemaAccepts(AutomationContracts.plugins[.pluginsList]!.result, .array([unavailable]), definitions: definitions))
    #expect(!schemaAccepts(AutomationContracts.plugins[.pluginsRegister]!.result, unavailable, definitions: definitions))
    let cleanup: JSONValue = .object(["type": .string("tools"), "kind": .string("packageCleanup"),
        "packageRoot": .string("/tmp/managed/contents"), "cleanupPending": .bool(true), "diagnostic": .string("Waiting for release")])
    #expect(schemaAccepts(AutomationContracts.plugins[.pluginsStatus]!.result, .array([cleanup]), definitions: definitions))
}
