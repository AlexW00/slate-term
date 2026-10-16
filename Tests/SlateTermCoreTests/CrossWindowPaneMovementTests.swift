import Foundation
import Testing
@testable import SlateTermCore

@Test(arguments: Direction.allCases)
func crossTabMoveRetainsPaneAndRepairsBothHistories(direction: Direction) throws {
    var workspace = Workspace()
    let source = try workspace.split(PaneID(1), direction: .right)
    try workspace.setManualTitle("Build", for: source)
    try workspace.setHeaderVisible(false, for: source)
    let destinationTab = try workspace.newTab()
    let target = try workspace.resolvedTab(tab: destinationTab).focusedPane
    let panes = workspace.panes
    try workspace.move(source, beside: target, direction: direction)
    #expect(workspace.panes == panes)
    #expect(try workspace.resolvedTab(tab: TabID(1)).layout == .pane(PaneID(1)))
    #expect(try workspace.resolvedTab(tab: TabID(1)).terminalHistory == [PaneID(1)])
    let destination = try workspace.resolvedTab(tab: destinationTab)
    #expect(destination.layout == .split(axis: direction.axis, fraction: 0.5,
        first: .pane(direction.insertsBefore ? source : target), second: .pane(direction.insertsBefore ? target : source)))
    #expect(destination.focusedPane == source && destination.terminalHistory == [source, target])
    #expect(workspace.keyTabID == destinationTab)
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
    #expect(try workspace.split(target, direction: .down) == PaneID(4))
}

@Test(arguments: [false, true])
func solePaneTransferRemovesOnlySourceTabAndEmptyGroup(reverse: Bool) throws {
    var workspace = Workspace()
    let otherTab = try workspace.newTab()
    let source = reverse ? PaneID(2) : PaneID(1)
    let target = reverse ? PaneID(1) : PaneID(2)
    let sourceTab = try workspace.resolvedTab(pane: source).id
    let destinationTab = try workspace.resolvedTab(pane: target).id
    let panes = workspace.panes
    try workspace.move(source, beside: target, direction: .right)
    #expect(workspace.panes == panes)
    #expect(workspace.tabs.map(\.id) == [destinationTab])
    #expect(!workspace.groups.contains { $0.tabs.contains(sourceTab) })
    #expect(workspace.groups.count == 1)
    #expect(try workspace.resolvedTab(pane: source).id == destinationTab)
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
    #expect(otherTab == TabID(2))
}

@Test func nonterminalTransferPreservesDestinationTerminalHistoryAndGroupedSibling() throws {
    var workspace = Workspace()
    try workspace.setType(PaneID(1), to: .registered("notes"))
    let destination = try workspace.newTab(in: GroupID(1))
    let target = try workspace.resolvedTab(tab: destination).focusedPane
    try workspace.move(PaneID(1), beside: target, direction: .down)
    #expect(workspace.groups[0].id == GroupID(1))
    #expect(workspace.groups[0].tabs == [destination])
    #expect(workspace.tabs[0].terminalHistory == [target])
    #expect(workspace.tabs[0].focusedPane == PaneID(1))
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
}

@Test func crossTabDepthFailureLeavesEntireSourceIntact() throws {
    var workspace = Workspace()
    _ = try workspace.newTab()
    for _ in 0..<64 { try workspace.split(PaneID(2), direction: .down) }
    let before = workspace
    #expect(throws: WorkspaceError.self) { try workspace.move(PaneID(1), beside: PaneID(2), direction: .left) }
    #expect(workspace == before)
}

@Test func crossTabCommandResultAndEventsDescribeTransferNotDestruction() throws {
    var workspace = Workspace()
    _ = try workspace.newTab()
    let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    let transition = try WorkspaceTransition.command("pane.move", parameters: ["pane": .string("p1"), "target": .string("p2"), "direction": .string("right")], workspace: workspace, revisions: revisions)
    #expect(transition.result.object?["tabId"] == .string("t2"))
    #expect(transition.result.object?["sourceTabId"] == .string("t1"))
    #expect(transition.result.object?["sourceTabClosed"] == .bool(true))
    #expect(transition.revisions.layoutRevision(TabID(1)) == nil)
    let moved = try #require(transition.changes.first { $0.topic == "host.pane.moved" })
    #expect(moved.tab == nil && moved.pane == PaneID(1))
    #expect(moved.payload["sourceTabId"] == .string("t1"))
    #expect(moved.payload["destinationTabId"] == .string("t2"))
    #expect(moved.payload["sourceLayoutRevision"] == .null)
    #expect(moved.payload["beforeSourceLayoutRevision"] == .string("test:t1:0"))
    #expect(!transition.changes.contains { $0.topic == "host.pane.created" || $0.topic == "host.pane.closed" || $0.topic == "host.layout.resized" })
    let closure = try #require(transition.changes.firstIndex { $0.topic == "host.tab.closed" })
    #expect(try #require(transition.changes.firstIndex { $0.topic == "host.pane.moved" }) < closure)
}

@Test func repeatedCrossTabMovesPreserveExactOwnershipAndMetadata() throws {
    var workspace = Workspace()
    var anchors = [PaneID(1)]
    var moving: [PaneID] = []
    for _ in 0..<3 {
        let tab = try workspace.newTab()
        anchors.append(try workspace.resolvedTab(tab: tab).focusedPane)
    }
    for (index, anchor) in anchors.enumerated() {
        moving.append(try workspace.split(anchor, direction: .right, type: index.isMultiple(of: 2) ? .terminal : .browser))
    }
    let panes = workspace.panes
    for step in 0..<100 {
        let source = moving[step % moving.count]
        let current = try workspace.resolvedTab(pane: source).id
        let destination = try anchors.first { try workspace.resolvedTab(pane: $0).id != current }!
        try workspace.move(source, beside: destination, direction: Direction.allCases[step % 4])
        #expect(workspace.panes == panes)
        let leaves = workspace.tabs.flatMap { $0.layout.paneIDs }
        #expect(leaves.count == panes.count && Set(leaves) == Set(panes.map(\.id)))
        #expect(try Workspace.restore(workspace.encoded()) == workspace)
    }
}

@Test func crossTabCommandRejectsDestinationZoomAtomically() throws {
    var workspace = Workspace()
    _ = try workspace.newTab()
    try workspace.toggleZoom(PaneID(2))
    let before = workspace
    #expect(throws: RPCFailure.self) {
        _ = try CommandRegistry.execute("pane.move", params: ["pane": .string("p1"), "target": .string("p2"), "direction": .string("left")], workspace: &workspace)
    }
    #expect(workspace == before)
}
