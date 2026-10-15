import Foundation
import Testing
import SlateTermCore

@Suite struct SavedLayoutModelTests {
    @Test func nestedSplitRoundTripPreservesOpaquePluginConfiguration() throws {
        let definition = savedLayoutFixture()
        let data = try JSONEncoder().encode(definition)
        #expect(try SavedLayoutDefinition.parse(data) == definition)
        #expect(try definition.validated() == definition)
        let blank = SavedLayoutDefinition.blank()
        #expect(blank.name == "Untitled Layout")
        #expect(blank.tabs[0].name == "Tab 1")
        #expect(blank.tabs[0].panes[0].id == PaneID(1))
        #expect(try blank.validated() == blank)
    }

    @Test func unknownFieldsAtEveryStructuralLevelAreRejected() throws {
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(savedLayoutFixture())) as! [String: Any]
        for level in ["definition", "tab", "pane", "split", "leaf"] {
            var object = original
            var tabs = object["tabs"] as! [[String: Any]]
            var panes = tabs[0]["panes"] as! [[String: Any]]
            var tree = tabs[0]["layout"] as! [String: Any]
            switch level {
            case "definition": object["future"] = true
            case "tab": tabs[0]["future"] = true
            case "pane": panes[0]["future"] = true; tabs[0]["panes"] = panes
            case "split": tree["future"] = true; tabs[0]["layout"] = tree
            default:
                var leaf = tree["first"] as! [String: Any]
                leaf["future"] = true
                tree["first"] = leaf
                tabs[0]["layout"] = tree
            }
            object["tabs"] = tabs
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: RPCFailure.self) { try SavedLayoutDefinition.parse(data) }
        }
    }

    @Test func openingsAllocateFreshIDsAndReplaceOnlyTheExplicitGroup() throws {
        var workspace = Workspace()
        let removed = try workspace.split(PaneID(1), direction: .right)
        try workspace.close(removed)
        let targetTab = try workspace.newTab()
        let targetGroup = try #require(workspace.groups.first { $0.tabs.contains(targetTab) }).id
        let targetSecondTab = try workspace.newTab(in: targetGroup)
        let original = workspace
        let definition = savedLayoutFixture()
        let opening = try definition.opening(in: workspace, replacing: targetGroup)
        #expect(workspace == original)
        #expect(opening.groupID != targetGroup)
        #expect(opening.workspace.groups.first == original.groups.first)
        #expect(opening.workspace.tabs.first == original.tabs.first)
        #expect(!opening.workspace.tabs.contains { $0.id == targetTab || $0.id == targetSecondTab })
        #expect(Set(opening.panes.keys).isDisjoint(with: Set(original.panes.map(\.id))))
        #expect(opening.panes.keys.allSatisfy { $0.number > (original.panes.map(\.id.number).max() ?? 0) })
        let group = try #require(opening.workspace.groups.first { $0.id == opening.groupID })
        #expect(group.tabs.count == 2)
        #expect(opening.workspace.keyTabID == group.tabs.first)
        for (index, id) in group.tabs.enumerated() {
            let tab = try #require(opening.workspace.tabs.first { $0.id == id })
            #expect(templateLayout(tab.layout, mapping: opening.panes) == definition.tabs[index].layout)
        }
        for (id, recipe) in opening.panes {
            let pane = try #require(opening.workspace.panes.first { $0.id == id })
            #expect(pane.manualTitle == (recipe.title.isEmpty ? nil : recipe.title))
            if recipe.type == "missing.plugin" { #expect(pane.type == .registered("missing.plugin")) }
        }
        #expect(try Workspace.restore(opening.workspace.encoded()) == opening.workspace)
        let another = try definition.opening(in: opening.workspace)
        #expect(another.workspace.groups.count == opening.workspace.groups.count + 1)
        #expect(Set(another.panes.keys).isDisjoint(with: Set(opening.panes.keys)))
        #expect(try workspace.split(PaneID(1), direction: .right) == PaneID(5))
    }

    @Test func invalidDefinitionsCannotMutateTheWorkspace() throws {
        let workspace = Workspace()
        let original = workspace
        var invalid = SavedLayoutDefinition.blank()
        invalid.tabs[0].layout = .pane(PaneID(99))
        #expect(throws: RPCFailure.self) { try invalid.opening(in: workspace, replacing: GroupID(1)) }
        #expect(throws: RPCFailure.self) { try SavedLayoutDefinition.blank().opening(in: workspace, replacing: GroupID(999)) }
        #expect(workspace == original)
    }

    @Test func structureAndBuiltInConfigurationsHaveExplicitBounds() throws {
        var cases: [SavedLayoutDefinition] = []
        var value = SavedLayoutDefinition.blank()
        value.version = 2; cases.append(value)
        value = .blank(); value.tabs = []; cases.append(value)
        value = .blank(); value.tabs = Array(repeating: value.tabs[0], count: 9); cases.append(value)
        value = .blank(); value.name = "bad\nname"; cases.append(value)
        value = .blank(); value.tabs[0].name = String(repeating: "x", count: 101); cases.append(value)
        value = .blank(); value.tabs[0].panes[0].title = "bad\u{0}"; cases.append(value)
        value = .blank(); value.tabs.append(value.tabs[0]); cases.append(value)
        value = .blank(); value.tabs[0].panes.append(value.tabs[0].panes[0]); cases.append(value)
        for configuration: [String: JSONValue] in [
            ["directory": .string("relative")], ["directory": .integer(1)], ["unknown": .string("x")],
            ["command": .string("a\u{0}b")], ["command": .string(String(repeating: "é", count: 8193))]
        ] {
            value = .blank(); value.tabs[0].panes[0].configuration = configuration; cases.append(value)
        }
        for type in ["browser", "private-browser"] {
            for url in ["file://remote/tmp/x", "https://user:password@example.com", "https://", "not a url"] {
                value = .blank(); value.tabs[0].panes[0].type = type
                value.tabs[0].panes[0].configuration = ["url": .string(url)]; cases.append(value)
            }
        }
        value = .blank(); value.tabs[0].panes[0].type = "Invalid_plugin"; cases.append(value)
        for fraction in [0.09, 0.91, Double.nan, Double.infinity] {
            value = savedLayoutFixture()
            value.tabs[0].layout = .split(axis: .horizontal, fraction: fraction, first: .pane(PaneID(1)), second: .pane(PaneID(2)))
            value.tabs[0].panes.removeLast(); cases.append(value)
        }
        for invalid in cases { #expect(throws: RPCFailure.self) { try invalid.validated() } }
        value = .blank()
        value.tabs[0].panes[0].configuration = ["directory": .string("~/src"), "command": .string(String(repeating: "é", count: 8192))]
        #expect(try value.validated() == value)
        for type in ["browser", "private-browser"] {
            for url in ["", "about:blank", "https://example.com/path?q=hello", "http://localhost:8080", "file:///tmp/page.html", "/tmp/local page.html", "~/Movies/clip.mp4"] {
                value = .blank(); value.tabs[0].panes[0].type = type
                value.tabs[0].panes[0].configuration = ["url": .string(url)]
                #expect(try value.validated() == value)
                #expect(value.problems(types: SavedLayoutPaneType.available(plugins: [])).isEmpty)
            }
        }
        #expect(throws: RPCFailure.self) { try SavedLayoutDefinition.parse(Data(repeating: 32, count: 262_145)) }
    }

    @Test func oversizedOrDeepPluginJSONAndDeepTreesAreRejected() throws {
        var value = SavedLayoutDefinition.blank()
        value.tabs[0].panes[0].type = "opaque.plugin"
        value.tabs[0].panes[0].configuration = ["payload": .string(String(repeating: "x", count: 262_144))]
        #expect(throws: RPCFailure.self) { try value.validated() }
        var json: JSONValue = .null
        for _ in 0..<34 { json = .array([json]) }
        value.tabs[0].panes[0].configuration = ["payload": json]
        #expect(throws: RPCFailure.self) { try value.validated() }
        var tree: Layout = .pane(PaneID(1))
        for _ in 0..<9 { tree = .split(axis: .horizontal, fraction: 0.5, first: tree, second: .pane(PaneID(1))) }
        value = .blank(); value.tabs[0].layout = tree
        #expect(throws: RPCFailure.self) { try value.validated() }
        let bytes = try JSONEncoder().encode(value)
        #expect(throws: RPCFailure.self) { try SavedLayoutDefinition.parse(bytes) }
    }
}

private func savedLayoutFixture() -> SavedLayoutDefinition {
    SavedLayoutDefinition(name: "Development", tabs: [
        SavedLayoutTab(name: "Tools", layout: .split(axis: .horizontal, fraction: 0.3, first: .pane(PaneID(1)),
            second: .split(axis: .vertical, fraction: 0.7, first: .pane(PaneID(2)), second: .pane(PaneID(3)))), panes: [
                SavedLayoutPane(id: PaneID(1), title: "Editor", configuration: ["directory": .string("/tmp"), "command": .string("vim")]),
                SavedLayoutPane(id: PaneID(2), type: "browser", title: "Docs", configuration: ["url": .string("https://example.com")]),
                SavedLayoutPane(id: PaneID(3), type: "missing.plugin", title: "Plugin", configuration: [
                    "future": .object(["array": .array([.integer(7), .bool(true), .null, .string("opaque")])])])]),
        SavedLayoutTab(name: "Logs", layout: .pane(PaneID(4)), panes: [SavedLayoutPane(id: PaneID(4), title: "Server")])
    ])
}

private func templateLayout(_ layout: Layout, mapping: [PaneID: SavedLayoutPane]) -> Layout {
    switch layout {
    case .pane(let id): return .pane(mapping[id]!.id)
    case .split(let axis, let fraction, let first, let second):
        return .split(axis: axis, fraction: fraction, first: templateLayout(first, mapping: mapping), second: templateLayout(second, mapping: mapping))
    }
}
