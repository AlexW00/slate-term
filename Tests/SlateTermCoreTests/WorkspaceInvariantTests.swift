import Foundation
import Testing
@testable import SlateTermCore

@Test func closingFocusedPaneInBackgroundTabDoesNotStealKeyWindow() throws {
    var workspace = Workspace()
    let backgroundPane = try workspace.split(PaneID(1), direction: .right)
    let keyTab = try workspace.newTab()
    try workspace.close(backgroundPane)
    #expect(workspace.keyTabID == keyTab)
    #expect(workspace.tabs[0].focusedPane == PaneID(1))
}

@Test func restoreRejectsTerminalFocusThatDisagreesWithHistory() throws {
    var workspace = Workspace()
    _ = try workspace.split(PaneID(1), direction: .right)
    var object = try #require(JSONSerialization.jsonObject(with: workspace.encoded()) as? [String: Any])
    var tabs = try #require(object["tabs"] as? [[String: Any]])
    tabs[0]["terminalHistory"] = ["p1", "p2"]
    object["tabs"] = tabs
    #expect(throws: WorkspaceError.self) {
        try Workspace.restore(JSONSerialization.data(withJSONObject: object))
    }
}

@Test func restoreRejectsDuplicateLayoutLeavesAndMissingTabGroups() throws {
    var workspace = Workspace()
    _ = try workspace.split(PaneID(1), direction: .right)
    let original = try #require(JSONSerialization.jsonObject(with: workspace.encoded()) as? [String: Any])
    var duplicate = original
    var tabs = try #require(duplicate["tabs"] as? [[String: Any]])
    tabs[0]["layout"] = ["kind": "split", "axis": "horizontal", "fraction": 0.5,
                         "first": ["kind": "pane", "pane": "p1"],
                         "second": ["kind": "split", "axis": "vertical", "fraction": 0.5,
                                    "first": ["kind": "pane", "pane": "p1"],
                                    "second": ["kind": "pane", "pane": "p2"]]]
    duplicate["tabs"] = tabs
    #expect(throws: WorkspaceError.self) {
        try Workspace.restore(JSONSerialization.data(withJSONObject: duplicate))
    }
    var missingGroup = original
    missingGroup["groups"] = []
    #expect(throws: WorkspaceError.self) {
        try Workspace.restore(JSONSerialization.data(withJSONObject: missingGroup))
    }
}

@Test(arguments: ["t1", "p0", "p-1", "p01", "p+1", "p 1", "p1 ", "p9999999999999999999999999"])
func paneIdentitiesRejectNoncanonicalInput(value: String) {
    #expect(throws: WorkspaceError.self) { try PaneID(parsing: value) }
}

@Test func nativeGroupChangesPreservePaneIdentityAndRejectMissingTabs() throws {
    var workspace = Workspace()
    let second = try workspace.newTab(in: GroupID(1))
    let layouts = workspace.tabs.map(\.layout)
    try workspace.adoptTabGroups([[TabID(1)], [second]])
    #expect(workspace.groups.map(\.tabs) == [[TabID(1)], [second]])
    #expect(workspace.groups.map(\.id) == [GroupID(1), GroupID(2)])
    try workspace.adoptTabGroups([[second, TabID(1)]])
    #expect(workspace.groups[0].tabs == [second, TabID(1)])
    #expect(workspace.tabs.map(\.layout) == layouts)
    let before = workspace
    #expect(throws: WorkspaceError.self) { try workspace.adoptTabGroups([[TabID(1)]]) }
    #expect(throws: WorkspaceError.self) { try workspace.adoptTabGroups([[TabID(1), second], [second]]) }
    #expect(workspace == before)
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
}

@Test func depthLimitRejectionDoesNotConsumeAnIdentity() throws {
    var workspace = Workspace()
    for _ in 0..<64 { try workspace.split(PaneID(1), direction: .right) }
    let before = workspace
    #expect(throws: WorkspaceError.self) { try workspace.split(PaneID(1), direction: .down) }
    #expect(workspace == before)
    #expect(try Workspace.restore(workspace.encoded()) == workspace)
}

@Test(arguments: ["nextPane", "nextTab", "nextGroup"])
func exhaustedCountersRejectAtomically(counter: String) throws {
    var object = try #require(JSONSerialization.jsonObject(with: Workspace().encoded()) as? [String: Any])
    object[counter] = Int.max
    var workspace = try Workspace.restore(JSONSerialization.data(withJSONObject: object))
    let before = workspace
    #expect(throws: WorkspaceError.self) { try workspace.newTab() }
    #expect(workspace == before)
    if counter == "nextPane" {
        #expect(throws: WorkspaceError.self) { try workspace.split(PaneID(1), direction: .down) }
    }
    if counter == "nextGroup" {
        #expect(throws: WorkspaceError.self) { try workspace.detach(TabID(1)) }
    }
    #expect(workspace == before)
}

@Test(arguments: [true, false], [true, false])
func closingBackgroundTabPreservesKeyTab(sameGroup: Bool, closeLastPane: Bool) throws {
    var workspace = Workspace()
    let key = try workspace.newTab(in: sameGroup ? GroupID(1) : nil)
    if closeLastPane { try workspace.close(PaneID(1)) }
    else { try workspace.closeTab(TabID(1)) }
    #expect(workspace.keyTabID == key)
    #expect(workspace.tabs.map(\.id) == [key])
    #expect(workspace.groups.count == 1)
}

@Test func longMutationSequenceRoundTripsAfterEveryStep() throws {
    var workspace = Workspace()
    // Deterministic choices exercise different shapes, not just a right-leaning tree.
    var seed: UInt64 = 42
    for step in 0..<200 {
        seed = seed &* 6364136223846793005 &+ 1
        let index = Int(seed % UInt64(workspace.panes.count))
        let target = workspace.panes[index].id
        if step % 3 == 2 && workspace.panes.count > 1 {
            try workspace.close(target)
        } else {
            _ = try workspace.split(target, direction: Direction.allCases[step % 4])
        }
        #expect(try Workspace.restore(workspace.encoded()) == workspace)
    }
}
