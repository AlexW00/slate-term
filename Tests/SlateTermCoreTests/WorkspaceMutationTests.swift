import Foundation
import Testing
@testable import SlateTermCore

@Test(arguments: Direction.allCases) func atomicSplitsUseNewPaneFractionsAndPreserveFocus(direction: Direction) throws {
    var workspace = Workspace()
    let pane = try workspace.split(PaneID(1), direction: direction, type: .browser, newPaneFraction: 0.25, focus: .preserve)
    let first = direction.insertsBefore ? Layout.pane(pane) : .pane(PaneID(1))
    let second = direction.insertsBefore ? Layout.pane(PaneID(1)) : .pane(pane)
    let subtree = Layout.split(axis: direction.axis, fraction: direction.insertsBefore ? 0.25 : 0.75, first: first, second: second)
    #expect(workspace.tabs[0].layout == subtree)
    #expect(workspace.panes.last?.type == .browser)
    #expect(workspace.tabs[0].focusedPane == PaneID(1))
    #expect(workspace.tabs[0].terminalHistory == [PaneID(1)])
    let root = try workspace.splitRoot(TabID(1), direction: .left, type: .terminal, newPaneFraction: 0.3, focus: .preserve)
    #expect(workspace.tabs[0].layout == .split(axis: .horizontal, fraction: 0.3, first: .pane(root), second: subtree))
    #expect(workspace.tabs[0].focusedPane == PaneID(1))
    #expect(workspace.tabs[0].terminalHistory == [PaneID(1), root])
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
}

@Test func invalidAtomicSplitsDoNotAllocateIdentitiesOrChangeTopology() throws {
    var workspace = Workspace()
    let before = workspace
    for fraction in [Double.nan, .infinity, -.infinity, 0, 1, -0.01, 1.01] {
        #expect(throws: WorkspaceError.self) { try workspace.split(PaneID(1), direction: .right, newPaneFraction: fraction) }
        #expect(throws: WorkspaceError.self) { try workspace.splitRoot(TabID(1), direction: .left, newPaneFraction: fraction) }
        #expect(workspace == before)
    }
    #expect(throws: WorkspaceError.self) { try workspace.splitRoot(TabID(999), direction: .down) }
    #expect(workspace == before)
    #expect(try workspace.split(PaneID(1), direction: .right) == PaneID(2))
}

@Test func preserveSplitFocusDoesNotActivateBackgroundTabs() throws {
    var workspace = Workspace()
    let front = try workspace.newTab()
    let pane = try workspace.splitRoot(TabID(1), direction: .down, focus: .preserve)
    #expect(workspace.keyTabID == front)
    #expect(workspace.tabs[0].focusedPane == PaneID(1))
    #expect(workspace.tabs[0].terminalHistory == [PaneID(1), pane])
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
}

@Test func tabMovesUseFinalIndicesAndRejectInvalidDestinationsAtomically() throws {
    var workspace = Workspace()
    let t2 = try workspace.newTab(in: GroupID(1))
    let t3 = try workspace.newTab()
    let panes = workspace.panes
    let second = try #require(workspace.groups.last).id
    try workspace.moveTab(TabID(1), to: second, at: 0)
    #expect(workspace.groups.first?.tabs == [t2])
    #expect(workspace.groups.last?.tabs == [TabID(1), t3])
    #expect(workspace.keyTabID == t3)
    try workspace.reorderTab(t3, to: 0)
    #expect(workspace.groups.last?.tabs == [t3, TabID(1)])
    let before = workspace
    for index in [-1, 2, Int.max] {
        #expect(throws: WorkspaceError.self) { try workspace.moveTab(t3, to: second, at: index) }
        #expect(workspace == before)
    }
    #expect(throws: WorkspaceError.self) { try workspace.moveTab(t3, to: GroupID(999), at: 0) }
    #expect(workspace == before)
    try workspace.reorderTab(t3, to: 0)
    #expect(workspace == before)
    #expect(workspace.panes == panes)
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
}

@Test func nativeGroupIdentitiesDoNotFollowAFirstTabIntoAnotherWindow() throws {
    var workspace = Workspace()
    let t2 = try workspace.newTab(in: GroupID(1))
    let t3 = try workspace.newTab()
    try workspace.adoptTabGroups([[TabID(1), t3], [t2]], retaining: [GroupID(2), GroupID(1)])
    #expect(workspace.groups.map(\.id) == [GroupID(1), GroupID(2)])
    #expect(workspace.groups.map(\.tabs) == [[t2], [TabID(1), t3]])
    let before = workspace
    try workspace.adoptTabGroups([[t2], [TabID(1), t3]], retaining: [GroupID(1), GroupID(2)])
    #expect(workspace == before)
    #expect(throws: WorkspaceError.self) { try workspace.adoptTabGroups([[t2], [TabID(1), t3]], retaining: [GroupID(1), GroupID(1)]) }
    #expect(workspace == before)
    try workspace.adoptTabGroups([[TabID(1)], [t2], [t3]], retaining: [nil, GroupID(1), GroupID(2)])
    #expect(workspace.groups.map(\.id) == [GroupID(1), GroupID(2), GroupID(3)])
    #expect(workspace.groups.last?.tabs == [TabID(1)])
}

@Test func detachingASingletonIsAnIdentityPreservingNoop() throws {
    var workspace = Workspace()
    let before = workspace
    #expect(try workspace.detach(TabID(1)) == GroupID(1))
    #expect(workspace == before)
    let t2 = try workspace.newTab(in: GroupID(1))
    #expect(try workspace.detach(t2) == GroupID(2))
    #expect(workspace.groups.map(\.tabs) == [[TabID(1)], [t2]])
}

@Test func legacyCommandDescriptorsDecodeWithoutNewControlOrContractFields() throws {
    let data = Data(#"{"id":"split.right","title":"Split Right","key":"d","shift":false,"alt":false}"#.utf8)
    let command = try JSONDecoder().decode(WorkspaceCommand.self, from: data)
    #expect(command.control == false)
    #expect(command.contract.pluginAccessible)
    let detach = try #require(CommandRegistry.commands.first { $0.id == "tab.detachCurrent" })
    #expect(detach.control && detach.key == "n" && !detach.shift && !detach.alt)
    #expect(try JSONDecoder().decode(WorkspaceCommand.self, from: JSONEncoder().encode(detach)).control)
}

@Test func mutationCommandAdaptersValidateBeforeCommitting() throws {
    var workspace = Workspace()
    let before = workspace
    let invalids: [[String: JSONValue]] = [
        ["direction": .string("right"), "newPaneFraction": .string("0.2")],
        ["direction": .string("right"), "focus": .string("guess")],
        ["direction": .string("right"), "target": .string("missing")],
        ["direction": .string("right"), "typo": .bool(true)]
    ]
    for invalid in invalids {
        #expect(throws: (any Error).self) { try CommandRegistry.execute("pane.split", params: invalid, workspace: &workspace) }
        #expect(workspace == before)
    }
    let result = try CommandRegistry.execute("pane.split", params: ["direction": .string("right"), "target": .string("root"), "type": .string("browser"), "newPaneFraction": .number(0.25), "focus": .string("preserve")], workspace: &workspace)
    #expect(result.object?["paneId"] == .string("p2"))
    #expect(workspace.panes.last?.type == .browser)
    #expect(workspace.tabs[0].focusedPane == PaneID(1))
    let other = try workspace.newTab()
    let pair = workspace
    #expect(throws: (any Error).self) { try CommandRegistry.execute("pane.title.set", params: ["pane": .string("p1"), "tab": .string(other.description), "title": .string("wrong owner")], workspace: &workspace) }
    #expect(workspace == pair)
    #expect(CommandContract.forCommand("pane.split").pluginAccessible)
    #expect(CommandContract.forCommand("pane.split").requiresArguments)
    #expect(CommandContract.forCommand("tab.detachCurrent").pluginAccessible == false)
    #expect(CommandContract.forCommand("tab.detachCurrent").workspaceIndependent == false)
}

@Test func manualTitlesAreBoundedWithoutChangingContentOrLayoutRevision() throws {
    var workspace = Workspace()
    var revisions = WorkspaceRevisions(epoch: "titles", workspace: workspace)
    let layoutRevision = revisions.layoutRevision(TabID(1))
    try workspace.setManualTitle("  build task  ", for: PaneID(1))
    #expect(workspace.panes[0].manualTitle == "build task")
    _ = revisions.observe(workspace)
    #expect(revisions.layoutRevision(TabID(1)) == layoutRevision)
    let before = workspace
    #expect(throws: WorkspaceError.self) { try workspace.setManualTitle(String(repeating: "😀", count: 1025), for: PaneID(1)) }
    #expect(workspace == before)
    try workspace.setManualTitle("\n  ", for: PaneID(1))
    #expect(workspace.panes[0].manualTitle == nil)
    #expect(workspace.panes[0].type == .terminal)
}
