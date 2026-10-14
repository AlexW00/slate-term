import Foundation
import Testing
@testable import SlateTermCore

@Test(arguments: Direction.allCases)
func movingPaneUsesExistingIdentityAndRequestedEdge(direction: Direction) throws {
    var workspace = Workspace()
    let source = try workspace.split(PaneID(1), direction: .right)
    try workspace.setManualTitle("Running build", for: source)
    let panes = workspace.panes
    try workspace.focus(PaneID(1))
    try workspace.move(source, beside: PaneID(1), direction: direction)
    #expect(workspace.tabs[0].layout == .split(axis: direction.axis, fraction: 0.5,
        first: .pane(direction.insertsBefore ? source : PaneID(1)),
        second: .pane(direction.insertsBefore ? PaneID(1) : source)))
    #expect(workspace.panes == panes)
    #expect(workspace.tabs[0].focusedPane == source)
    #expect(workspace.tabs[0].activeTerminal == source)
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
    #expect(try workspace.split(source, direction: .right) == PaneID(3))
}

@Test func moveCollapsesSourceParentAndPreservesUnrelatedFractions() throws {
    var workspace = Workspace()
    let right = try workspace.split(PaneID(1), direction: .right)
    let bottom = try workspace.split(right, direction: .down)
    let sibling = try workspace.split(PaneID(1), direction: .down)
    try workspace.resize(tab: TabID(1), path: [], fraction: 0.3)
    try workspace.resize(tab: TabID(1), path: [.first], fraction: 0.7)
    try workspace.move(bottom, beside: right, direction: .left)
    #expect(workspace.tabs[0].layout == .split(axis: .horizontal, fraction: 0.3,
        first: .split(axis: .vertical, fraction: 0.7, first: .pane(PaneID(1)), second: .pane(sibling)),
        second: .split(axis: .horizontal, fraction: 0.5, first: .pane(bottom), second: .pane(right))))
    try workspace.move(bottom, beside: sibling, direction: .down)
    #expect(workspace.tabs[0].layout == .split(axis: .horizontal, fraction: 0.3,
        first: .split(axis: .vertical, fraction: 0.7, first: .pane(PaneID(1)),
            second: .split(axis: .vertical, fraction: 0.5, first: .pane(sibling), second: .pane(bottom))),
        second: .pane(right)))
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
}

@Test(arguments: [PaneType.browser, .registered("notes")])
func movingNonTerminalPreservesTerminalHistory(type: PaneType) throws {
    var workspace = Workspace()
    let terminal = try workspace.split(PaneID(1), direction: .right)
    let web = try workspace.split(terminal, direction: .down, type: type)
    try workspace.focus(PaneID(1))
    let history = workspace.tabs[0].terminalHistory
    try workspace.move(web, beside: PaneID(1), direction: .left)
    #expect(workspace.tabs[0].focusedPane == web)
    #expect(workspace.tabs[0].terminalHistory == history)
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
}

@Test func invalidMovesAreAtomicAndSelfMoveIsNoOp() throws {
    var workspace = Workspace()
    let otherTab = try workspace.newTab()
    let other = try #require(workspace.tabs.first { $0.id == otherTab }).focusedPane
    let before = workspace
    #expect(throws: WorkspaceError.self) { try workspace.move(PaneID(1), beside: other, direction: .left) }
    #expect(throws: WorkspaceError.self) { try workspace.move(PaneID(999), beside: other, direction: .left) }
    #expect(throws: WorkspaceError.self) { try workspace.move(other, beside: PaneID(999), direction: .left) }
    try workspace.move(PaneID(1), beside: PaneID(1), direction: .down)
    #expect(workspace == before)
}

@Test func moveRejectsExcessDepthWithoutLosingSource() throws {
    var workspace = Workspace()
    let source = try workspace.split(PaneID(1), direction: .right)
    for _ in 0..<63 { try workspace.split(PaneID(1), direction: .down) }
    let target = try workspace.split(source, direction: .down)
    let before = workspace
    #expect(throws: WorkspaceError.self) { try workspace.move(source, beside: PaneID(1), direction: .left) }
    #expect(workspace == before)
    try workspace.move(source, beside: target, direction: .left)
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
}

@Test func moveExitsZoomAndPreservesBackgroundTabs() throws {
    var workspace = Workspace()
    let source = try workspace.split(PaneID(1), direction: .right)
    try workspace.toggleZoom(source)
    let otherTab = try workspace.newTab()
    let other = try #require(workspace.tabs.first { $0.id == otherTab })
    try workspace.move(source, beside: PaneID(1), direction: .up)
    #expect(workspace.tabs[0].zoomedPane == nil)
    #expect(workspace.keyTabID == TabID(1))
    #expect(workspace.tabs[1] == other)
}

@Test func repeatedMovesPreserveEveryPaneExactlyOnce() throws {
    var workspace = Workspace()
    for _ in 0..<8 { try workspace.split(PaneID(1), direction: .right) }
    let original = workspace.panes
    for step in 0..<100 {
        let source = original[step % original.count].id
        let target = original[(step * 3 + 1) % original.count].id
        try workspace.move(source, beside: target, direction: Direction.allCases[step % 4])
        #expect(workspace.panes == original)
        #expect(Set(workspace.tabs[0].layout.paneIDs) == Set(original.map(\.id)))
        #expect(workspace.tabs[0].layout.paneIDs.count == original.count)
        #expect(try Workspace.restore(workspace.encoded()) == workspace)
    }
}
