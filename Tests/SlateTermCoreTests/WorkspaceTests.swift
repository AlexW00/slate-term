import Foundation
import Testing
@testable import SlateTermCore

@Test func initialWorkspaceHasOneTerminalAndExplicitTabGroup() throws {
    let workspace = Workspace()
    #expect(workspace.tabs.count == 1)
    #expect(workspace.groups.count == 1)
    #expect(workspace.groups[0].tabs == [TabID(1)])
    #expect(workspace.keyTabID == TabID(1))
    let tab = try #require(workspace.tabs.first)
    #expect(tab.id == TabID(1))
    #expect(tab.layout == .pane(PaneID(1)))
    #expect(tab.focusedPane == PaneID(1))
    #expect(tab.activeTerminal == PaneID(1))
}

@Test(arguments: Direction.allCases) func splitPlacement(direction: Direction) throws {
    var workspace = Workspace()
    let pane = try workspace.split(PaneID(1), direction: direction)
    let layout = try #require(workspace.tabs.first).layout
    let expected: Layout
    switch direction {
    case .left: expected = .split(axis: .horizontal, fraction: 0.5, first: .pane(pane), second: .pane(PaneID(1)))
    case .right: expected = .split(axis: .horizontal, fraction: 0.5, first: .pane(PaneID(1)), second: .pane(pane))
    case .up: expected = .split(axis: .vertical, fraction: 0.5, first: .pane(pane), second: .pane(PaneID(1)))
    case .down: expected = .split(axis: .vertical, fraction: 0.5, first: .pane(PaneID(1)), second: .pane(pane))
    }
    #expect(layout == expected)
    #expect(pane == PaneID(2))
    #expect(workspace.tabs[0].focusedPane == pane)
    #expect(workspace.tabs[0].activeTerminal == pane)
}

@Test func nestedCloseCollapsesOnlyTheAffectedParent() throws {
    var workspace = Workspace()
    let right = try workspace.split(PaneID(1), direction: .right)
    let bottom = try workspace.split(right, direction: .down)
    try workspace.close(right)
    #expect(workspace.tabs[0].layout == .split(axis: .horizontal, fraction: 0.5,
                                            first: .pane(PaneID(1)), second: .pane(bottom)))
    #expect(workspace.tabs[0].focusedPane == bottom)
    #expect(workspace.panes.map(\.id) == [PaneID(1), bottom])
    try workspace.close(bottom)
    #expect(workspace.tabs[0].layout == .pane(PaneID(1)))
    try workspace.close(PaneID(1))
    #expect(workspace.tabs.isEmpty)
    #expect(workspace.groups.isEmpty)
    #expect(workspace.keyTabID == nil)
    #expect(try workspace.newTab() == TabID(2))
    #expect(workspace.panes.map(\.id) == [PaneID(4)])
}

@Test func nonTerminalFocusPreservesActiveTerminalAndCloseUsesHistory() throws {
    var workspace = Workspace()
    let second = try workspace.split(PaneID(1), direction: .right)
    let plugin = try workspace.split(second, direction: .down, type: .registered("git.dashboard"))
    #expect(workspace.tabs[0].focusedPane == plugin)
    #expect(workspace.tabs[0].activeTerminal == second)
    try workspace.focus(PaneID(1))
    try workspace.focus(plugin)
    #expect(workspace.tabs[0].activeTerminal == PaneID(1))
    try workspace.close(PaneID(1))
    #expect(workspace.tabs[0].activeTerminal == second)
    try workspace.close(second)
    #expect(workspace.tabs[0].activeTerminal == nil)
    #expect(workspace.tabs[0].focusedPane == plugin)
}

@Test func rejectedMutationsDoNotChangeStateOrConsumeIDs() throws {
    var workspace = Workspace()
    let before = workspace
    #expect(throws: WorkspaceError.self) { try workspace.split(PaneID(999), direction: .right) }
    #expect(throws: WorkspaceError.self) { try workspace.close(PaneID(999)) }
    #expect(throws: WorkspaceError.self) { try workspace.focus(PaneID(999)) }
    #expect(throws: WorkspaceError.self) { try workspace.newTab(in: GroupID(999)) }
    #expect(workspace == before)
    #expect(try workspace.split(PaneID(1), direction: .left) == PaneID(2))
}

@Test func nativeTabDetachAndMergePreserveIdentityAndLayout() throws {
    var workspace = Workspace()
    let second = try workspace.newTab(in: GroupID(1))
    let pane = try #require(workspace.tabs.last).focusedPane
    _ = try workspace.split(pane, direction: .up)
    let layout = workspace.tabs[1].layout
    let group = try workspace.detach(second)
    #expect(workspace.groups.count == 2)
    #expect(workspace.groups[0].tabs == [TabID(1)])
    #expect(workspace.groups[1].tabs == [second])
    #expect(workspace.tabs[1].layout == layout)
    try workspace.moveTab(second, to: GroupID(1))
    #expect(!workspace.groups.contains { $0.id == group })
    #expect(workspace.groups[0].tabs == [TabID(1), second])
    #expect(workspace.tabs[1].layout == layout)
}

@Test func restorationPreservesIdentityAndMonotonicCounters() throws {
    var workspace = Workspace()
    let closed = try workspace.split(PaneID(1), direction: .right)
    try workspace.close(closed)
    let tab = try workspace.newTab()
    try workspace.closeTab(tab)
    let data = try workspace.encoded()
    var restored = try Workspace.restore(data)
    #expect(restored == workspace)
    #expect(try restored.split(PaneID(1), direction: .down) == PaneID(4))
    #expect(try restored.newTab() == TabID(3))
    #expect(restored.groups.map(\.id) == [GroupID(1), GroupID(3)])
}

@Test func manualPaneTitlesFollowTheSlotAndSurviveRestoration() throws {
    var workspace = Workspace()
    try workspace.setManualTitle("  作業メモ  ", for: PaneID(1))
    let other = try workspace.split(PaneID(1), direction: .right)
    try workspace.setType(PaneID(1), to: .registered("notes"))
    var restored = try Workspace.restore(workspace.encoded())
    #expect(restored.panes.first { $0.id == PaneID(1) }?.manualTitle == "作業メモ")
    #expect(restored.panes.first { $0.id == other }?.manualTitle == nil)
    let before = restored
    #expect(throws: WorkspaceError.paneNotFound(PaneID(999))) {
        try restored.setManualTitle("Missing", for: PaneID(999))
    }
    #expect(restored == before)
    try restored.setManualTitle(" \n\t ", for: PaneID(1))
    #expect(try Workspace.restore(restored.encoded()).panes[0].manualTitle == nil)
}

@Test func restoreAcceptsWorkspacesWithoutManualTitles() throws {
    var workspace = Workspace()
    try workspace.setManualTitle("Old title", for: PaneID(1))
    var object = try #require(JSONSerialization.jsonObject(with: workspace.encoded()) as? [String: Any])
    var panes = try #require(object["panes"] as? [[String: Any]])
    panes[0].removeValue(forKey: "manualTitle")
    object["panes"] = panes
    let restored = try Workspace.restore(JSONSerialization.data(withJSONObject: object))
    #expect(restored == Workspace())
}

@Test func restoreRejectsDanglingFocusAndStaleCounters() throws {
    let workspace = Workspace()
    let object = try #require(JSONSerialization.jsonObject(with: workspace.encoded()) as? [String: Any])
    var invalid = object
    invalid["nextPane"] = 1
    #expect(throws: (any Error).self) {
        try Workspace.restore(JSONSerialization.data(withJSONObject: invalid))
    }
    invalid = object
    invalid["schemaVersion"] = 999
    #expect(throws: (any Error).self) {
        try Workspace.restore(JSONSerialization.data(withJSONObject: invalid))
    }
    invalid = object
    var tabs = try #require(invalid["tabs"] as? [[String: Any]])
    tabs[0]["focusedPane"] = "p999"
    invalid["tabs"] = tabs
    #expect(throws: (any Error).self) {
        try Workspace.restore(JSONSerialization.data(withJSONObject: invalid))
    }
}

@Test func fractionsAreFiniteInteriorValuesAndResizeIsAtomic() throws {
    var workspace = Workspace()
    _ = try workspace.split(PaneID(1), direction: .right)
    try workspace.resize(tab: TabID(1), path: [], fraction: 0.3)
    #expect(workspace.tabs[0].layout == .split(axis: .horizontal, fraction: 0.3,
                                            first: .pane(PaneID(1)), second: .pane(PaneID(2))))
    let before = workspace
    for fraction in [0.0, 1.0, -0.1, Double.nan, Double.infinity] {
        #expect(throws: WorkspaceError.self) {
            try workspace.resize(tab: TabID(1), path: [], fraction: fraction)
        }
        #expect(workspace == before)
    }
    #expect(throws: WorkspaceError.self) {
        try workspace.resize(tab: TabID(1), path: [.first], fraction: 0.4)
    }
    #expect(workspace == before)
}
