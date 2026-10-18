import Foundation
import Testing
@testable import SlateTermCore
import SlateTermTestSupport

@Test func contributedCommandSchemaPreservesUserExpectedArgumentsButRejectsUnsupportedHostGuards() {
    let schema = AutomationContracts.contributedCommand.input
    let baseline: [String: JSONValue] = ["id": .string("plugin.notes.preview.open")]
    #expect(schemaAccepts(schema, .object(baseline)))
    for key in ["expectedSelection", "expected", "scope", "timeoutSeconds", "executable", "options"] {
        for value in [JSONValue.null, .integer(42), .object(["nested": .array([.bool(true)])])] {
            #expect(schemaAccepts(schema, .object(baseline.merging([key: value]) { _, value in value })))
        }
    }
    for guardName in APIGuards.names.subtracting(AutomationContracts.contributedCommand.guards) {
        #expect(!schemaAccepts(schema, .object(baseline.merging([guardName: .string("unsupported")]) { _, value in value })))
    }
    #expect(!schemaAccepts(schema, .object(baseline.merging(["expectedAnchorSessionId": .string("session")]) { _, value in value })))
    #expect(schemaAccepts(schema, .object(baseline.merging(["expectedAnchorSessionId": .string("session"), "pane": .string("p1")]) { _, value in value })))
    #expect(!schemaAccepts(schema, .object(baseline.merging(["pane": .string("p1"), "contextPane": .string("p2")]) { _, value in value })))
    // The exception is specific to contributed commands, not a weakening of built-ins.
    #expect(!schemaAccepts(AutomationContracts.workspaceCommands["pane.focus"]!.input,
        .object(["id": .string("pane.focus"), "expectedSelection": .null])))
}

@Test func contributedCommandIDsAndCallerDefaultsMatchSharedRoutingDefinitions() {
    let schema = AutomationContracts.contributedCommand.input
    for id in ["plugin.notes.open", "plugin.notes.preview.open-tab", "plugin.a.b", "plugin.a.b\n", "plugin.a.", "plugin.a.Upper", "pane.focus", "plugin." + String(repeating: "x", count: 129) + ".a"] {
        #expect(schemaAccepts(schema, .object(["id": .string(id)])) == PluginCommand.isNamespacedID(id))
    }
    let resolved = AutomationMethod.commandRun.resolving(["id": .string("plugin.notes.open")],
        defaults: .init(pane: PaneID(3), tab: TabID(2), scope: "tab"))
    #expect(resolved["pane"] == .string("p3"))
    #expect(resolved["tab"] == .string("t2"))
    #expect(resolved["scope"] == .string("tab"))
    #expect(schemaAccepts(schema, .object(resolved)))
    // The byte cap applies after the host replaces routing fields. The input
    // contract must not incorrectly cap the pre-normalized context-anchor object.
    let input: JSONValue = .object(["id": .string("plugin.notes.open"), "contextPane": .string("p9223372036854775807"),
        "payload": .string(String(repeating: "x", count: 16_384))])
    #expect(schemaAccepts(schema, input))
    #expect(AutomationContracts.contributedCommand.semantics["maximumResolvedParameterBytes"] == .integer(16_384))
}

@Test func contributedCommandSuccessSchemaIsNarrowerThanRetainedRunStatus() {
    let definitions = AutomationContracts.pluginDefinitions.merging(AutomationContracts.contributedCommandDefinitions) { first, _ in first }
    var result: [String: JSONValue] = ["instanceId": .string(UUID().uuidString), "type": .string("notes"), "kind": .string("command"),
        "commandId": .string("plugin.notes.open"), "state": .string("succeeded"), "tabId": .null, "paneId": .null, "pid": .null,
        "cleanupPending": .bool(true), "exitCode": .integer(0), "signal": .null, "error": .null,
        "stdout": .string("retained tail"), "stderr": .string("")]
    let schema = AutomationContracts.contributedCommand.result
    #expect(schemaAccepts(schema, .object(result), definitions: definitions))
    result["stdout"] = .string(String(repeating: "�", count: 65_536))
    #expect(schemaAccepts(schema, .object(result), definitions: definitions))
    result["stdout"] = .string(String(repeating: "�", count: 65_537))
    #expect(!schemaAccepts(schema, .object(result), definitions: definitions))
    result["stdout"] = .string(""); result["state"] = .string("failed"); result["exitCode"] = .integer(1)
    result["error"] = .string("Command exited with code 1")
    #expect(!schemaAccepts(schema, .object(result), definitions: definitions))
    result.removeValue(forKey: "stdout"); result.removeValue(forKey: "stderr")
    #expect(schemaAccepts(definitions["PluginCommandRun"]!, .object(result), definitions: definitions))
}
