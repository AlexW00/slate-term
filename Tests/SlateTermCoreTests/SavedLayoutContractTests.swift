import Foundation
import Testing
@testable import SlateTermCore
import SlateTermTestSupport

private let savedLayoutContractDefinitions = AutomationContracts.savedLayoutDefinitions.merging(AutomationContracts.pluginDefinitions) { first, _ in first }

@Test func savedLayoutResultsPreserveOpaqueNativeWindowIdentifiers() {
    let definitions = savedLayoutContractDefinitions
    let window = JSONValue.string("window-" + UUID().uuidString)
    let source: JSONValue = .object(["id": .string("epoch/w1"), "title": .string("Slate Terminal"),
        "tabs": .array([.string("t1")]), "groupId": .string("w1"), "windowIds": .array([window]),
        "workspaceRevision": .string("epoch:w:1")])
    #expect(schemaAccepts(AutomationContracts.savedLayouts[.layoutsWindows]!.result, .array([source]), definitions: definitions))
    let opened: JSONValue = .object(["window": .string("epoch/w1"), "groupId": .string("w1"), "windowIds": .array([window]),
        "paneIds": .array([.string("p1")]), "startup": .array([]), "operationId": .string(UUID().uuidString),
        "workspaceRevision": .string("epoch:w:1"), "outcome": .string("committed"), "workspacePersistence": .string("saved")])
    #expect(schemaAccepts(AutomationContracts.savedLayouts[.layoutsOpen]!.result, opened, definitions: definitions))
}

@Test func savedLayoutContractsSeparateOptionalInputFromNormalizedRecipes() throws {
    let definitions = savedLayoutContractDefinitions
    let input = definitions["SavedLayoutDefinitionInput"]!
    let output = definitions["SavedLayoutDefinition"]!
    let minimal: JSONValue = .object(["version": .integer(1), "id": .string(UUID().uuidString), "name": .string("Recipe"), "tabs": .array([
        .object(["name": .string("Tab"), "manualTitle": .null, "layout": .object(["kind": .string("pane"), "pane": .string("p1")]),
            "panes": .array([.object(["id": .string("p1"), "type": .string("terminal")])])])
    ])])
    let decoded = try SavedLayoutDefinition.parse(JSONEncoder().encode(minimal))
    #expect(schemaAccepts(input, minimal, definitions: definitions))
    #expect(!schemaAccepts(output, minimal, definitions: definitions))
    #expect(schemaAccepts(output, try .encoding(decoded), definitions: definitions))

    let samples: [[String: JSONValue]] = [
        ["title": .null], ["headerVisible": .null], ["configuration": .null], ["title": .string("\n")],
        ["configuration": .object(["directory": .string("relative")])], ["configuration": .object(["directory": .string("~/work")])],
        ["configuration": .object(["command": .string("echo hi\necho done")])], ["configuration": .object(["command": .bool(false)])],
        ["type": .string("browser"), "configuration": .object(["url": .string("https://user:pass@example.test")])],
        ["type": .string("private-browser"), "configuration": .object(["url": .string("/tmp/page.html")])],
        ["type": .string("browser"), "configuration": .object(["url": .string("")])],
        ["type": .string("unregistered.plugin"), "configuration": .object(["future": .array([.null, .bool(true)])])]
    ]
    for paneChanges in samples {
        var root = minimal.object!
        guard case .array(var tabs) = root["tabs"] else { preconditionFailure() }
        var tab = tabs[0].object!
        tab["panes"] = .array([.object(["id": .string("p1"), "type": .string("terminal")].merging(paneChanges) { _, value in value })])
        tabs[0] = .object(tab); root["tabs"] = .array(tabs)
        let value = JSONValue.object(root)
        let parsed = try? SavedLayoutDefinition.parse(JSONEncoder().encode(value))
        #expect(schemaAccepts(input, value, definitions: definitions) == (parsed != nil))
        if let parsed { #expect(schemaAccepts(output, try .encoding(parsed), definitions: definitions)) }
    }
}

@Test func savedLayoutContractsEnforceTopologyCanonicalTitlesAndOpaqueDepth() throws {
    let definitions = savedLayoutContractDefinitions
    let schema = definitions["SavedLayoutDefinitionInput"]!
    var valid = SavedLayoutDefinition.blank(name: "Two panes")
    _ = try valid.splitPane(PaneID(1), axis: .horizontal)
    var variants = [valid]
    var mismatch = valid; mismatch.tabs[0].panes.removeLast(); variants.append(mismatch)
    var duplicate = valid; duplicate.tabs.append(duplicate.tabs[0]); variants.append(duplicate)
    var fraction = valid; fraction.tabs[0].layout = .split(axis: .horizontal, fraction: 0.09, first: .pane(PaneID(1)), second: .pane(PaneID(2))); variants.append(fraction)
    var title = valid; title.tabs[0].manualTitle = " Untrimmed "; variants.append(title)
    title.tabs[0].manualTitle = "Canonical"; variants.append(title)
    var plugin = SavedLayoutDefinition.blank(); plugin.tabs[0].panes[0].type = "future.plugin"
    for depth in [31, 32] {
        var value: JSONValue = .null
        for _ in 0..<depth { value = .array([value]) }
        // Configuration itself occupies depth zero, so the value begins at one.
        plugin.tabs[0].panes[0].configuration = ["opaque": value]
        variants.append(plugin)
    }
    for definition in variants {
        let value = try JSONValue.encoding(definition)
        let accepted = (try? SavedLayoutDefinition.parse(JSONEncoder().encode(value))) != nil
        #expect(schemaAccepts(schema, value, definitions: definitions) == accepted)
    }
}

@Test func savedLayoutContractsPreserveDocumentGuardsAndWholeGroupTargeting() throws {
    let contracts = AutomationContracts.savedLayouts
    #expect(Set(contracts.keys) == Set(AutomationMethod.publicMethods.filter { $0.rawValue.hasPrefix("layouts.") || $0.rawValue.hasPrefix("layoutApps.") }))
    let definition = try JSONValue.encoding(SavedLayoutDefinition.blank())
    #expect(!schemaAccepts(contracts[.layoutsUpdate]!.input, .object(["definition": definition]), definitions: savedLayoutContractDefinitions))
    #expect(schemaAccepts(contracts[.layoutsUpdate]!.input, .object(["definition": definition, "expectedSavedLayoutRevision": .string("stale-but-well-formed")]), definitions: savedLayoutContractDefinitions))
    #expect(!schemaAccepts(contracts[.layoutsGet]!.input, .object(["id": .string(UUID().uuidString), "expectedWorkspaceRevision": .string("r1")])))
    #expect(!schemaAccepts(contracts[.layoutsCapture]!.input, .object(["pane": .string("p1"), "name": .string("No focus fallback")])))
    #expect(schemaAccepts(contracts[.layoutsCapture]!.input, .object(["window": .string("epoch/w1"), "name": .string("Captured"), "includeCommands": .bool(true)])))
    #expect(!schemaAccepts(contracts[.layoutsOpen]!.input, .object(["id": .string(UUID().uuidString), "force": .bool(true)])))
    for path in ["/tmp/New.app", "/tmp/New.app///", "/tmp/New.APP", "/tmp/New.app/child", "relative.app"] {
        let value: JSONValue = .object(["id": .string(UUID().uuidString), "path": .string(path)])
        #expect(schemaAccepts(contracts[.layoutsLauncher]!.input, value) == (path.hasPrefix("/") && URL(fileURLWithPath: path).pathExtension == "app"))
    }
}
