import Foundation
import Testing
import SlateTermTestSupport
@testable import SlateTermCore

@Test func workspaceSchemasPreserveLegacyEncodingAndRecursiveLayouts() throws {
    var workspace = Workspace()
    let first = try #require(workspace.panes.first?.id)
    let browser = try workspace.split(first, direction: .right)
    try workspace.setType(browser, to: .browser)
    let privateBrowser = try workspace.split(first, direction: .down)
    try workspace.setType(privateBrowser, to: .privateBrowser)
    let plugin = try workspace.split(first, direction: .left)
    try workspace.setType(plugin, to: .registered("acme.notes"))
    let definitions = AutomationContracts.workspaceDefinitions
    let snapshot = try workspace.publicJSON()
    let privateSnapshot = try JSONDecoder().decode(JSONValue.self, from: workspace.encoded())
    #expect(!schemaAccepts(AutomationContracts.workspace[.workspaceGet]!.result, privateSnapshot, definitions: definitions))
    #expect(schemaAccepts(AutomationContracts.workspace[.workspaceGet]!.result, snapshot, definitions: definitions))
    #expect(schemaAccepts(AutomationContracts.workspace[.tabsList]!.result, try .encoding(workspace.tabs), definitions: definitions))
    #expect(schemaAccepts(AutomationContracts.workspace[.panesList]!.result, snapshot.object!["panes"]!, definitions: definitions))
    #expect(schemaAccepts(AutomationContracts.workspace[.layoutGet]!.result, try .encoding(workspace.tabs[0].layout), definitions: definitions))
    let flattenedPane: JSONValue = .object(["id": .string("p1"), "type": .string("terminal"), "headerVisible": .bool(true)])
    #expect(!schemaAccepts(definitions["Pane"]!, flattenedPane, definitions: definitions))
    let invalidLayout: JSONValue = .object(["kind": .string("split"), "axis": .string("horizontal"), "fraction": .integer(1),
        "first": .object(["kind": .string("pane"), "pane": .string("p1")]),
        "second": .object(["kind": .string("pane"), "pane": .string("p2")])])
    #expect(!schemaAccepts(definitions["Layout"]!, invalidLayout, definitions: definitions))
}

@Test func workspaceContractsKeepNativeWindowTargetsAndGuardsDistinct() {
    let get = AutomationContracts.workspace[.windowGet]!
    #expect(schemaAccepts(get.input, .object(["windowId": .string("opaque"), "expectedWorkspaceRevision": .string("revision")])))
    #expect(!schemaAccepts(get.input, .object(["windowId": .string("opaque"), "pane": .string("p1")])))
    #expect(!schemaAccepts(get.input, .object(["windowId": .string("opaque"), "expectedLayoutRevision": .string("revision")])))
    let list = AutomationContracts.workspace[.windowList]!
    #expect(!schemaAccepts(list.input, .object(["limit": .integer(65)])))
    #expect(schemaAccepts(list.input, .object(["limit": .integer(1)])))
    #expect(AutomationContracts.workspace[.contextGet]!.input.object?["properties"]?.object?["scope"]?.object?["default"] == .string("tab"))
    #expect(AutomationContracts.workspace[.workspaceSnapshot]!.input.object?["properties"]?.object?["scope"]?.object?["default"] == .string("global"))
}

@Test func workspaceSchemaReferencesAreClosedAndMissingDefinitionsFailValidation() {
    let definitions = AutomationContracts.workspaceDefinitions
    func references(_ value: JSONValue) -> Set<String> {
        switch value {
        case .object(let fields):
            var result = Set(fields["$ref"]?.string.map { [String($0.dropFirst(8))] } ?? [])
            for field in fields.values { result.formUnion(references(field)) }
            return result
        case .array(let values): return values.reduce(into: Set<String>()) { $0.formUnion(references($1)) }
        default: return []
        }
    }
    for schema in Array(definitions.values) + AutomationContracts.workspace.values.map(\.result) {
        #expect(references(schema).isSubset(of: Set(definitions.keys)))
    }
    #expect(!schemaAccepts(APISchema.reference("Missing"), .null, definitions: definitions))
}
