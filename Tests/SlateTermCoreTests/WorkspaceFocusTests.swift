import Foundation
import Testing
@testable import SlateTermCore

@Test(arguments: ["split.left", "pane.split", "tab.new", "window.new"])
func structuralCommandsPreserveUnrelatedFocusByDefault(command: String) throws {
    var workspace = Workspace()
    let front = try workspace.newTab()
    let before = try workspace.resolvedTab(tab: front)
    var params: [String: JSONValue] = ["pane": .string("p1")]
    if command == "pane.split" { params["direction"] = .string("left") }
    _ = try CommandRegistry.execute(command, params: params, workspace: &workspace)
    #expect(workspace.keyTabID == front)
    #expect(try workspace.resolvedTab(tab: front) == before)
    #expect(try workspace.resolvedTab(tab: TabID(1)).focusedPane == PaneID(1))
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
}

@Test(arguments: ["split.left", "pane.split", "tab.new", "window.new"])
func structuralCommandsCanExplicitlySelectNewContent(command: String) throws {
    var workspace = Workspace()
    let front = try workspace.newTab()
    var params: [String: JSONValue] = ["pane": .string("p1"), "focus": .string("new")]
    if command == "pane.split" { params["direction"] = .string("left") }
    let result = try CommandRegistry.execute(command, params: params, workspace: &workspace)
    #expect(workspace.keyTabID != front)
    if let pane = result.object?["paneId"]?.string {
        #expect(try workspace.resolvedTab().focusedPane.description == pane)
    } else {
        #expect(workspace.keyTabID?.description == result.object?["tabId"]?.string)
    }
}

@Test func movingBackgroundPanePreservesSourceDestinationAndGlobalSelection() throws {
    var workspace = Workspace()
    let moved = try workspace.split(PaneID(1), direction: .right)
    let destination = try workspace.newTab()
    let target = try workspace.resolvedTab(tab: destination).focusedPane
    let front = try workspace.newTab()
    let frontState = try workspace.resolvedTab(tab: front)
    _ = try CommandRegistry.execute("pane.move", params: ["pane": .string(moved.description),
        "target": .string(target.description), "direction": .string("right")], workspace: &workspace)
    #expect(workspace.keyTabID == front)
    #expect(try workspace.resolvedTab(tab: front) == frontState)
    #expect(try workspace.resolvedTab(tab: destination).focusedPane == target)
    #expect(try workspace.resolvedTab(tab: destination).terminalHistory == [target, moved])
    #expect(try workspace.resolvedTab(tab: TabID(1)).focusedPane == PaneID(1))
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
    _ = try CommandRegistry.execute("pane.move", params: ["pane": .string(moved.description),
        "target": .string("p1"), "direction": .string("right"), "focus": .string("target")], workspace: &workspace)
    #expect(workspace.keyTabID == TabID(1))
    #expect(try workspace.resolvedTab().focusedPane == moved)
}

@Test func movingTheSelectedPaneRetainsThatPaneAcrossWindows() throws {
    var workspace = Workspace()
    let destination = try workspace.newTab()
    let target = try workspace.resolvedTab(tab: destination).focusedPane
    try workspace.focus(PaneID(1))
    _ = try CommandRegistry.execute("pane.move", params: ["pane": .string("p1"),
        "target": .string(target.description), "direction": .string("left")], workspace: &workspace)
    #expect(workspace.keyTabID == destination)
    #expect(try workspace.resolvedTab().focusedPane == PaneID(1))
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
}

@Test(arguments: ["split.left", "pane.split", "pane.move", "tab.new", "window.new"])
func invalidStructuralFocusNeverMutatesWorkspace(command: String) throws {
    var workspace = Workspace()
    _ = try workspace.split(PaneID(1), direction: .right)
    let before = workspace
    for focus in [JSONValue.string("typo"), .bool(true), .null] {
        #expect(throws: RPCFailure.self) {
            try CommandRegistry.execute(command, params: ["pane": .string("p1"), "target": .string(command == "pane.split" ? "pane" : "p2"),
                "direction": .string("left"), "focus": focus], workspace: &workspace)
        }
        #expect(workspace == before)
    }
}

@Test func savedLayoutOpeningCanPreserveExistingSelections() throws {
    var workspace = Workspace()
    let front = try workspace.newTab()
    let original = try workspace.resolvedTab(tab: front)
    let definition = SavedLayoutDefinition.blank()
    let background = try definition.opening(in: workspace, focus: false)
    #expect(background.workspace.keyTabID == front)
    #expect(try background.workspace.resolvedTab(tab: front) == original)
    #expect(try Workspace.restore(background.workspace.encoded()) == background.workspace)
    let selected = try definition.opening(in: workspace, focus: true)
    #expect(selected.workspace.keyTabID != front)
}

@Test func nativeFocusParametersAndExplicitNavigationRemainIntentional() {
    for command in ["split.right", "pane.split", "tab.new", "window.new", "pane.move"] {
        let params = CommandRegistry.nativeFocusParameters(command)
        #expect(CommandRegistry.requestsFocus(command, params: params))
        #expect(!CommandRegistry.requestsFocus(command, params: [:]))
        #expect(!CommandRegistry.requestsFocus(command, params: ["focus": .string("preserve")]))
    }
    #expect(!CommandRegistry.requestsFocus("layout.equalize", params: ["focus": .string("new")]))
    #expect(!CommandRegistry.requestsFocus("pane.type", params: ["focus": .string("target")]))
    for command in ["pane.focus", "tab.focus", "window.focus", "focus.left", "tab.next", "tab.select1"] {
        #expect(CommandRegistry.requestsFocus(command, params: [:]))
    }
}
