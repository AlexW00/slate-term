import Foundation
import Testing
@testable import SlateTermCore

@Test func directionalFocusUsesSplitGeometryWithoutWrapping() throws {
    var workspace = Workspace()
    let right = try workspace.split(PaneID(1), direction: .right)
    let bottom = try workspace.split(right, direction: .down)
    try workspace.focus(right, direction: .left)
    #expect(workspace.tabs[0].focusedPane == PaneID(1))
    try workspace.focus(PaneID(1), direction: .right)
    #expect(workspace.tabs[0].focusedPane == right)
    try workspace.focus(right, direction: .down)
    #expect(workspace.tabs[0].focusedPane == bottom)
    let before = workspace
    try workspace.focus(bottom, direction: .down)
    #expect(workspace == before)
    try workspace.focus(bottom, direction: .up)
    #expect(workspace.tabs[0].focusedPane == right)
}

@Test func zoomPreservesLayoutAndFollowsFocusUntilSplitOrToggle() throws {
    var workspace = Workspace()
    let other = try workspace.split(PaneID(1), direction: .right)
    let layout = workspace.tabs[0].layout
    try workspace.toggleZoom(other)
    #expect(workspace.tabs[0].zoomedPane == other)
    #expect(workspace.tabs[0].layout == layout)
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
    try workspace.focus(PaneID(1))
    #expect(workspace.tabs[0].zoomedPane == PaneID(1))
    try workspace.toggleZoom(PaneID(1))
    #expect(workspace.tabs[0].zoomedPane == nil)
    try workspace.toggleZoom(other)
    _ = try workspace.split(other, direction: .down)
    #expect(workspace.tabs[0].zoomedPane == nil)
    try workspace.toggleZoom(other)
    try workspace.close(other)
    #expect(workspace.tabs[0].zoomedPane == nil)
}

@Test func equalizeAssignsEqualPaneAreasAndPreservesFocus() throws {
    var workspace = Workspace()
    let second = try workspace.split(PaneID(1), direction: .right)
    let third = try workspace.split(second, direction: .right)
    try workspace.resize(tab: TabID(1), path: [], fraction: 0.8)
    try workspace.equalize(TabID(1))
    #expect(workspace.tabs[0].layout == .split(axis: .horizontal, fraction: 1.0 / 3.0,
        first: .pane(PaneID(1)), second: .split(axis: .horizontal, fraction: 0.5, first: .pane(second), second: .pane(third))))
    #expect(workspace.tabs[0].focusedPane == third)
    let before = workspace
    #expect(throws: WorkspaceError.tabNotFound(TabID(99))) { try workspace.equalize(TabID(99)) }
    #expect(workspace == before)
}

@Test func restorationRejectsZoomOutsideFocusedPaneButAcceptsLegacyTabs() throws {
    let workspace = Workspace()
    var snapshot = try #require(JSONSerialization.jsonObject(with: workspace.encoded()) as? [String: Any])
    var tabs = try #require(snapshot["tabs"] as? [[String: Any]])
    tabs[0]["zoomedPane"] = "p99"
    snapshot["tabs"] = tabs
    #expect(throws: WorkspaceError.self) { try Workspace.restore(JSONSerialization.data(withJSONObject: snapshot)) }
    tabs[0].removeValue(forKey: "zoomedPane")
    snapshot["tabs"] = tabs
    #expect(try Workspace.restore(JSONSerialization.data(withJSONObject: snapshot)) == workspace)
}

@Test func tabCommandsFollowGroupOrderWrapAndStayInTheirWindow() throws {
    var workspace = Workspace()
    let first = TabID(1)
    let second = try workspace.newTab(in: workspace.groups[0].id)
    let third = try workspace.newTab(in: workspace.groups[0].id)
    let otherWindow = try workspace.newTab()
    try workspace.focusTab(third)
    _ = try CommandRegistry.execute("tab.next", params: [:], workspace: &workspace)
    #expect(workspace.keyTabID == first)
    _ = try CommandRegistry.execute("tab.previous", params: [:], workspace: &workspace)
    #expect(workspace.keyTabID == third)
    _ = try CommandRegistry.execute("tab.select2", params: [:], workspace: &workspace)
    #expect(workspace.keyTabID == second)
    _ = try CommandRegistry.execute("tab.select9", params: [:], workspace: &workspace)
    #expect(workspace.keyTabID == second)
    _ = try CommandRegistry.execute("tab.next", params: ["tab": .string(otherWindow.description)], workspace: &workspace)
    #expect(workspace.keyTabID == otherWindow)
}
