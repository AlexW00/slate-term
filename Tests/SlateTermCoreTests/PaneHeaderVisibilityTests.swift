import Foundation
import Testing
@testable import SlateTermCore

@Suite struct PaneHeaderVisibilityTests {
    @Test func commandsRetainTopologyFocusAndTitleAndHaveNoOpSemantics() throws {
        var workspace = Workspace()
        _ = try workspace.split(PaneID(1), direction: .right)
        try workspace.setManualTitle("Build", for: PaneID(1))
        let before = workspace
        let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
        let hidden = try WorkspaceTransition.command("pane.header.hide", parameters: ["pane": .string("p1")], workspace: workspace, revisions: revisions)
        #expect(hidden.workspace.tabs == before.tabs && hidden.workspace.groups == before.groups)
        #expect(hidden.workspace.panes[0].manualTitle == "Build")
        #expect(!hidden.workspace.panes[0].headerVisible && hidden.workspace.panes[1].headerVisible)
        #expect(hidden.result.object?["paneId"] == .string("p1"))
        #expect(hidden.result.object?["headerVisible"] == .bool(false))
        #expect(hidden.revisions.revision != revisions.revision)
        #expect(hidden.revisions.layoutRevision(TabID(1)) == revisions.layoutRevision(TabID(1)))
        #expect(hidden.changes.map(\.topic) == ["host.pane.header.changed", "host.workspace.changed"])
        let fact = try #require(hidden.changes.first)
        #expect(fact.pane == PaneID(1) && fact.tab == TabID(1))
        #expect(fact.payload["headerVisible"] == .bool(false))
        #expect(fact.payload["actionKind"] == .string("pane.header.hide"))
        let again = try WorkspaceTransition.command("pane.header.hide", parameters: ["pane": .string("p1")], workspace: hidden.workspace, revisions: hidden.revisions)
        #expect(!again.changed && again.changes.isEmpty && again.revisions.revision == hidden.revisions.revision)
        let shown = try WorkspaceTransition.command("pane.header.show", parameters: ["pane": .string("p1")], workspace: again.workspace, revisions: again.revisions)
        #expect(shown.workspace == before)
        let toggle = try WorkspaceTransition.command("pane.header.toggle", parameters: ["pane": .string("p1")], workspace: shown.workspace, revisions: shown.revisions)
        #expect(toggle.workspace == hidden.workspace)
        workspace = shown.workspace
        _ = try CommandRegistry.execute("pane.header.show", params: [:], workspace: &workspace)
        #expect(workspace == before)
    }

    @Test func explicitAndTabTargetsAreValidatedAndErrorsAreAtomic() throws {
        var workspace = Workspace()
        _ = try workspace.newTab()
        let before = workspace
        for params: [String: JSONValue] in [
            ["pane": .string("p99")], ["pane": .bool(false)],
            ["pane": .string("p1"), "tab": .string("t2")],
            ["headerVisible": .bool(false)], ["unexpected": .bool(true)]
        ] {
            #expect(throws: (any Error).self) { try CommandRegistry.execute("pane.header.hide", params: params, workspace: &workspace) }
            #expect(workspace == before)
        }
        _ = try CommandRegistry.execute("pane.header.hide", params: ["tab": .string("t1")], workspace: &workspace)
        #expect(!workspace.panes[0].headerVisible && workspace.panes[1].headerVisible)
        #expect(workspace.keyTabID == TabID(2))
    }

    @Test func stateSurvivesMovesZoomTypeReplacementAndSnapshotRestore() throws {
        var workspace = Workspace()
        let other = try workspace.split(PaneID(1), direction: .right)
        try workspace.setHeaderVisible(false, for: PaneID(1))
        try workspace.move(PaneID(1), beside: other, direction: .down)
        try workspace.toggleZoom(PaneID(1))
        try workspace.toggleZoom(PaneID(1))
        for type: PaneType in [.browser, .privateBrowser, .registered("headers.fixture"), .terminal] {
            try workspace.setType(PaneID(1), to: type)
            #expect(!workspace.panes[0].headerVisible)
            #expect(try Workspace.restore(workspace.encoded()) == workspace)
        }
        let fresh = try workspace.split(other, direction: .down)
        #expect(workspace.panes.first { $0.id == fresh }?.headerVisible == true)
        let tab = try workspace.newTab()
        #expect(workspace.panes.first { $0.id == workspace.tabs.first { $0.id == tab }?.focusedPane }?.headerVisible == true)
    }

    @Test func oldSnapshotsDefaultShownButMalformedFieldsFail() throws {
        var workspace = Workspace()
        try workspace.setManualTitle("Old title", for: PaneID(1))
        var snapshot = try JSONSerialization.jsonObject(with: workspace.encoded()) as! [String: Any]
        var panes = snapshot["panes"] as! [[String: Any]]
        panes[0].removeValue(forKey: "headerVisible")
        snapshot["panes"] = panes
        #expect(try Workspace.restore(JSONSerialization.data(withJSONObject: snapshot)) == workspace)
        for invalid: Any in [NSNull(), "false", 0, []] {
            panes[0]["headerVisible"] = invalid; snapshot["panes"] = panes
            #expect(throws: (any Error).self) { try Workspace.restore(JSONSerialization.data(withJSONObject: snapshot)) }
        }
    }

    @Test func commandDiscoveryIsParameterlessAndContextual() throws {
        for id in ["pane.header.show", "pane.header.hide", "pane.header.toggle"] {
            let command = try #require(CommandRegistry.commands.first { $0.id == id })
            #expect(!command.contract.requiresArguments && !command.contract.workspaceIndependent)
            #expect(WorkspaceMutationCommand.ids.contains(id))
            #expect(AutomationMethod.commandRun.resolving(["id": .string(id)], defaults: .init(pane: PaneID(1), tab: TabID(1)))["pane"] == .string("p1"))
            #expect(AutomationMethod.commandRun.resolving(["id": .string(id), "pane": .string("p2")], defaults: .init(pane: PaneID(1), tab: TabID(1)))["tab"] == nil)
        }
    }
}
