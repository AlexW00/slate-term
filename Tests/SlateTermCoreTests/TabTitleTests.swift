import Foundation
import Testing
@testable import SlateTermCore

@Suite struct TabTitleTests {
    @Test func appDefaultTitlesApplyToNewRestoredAndExplicitlyClearedTabs() throws {
        var workspace = Workspace()
        try workspace.setManualTabTitle("Explicit", for: TabID(1))
        try workspace.setDefaultTabTitle("Writing")
        let second = try workspace.newTab()
        #expect(workspace.tabs[0].title == "Explicit")
        #expect(workspace.tabs[1].title == "Writing")
        #expect(workspace.tabs[1].manualTitle == nil)
        let clear = try CommandRegistry.execute("tab.title.clear", params: ["tab": .string("t1")], workspace: &workspace)
        #expect(clear.object?["title"] == .string("Writing"))
        #expect(workspace.tabs[0].title == "Writing")
        let encoded = try workspace.encoded()
        #expect(!String(decoding: encoded, as: UTF8.self).contains("defaultTitle"))
        var restored = try Workspace.restore(encoded)
        #expect(restored.tabs.allSatisfy { $0.title == "New Tab" })
        try restored.setDefaultTabTitle("Writing")
        #expect(restored == workspace)
        try restored.setManualTabTitle("Saved explicit", for: second)
        var later = try Workspace.restore(restored.encoded())
        try later.setDefaultTabTitle("Writing")
        #expect(later.tabs[1].title == "Saved explicit")
        let before = later
        #expect(throws: (any Error).self) { try later.setDefaultTabTitle("\n") }
        #expect(later == before)
    }

    @Test func titlesAreTabMetadataAndCommandsShareRouting() throws {
        var workspace = Workspace()
        let second = try workspace.newTab(in: GroupID(1))
        let before = workspace
        let revisions = WorkspaceRevisions(epoch: "titles", workspace: workspace)
        let transition = try WorkspaceTransition.command("tab.title.set", parameters: [
            "pane": .string("p1"), "title": .string("  Build 日本語  ")
        ], workspace: workspace, revisions: revisions)
        workspace = transition.workspace
        #expect(workspace.tabs[0].manualTitle == "Build 日本語")
        #expect(workspace.tabs[0].title == "Build 日本語")
        #expect(workspace.keyTabID == second)
        #expect(workspace.panes == before.panes && workspace.groups == before.groups)
        #expect(workspace.tabs[0].layout == before.tabs[0].layout)
        #expect(workspace.tabs[0].focusedPane == before.tabs[0].focusedPane)
        #expect(transition.revisions.layoutRevision(TabID(1)) == revisions.layoutRevision(TabID(1)))
        #expect(transition.revisions.revision != revisions.revision)
        #expect(transition.changes.map(\.topic) == ["host.tab.title.changed", "host.workspace.changed"])
        #expect(transition.changes.allSatisfy { $0.tab == TabID(1) && $0.pane == nil })
        #expect(transition.changes[0].payload["hasManualTitle"] == .bool(true))
        #expect(!String(describing: transition.changes).contains("Build"))
        #expect(transition.result.object?["title"] == .string("Build 日本語"))
        let noop = try WorkspaceTransition.command("tab.title.set", parameters: ["tab": .string("t1"), "title": .string("Build 日本語")], workspace: workspace, revisions: transition.revisions)
        #expect(!noop.changed && noop.changes.isEmpty)
        #expect(noop.revisions.revision == transition.revisions.revision)
        let clear = try WorkspaceTransition.command("tab.title.clear", parameters: ["tab": .string("t1")], workspace: workspace, revisions: transition.revisions)
        #expect(clear.workspace.tabs[0].manualTitle == nil)
        #expect(clear.workspace.tabs[0].title == "New Tab")
        #expect(clear.changes[0].payload["hasManualTitle"] == .bool(false))
    }

    @Test func normalizationLimitsAndRejectedCommandsAreAtomic() throws {
        var workspace = Workspace()
        let valid = ["Tab 2", "Slate Terminal", String(repeating: "😀", count: 100), String(repeating: "e\u{301}", count: 100), "inside  spaces"]
        for title in valid {
            try workspace.setManualTabTitle(title, for: TabID(1))
            #expect(workspace.tabs[0].manualTitle == title)
        }
        // One grapheme may contain many scalars; both character and byte limits matter.
        let byteBoundary = "a" + String(repeating: "\u{301}", count: 511) + "b"
        try workspace.setManualTabTitle(byteBoundary, for: TabID(1))
        #expect(workspace.tabs[0].manualTitle?.utf8.count == 1024)
        let invalid = [String(repeating: "x", count: 101), byteBoundary + "c", "bad\nname", "bad\tname", "bad\0name", "bad\u{7f}name"]
        for title in invalid {
            let before = workspace
            #expect(throws: (any Error).self) { try workspace.setManualTabTitle(title, for: TabID(1)) }
            #expect(workspace == before)
        }
        try workspace.setManualTabTitle(" \n\t ", for: TabID(1))
        #expect(workspace.tabs[0].manualTitle == nil)
        let second = try workspace.newTab()
        let before = workspace
        let badParams: [[String: JSONValue]] = [[:], ["title": .null], ["title": .integer(1)], ["title": .string("ok"), "typo": .bool(true)], ["title": .string("ok"), "tab": .string("t999")], ["title": .string("ok"), "pane": .string("p999")], ["title": .string("ok"), "pane": .string("p1"), "tab": .string(second.description)]]
        for params in badParams {
            #expect(throws: (any Error).self) { try CommandRegistry.execute("tab.title.set", params: params, workspace: &workspace) }
            #expect(workspace == before)
        }
        #expect(throws: (any Error).self) { try CommandRegistry.execute("tab.title.clear", params: ["title": .string("unexpected")], workspace: &workspace) }
        #expect(workspace == before)
    }

    @Test func titlesRestoreAndFollowIdentity() throws {
        var workspace = Workspace()
        try workspace.setManualTabTitle("Tab 2", for: TabID(1))
        let second = try workspace.newTab(in: GroupID(1))
        try workspace.setManualTabTitle("Tab 2", for: second)
        try workspace.reorderTab(TabID(1), to: 1)
        _ = try workspace.detach(TabID(1))
        #expect(workspace.tabs.allSatisfy { $0.manualTitle == "Tab 2" })
        #expect(try Workspace.restore(workspace.encoded()) == workspace)
        let data = try Workspace().encoded()
        let base = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for value in [NSNull(), "Server"] as [Any] {
            var object = base
            var tabs = object["tabs"] as! [[String: Any]]
            tabs[0]["manualTitle"] = value
            object["tabs"] = tabs
            let restored = try Workspace.restore(JSONSerialization.data(withJSONObject: object))
            #expect(restored.tabs[0].manualTitle == (value as? String))
        }
        for value in ["", " padded ", "\n", "bad\0name", 1, String(repeating: "x", count: 101)] as [Any] {
            var object = base
            var tabs = object["tabs"] as! [[String: Any]]
            tabs[0]["manualTitle"] = value
            object["tabs"] = tabs
            #expect(throws: (any Error).self) { try Workspace.restore(JSONSerialization.data(withJSONObject: object)) }
        }
        #expect(try Workspace.restore(data).tabs[0].title == "New Tab")
    }

    @Test func recipesPreserveLiteralTitlesWithoutReinterpretingEditorLabels() throws {
        var recipe = SavedLayoutDefinition.blank()
        recipe.tabs[0].name = "Editor only"
        #expect(try recipe.opening(in: Workspace()).workspace.tabs.last?.manualTitle == nil)
        recipe.tabs[0].manualTitle = "Tab 2"
        _ = try recipe.addTab()
        try recipe.moveTab(from: 0, to: 1)
        let parsed = try SavedLayoutDefinition.parse(JSONEncoder().encode(recipe))
        let opening = try parsed.opening(in: Workspace())
        #expect(opening.workspace.tabs.last?.manualTitle == "Tab 2")
        #expect(opening.workspace.tabs.last?.id != TabID(1))
        for invalid in ["", " padded ", "bad\nname", String(repeating: "x", count: 101)] {
            recipe.tabs[0].manualTitle = invalid
            #expect(throws: (any Error).self) { try recipe.validated() }
            #expect(throws: (any Error).self) { try SavedLayoutDefinition.parse(JSONEncoder().encode(recipe)) }
        }
    }
}
