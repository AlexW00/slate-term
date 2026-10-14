import Testing
@testable import SlateTermCore

@Test func changingPaneTypeRetainsSlotButUpdatesTerminalContext() throws {
    var workspace = Workspace()
    let second = try workspace.split(PaneID(1), direction: .right)
    let layout = workspace.tabs[0].layout
    try workspace.setType(second, to: .browser)
    #expect(workspace.tabs[0].layout == layout)
    #expect(workspace.tabs[0].focusedPane == second)
    #expect(workspace.tabs[0].activeTerminal == PaneID(1))
    #expect(workspace.panes.first { $0.id == second }?.type == .browser)
    try workspace.setType(second, to: .terminal)
    #expect(workspace.tabs[0].activeTerminal == second)
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
    #expect(try workspace.split(second, direction: .down) == PaneID(3))
}

@Test func changingBackgroundPaneTypeDoesNotStealFocusAndInvalidTargetsAreAtomic() throws {
    var workspace = Workspace()
    let foreground = try workspace.newTab()
    try workspace.setType(PaneID(1), to: .browser)
    #expect(workspace.keyTabID == foreground)
    #expect(workspace.tabs[0].activeTerminal == nil)
    try workspace.setType(PaneID(1), to: .terminal)
    #expect(workspace.keyTabID == foreground)
    let before = workspace
    #expect(throws: WorkspaceError.paneNotFound(PaneID(999))) { try workspace.setType(PaneID(999), to: .browser) }
    #expect(workspace == before)
}
