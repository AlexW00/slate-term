import Foundation
import Testing
import SlateTermCore
import SlateTermSettings
import SlateTermTestSupport

@Test func savedLayoutContractsMatchRealFilesRevisionsAndFieldEncoders() throws {
    let definitions = AutomationContracts.savedLayoutDefinitions.merging(AutomationContracts.pluginDefinitions) { first, _ in first }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-layout-contract-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try SavedLayoutStore(directory: directory)
    var definition = SavedLayoutDefinition.blank(name: "Initial")
    let created = try store.create(definition)
    for method in [AutomationMethod.layoutsCreate, .layoutsGet, .layoutsUpdate, .layoutsCapture] {
        #expect(schemaAccepts(AutomationContracts.savedLayouts[method]!.result, try .encoding(created), definitions: definitions))
    }
    let createdObject = try JSONValue.encoding(created).object!
    #expect(createdObject["diagnostic"] == nil)
    #expect(createdObject["id"] == nil) // The Codable entry uses file, not its computed Identifiable id.
    definition.name = "Updated"
    let updated = try store.update(definition, expectedRevision: created.revision!)
    #expect(schemaAccepts(AutomationContracts.savedLayouts[.layoutsUpdate]!.result, try .encoding(updated), definitions: definitions))
    do {
        _ = try store.update(definition, expectedRevision: created.revision!)
        Issue.record("Stale saved-layout content revision was accepted")
    } catch let failure as RPCFailure { #expect(failure.code == APIError.conflict) }
    #expect(try store.get(id: definition.id) == updated)

    let plugin = try PluginRegistration.parse(Data(#"{"id":"notes","title":"Notes","source":{"kind":"directory","path":"/tmp/notes"},"layoutFields":[{"id":"mode","label":"Mode","kind":"choice","options":["board","list"],"defaultValue":"board"}]}"#.utf8))
    let types = SavedLayoutPaneType.available(plugins: [plugin])
    #expect(schemaAccepts(AutomationContracts.savedLayouts[.layoutsFields]!.result, try .encoding(types), definitions: definitions))
    definition.tabs[0].panes[0].type = "unavailable.plugin"
    definition.tabs[0].panes[0].configuration = ["future": .null]
    let problems = definition.problems(types: types)
    #expect(problems == ["Missing plugin: unavailable.plugin"])
    #expect(schemaAccepts(AutomationContracts.savedLayouts[.layoutsValidate]!.input, .object(["definition": try .encoding(definition)]), definitions: definitions))
    #expect(schemaAccepts(AutomationContracts.savedLayouts[.layoutsValidate]!.result, .object(["valid": .bool(false), "diagnostics": .array(problems.map(JSONValue.string))]), definitions: definitions))
}

@Test func savedLayoutContractsAccountForNormalizedSizeAfterDefaultExpansion() throws {
    let definitions = AutomationContracts.savedLayoutDefinitions.merging(AutomationContracts.pluginDefinitions) { first, _ in first }
    let id = UUID().uuidString
    func pair(_ first: String, _ second: String) -> JSONValue {
        .object(["kind": .string("split"), "axis": .string("vertical"), "fraction": .number(0.5),
            "first": .object(["kind": .string("pane"), "pane": .string(first)]),
            "second": .object(["kind": .string("pane"), "pane": .string(second)])])
    }
    func recipe(payload: String) -> JSONValue {
        .object(["version": .integer(1), "id": .string(id), "name": .string("Boundary"), "tabs": .array([
            // Four bounded plugin configurations reach the document budget without
            // violating main\'s new per-panel 64 KiB configuration limit.
            .object(["name": .string("Tab"), "layout": .object(["kind": .string("split"), "axis": .string("horizontal"), "fraction": .number(0.5),
                "first": pair("p1", "p2"), "second": pair("p3", "p4")]),
                "panes": .array((0..<4).map { index in
                    let start = index * (payload.utf8.count / 4)
                    let end = index == 3 ? payload.utf8.count : (index + 1) * (payload.utf8.count / 4)
                    return .object(["id": .string("p\(index + 1)"), "type": .string("large.plugin"),
                        "configuration": .object(["payload": .string(String(payload.dropFirst(start).prefix(end - start)))])])
                })])
        ])])
    }
    let emptySize = try JSONEncoder().encode(recipe(payload: "")).count
    let atInputLimit = recipe(payload: String(repeating: "x", count: 262_144 - emptySize))
    let raw = try JSONEncoder().encode(atInputLimit)
    #expect(raw.count == 262_144)
    let normalized = try JSONDecoder().decode(SavedLayoutDefinition.self, from: raw)
    #expect(try JSONEncoder().encode(normalized).count > 262_144)
    #expect(throws: RPCFailure.self) { try SavedLayoutDefinition.parse(raw) }
    #expect(!schemaAccepts(definitions["SavedLayoutDefinitionInput"]!, atInputLimit, definitions: definitions))
    let belowLimit = recipe(payload: String(repeating: "x", count: 262_144 - emptySize - 256))
    #expect(try SavedLayoutDefinition.parse(JSONEncoder().encode(belowLimit)).id.uuidString == id)
    #expect(schemaAccepts(definitions["SavedLayoutDefinitionInput"]!, belowLimit, definitions: definitions))
}
