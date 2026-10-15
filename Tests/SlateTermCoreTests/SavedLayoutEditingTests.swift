import Foundation
import Testing
@testable import SlateTermCore

struct SavedLayoutEditingTests {
    @Test func removeNestedPaneCollapsesOnlyItsParentAndPreservesRecipes() throws {
        var layout = SavedLayoutDefinition.blank(name: "Development")
        let browser = try layout.splitPane(PaneID(1), axis: .horizontal)
        let output = try layout.splitPane(browser, axis: .vertical)
        layout.tabs[0].panes[1].type = "browser"
        layout.tabs[0].panes[1].configuration = ["url": .string("https://example.com")]
        let before = layout
        _ = try layout.removePane(output)
        #expect(layout.tabs[0].layout == .split(axis: .horizontal, fraction: 0.5, first: .pane(PaneID(1)), second: .pane(browser)))
        #expect(layout.tabs[0].panes == Array(before.tabs[0].panes.prefix(2)))
        _ = try layout.removePane(PaneID(1))
        #expect(layout.tabs[0].layout == .pane(browser))
        let last = layout
        #expect(throws: RPCFailure.self) { try layout.removePane(browser) }
        #expect(layout == last)
        #expect(try SavedLayoutDefinition.parse(JSONEncoder().encode(layout)) == layout)
    }

    @Test func diagnosticsAndCombiningCharacterNamesAreBounded() throws {
        var layout = SavedLayoutDefinition.blank()
        layout.name = "a" + String(repeating: "\u{0301}", count: 1024)
        #expect(layout.name.count == 1)
        #expect(throws: RPCFailure.self) { try layout.validated() }
        layout.name = "Bounded"
        for _ in 0..<7 { _ = try layout.splitPane(PaneID(1), axis: .horizontal) }
        for index in layout.tabs[0].panes.indices { layout.tabs[0].panes[index].type = "dashboard" }
        let fields = (0..<32).map { SavedLayoutField(id: "field\($0)", label: "Field \($0)", kind: .text, required: true) }
        let problems = layout.problems(types: [SavedLayoutPaneType(id: "dashboard", title: "Dashboard", fields: fields)])
        #expect(problems.count == 129)
        #expect(problems.last?.hasPrefix("Further diagnostics omitted") == true)
        #expect(try JSONEncoder().encode(problems).count < 1_048_576)
    }

    @Test func splittingUsesUnusedIdentitiesAcrossAllTabs() throws {
        var layout = SavedLayoutDefinition.blank()
        layout.tabs.append(SavedLayoutTab(name: "Second", layout: .pane(PaneID(2)), panes: [.init(id: PaneID(2))]))
        #expect(try layout.splitPane(PaneID(1), axis: .horizontal) == PaneID(3))
        #expect(try layout.validated().tabs.count == 2)
    }

    @Test func pluginSchemaDefaultsAndOpaqueValuesArePreserved() throws {
        let data = Data(#"{"id":"dashboard","title":"Dashboard","source":{"kind":"url","url":"https://example.com"},"layoutFields":[{"id":"project","label":"Project Folder","kind":"directory","required":true},{"id":"view","label":"View","kind":"choice","options":["board","list"],"defaultValue":"board"},{"id":"completed","label":"Show Completed","kind":"boolean","defaultValue":false}]}"#.utf8)
        let plugin = try PluginRegistration.parse(data)
        let types = SavedLayoutPaneType.available(plugins: [plugin])
        var layout = SavedLayoutDefinition.blank()
        layout.tabs[0].panes[0].type = plugin.id
        layout.tabs[0].panes[0].configuration = types.last!.defaults
        #expect(layout.problems(types: types).count == 1)
        layout.tabs[0].panes[0].configuration["project"] = .string("~/Development")
        layout.tabs[0].panes[0].configuration["future"] = .object(["nested": .integer(42)])
        #expect(layout.problems(types: types).isEmpty)
        #expect(try SavedLayoutDefinition.parse(JSONEncoder().encode(layout)) == layout)
        #expect(layout.problems(types: []).first == "Missing plugin: dashboard")
        let invalid = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"defaultValue\":false", with: "\"defaultValue\":\"wrong\"")
        #expect(throws: RPCFailure.self) { try PluginRegistration.parse(Data(invalid.utf8)) }
    }
}
