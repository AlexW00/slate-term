import Testing
@testable import SlateTermCore

@Suite struct SavedLayoutTabTests {
    @Test func automaticNamesFollowRemoveMoveAndAdd() throws {
        var layout = SavedLayoutDefinition.blank()
        for _ in 0..<3 { _ = try layout.addTab() }
        let moved = layout.tabs[2]
        try layout.moveTab(from: 2, to: 0)
        #expect(layout.tabs[0].panes == moved.panes)
        #expect(layout.tabs.map(\.name) == ["Tab 1", "Tab 2", "Tab 3", "Tab 4"])
        try layout.removeTab(at: 1)
        #expect(layout.tabs.map(\.name) == ["Tab 1", "Tab 2", "Tab 3"])
        _ = try layout.addTab()
        #expect(layout.tabs.map(\.name) == ["Tab 1", "Tab 2", "Tab 3", "Tab 4"])
        #expect(try layout.validated() == layout)
    }

    @Test func customNamesAndPaneRecipesSurviveReordering() throws {
        var layout = SavedLayoutDefinition.blank()
        _ = try layout.addTab(); _ = try layout.addTab()
        layout.tabs[1].name = "Server"
        layout.tabs[1].panes[0].configuration = ["command": .string("echo server")]
        let custom = layout.tabs[1]
        try layout.moveTab(from: 1, to: 2)
        #expect(layout.tabs.map(\.name) == ["Tab 1", "Tab 2", "Server"])
        #expect(layout.tabs[2] == custom)
        try layout.removeTab(at: 0)
        #expect(layout.tabs.map(\.name) == ["Tab 1", "Server"])
        _ = try layout.addTab()
        #expect(layout.tabs.map(\.name) == ["Tab 1", "Server", "Tab 3"])
    }

    @Test func legacyGapsAndDuplicatesNormalizeOnMutation() throws {
        var layout = SavedLayoutDefinition.blank()
        _ = try layout.addTab()
        layout.tabs[0].name = "Tab 2"; layout.tabs[1].name = "Tab 2"
        _ = try layout.addTab()
        #expect(layout.tabs.map(\.name) == ["Tab 1", "Tab 2", "Tab 3"])
    }

    @Test func limitsAndInvalidIndicesLeaveDefinitionUntouched() throws {
        var layout = SavedLayoutDefinition.blank()
        let original = layout
        #expect(throws: RPCFailure.self) { try layout.removeTab(at: 0) }
        #expect(throws: RPCFailure.self) { try layout.moveTab(from: 0, to: 1) }
        #expect(throws: RPCFailure.self) { try layout.removeTab(at: -1) }
        #expect(layout == original)
        for _ in 0..<7 { _ = try layout.addTab() }
        let full = layout
        #expect(throws: RPCFailure.self) { try layout.addTab() }
        #expect(layout == full)
        #expect(Set(layout.tabs.flatMap(\.panes).map(\.id)).count == 8)
    }
}

@Test func pluginReloadUsesCapturedPaneDefaultsAndIsDiscoverable() {
    let command = CommandRegistry.commands.first { $0.id == "plugins.reload" }
    #expect(command != nil)
    #expect(command?.contract.workspaceIndependent == false)
    let defaults = AutomationDefaults(pane: PaneID(2), tab: TabID(2))
    #expect(AutomationMethod.commandRun.resolving(["id": .string("plugins.reload")], defaults: defaults)["pane"] == .string("p2"))
    #expect(AutomationMethod.commandRun.resolving(["id": .string("plugins.reload"), "pane": .string("p9")], defaults: defaults)["tab"] == nil)
    #expect(!CommandRegistry.commands.contains { $0.id == "layouts.replaceWindow" })
}
