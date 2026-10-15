import Foundation
import Testing
@testable import SlateTermCore

@Test func semanticSplitAliasesProduceIdenticalFactsAndImmutableCandidate() throws {
    let before = Workspace()
    let revisions = WorkspaceRevisions(epoch: "test", workspace: before)
    let legacy = try WorkspaceTransition.command("split.left", parameters: [:], workspace: before, revisions: revisions)
    let explicit = try WorkspaceTransition.command("pane.split", parameters: ["direction": .string("left")], workspace: before, revisions: revisions)
    #expect(legacy.changes == explicit.changes)
    #expect(before.panes.count == 1 && revisions.revision == "test:w:0")
    #expect(legacy.workspace.panes.count == 2 && legacy.revisions.revision == "test:w:1")
    #expect(legacy.changes.map(\.topic) == ["host.pane.created", "host.layout.changed", "host.focus.changed", "host.workspace.changed"])
    let created = try #require(legacy.changes.first)
    #expect(created.payload["actionKind"] == .string("pane.split"))
    #expect(created.payload["anchor"] == .string("p1"))
    #expect(created.payload["targetKind"] == .string("pane"))
    #expect(created.payload["direction"] == .string("left"))
    #expect(created.payload["newPaneFraction"] == .number(0.5))
    #expect(created.payload["beforeLayoutRevision"] == .string("test:t1:0"))
    #expect(created.payload["layoutRevision"] == .string("test:t1:1"))
}

@Test func semanticClosureOrderAndDeletedRevisionsAndTitlePrivacy() throws {
    var workspace = Workspace()
    _ = try workspace.split(PaneID(1), direction: .right)
    try workspace.setManualTitle("private title", for: PaneID(1))
    let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    let title = try WorkspaceTransition.command("pane.title.clear", parameters: ["pane": .string("p1")], workspace: workspace, revisions: revisions)
    let titleFact = try #require(title.changes.first)
    #expect(titleFact.topic == "host.pane.title.changed")
    #expect(titleFact.payload["hasManualTitle"] == .bool(false))
    #expect(!String(decoding: try JSONEncoder().encode(JSONValue.object(titleFact.payload)), as: UTF8.self).contains("private title"))
    let close = try WorkspaceTransition.command("tab.close", parameters: [:], workspace: workspace, revisions: revisions)
    #expect(Array(close.changes.map(\.topic).prefix(3)) == ["host.pane.closed", "host.pane.closed", "host.tab.closed"])
    for fact in close.changes.prefix(3) {
        #expect(fact.payload["beforeLayoutRevision"] == .string("test:t1:0"))
        #expect(fact.payload["layoutRevision"] == .null)
    }
}

@Test func semanticReorderIncludesDisplacedTabsAndNoOpProducesNoFacts() throws {
    var workspace = Workspace()
    _ = try workspace.newTab(in: GroupID(1))
    _ = try workspace.newTab(in: GroupID(1))
    let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    let reorder = try WorkspaceTransition.command("tab.reorder", parameters: ["tab": .string("t3"), "index": .integer(0)], workspace: workspace, revisions: revisions)
    let facts = reorder.changes.filter { $0.topic == "host.tab.reordered" }
    #expect(facts.map(\.tab) == [TabID(1), TabID(2), TabID(3)])
    #expect(facts.map { $0.payload["beforeIndex"] } == [.integer(0), .integer(1), .integer(2)])
    #expect(facts.map { $0.payload["afterIndex"] } == [.integer(1), .integer(2), .integer(0)])
    let noOp = try WorkspaceTransition.command("tab.reorder", parameters: ["tab": .string("t3"), "index": .integer(0)], workspace: reorder.workspace, revisions: reorder.revisions)
    #expect(noOp.changes.isEmpty && !noOp.changed)
    #expect(noOp.revisions.revision == reorder.revisions.revision)
    #expect(throws: RPCFailure.self) {
        try WorkspaceTransition.command("tab.new", parameters: [:], workspace: reorder.workspace, revisions: revisions)
    }
}

@Test func semanticEqualizeEmitsOneBoundedFactPerChangedPath() throws {
    var workspace = Workspace()
    _ = try workspace.split(PaneID(1), direction: .right, newPaneFraction: 0.3)
    _ = try workspace.split(PaneID(1), direction: .down, newPaneFraction: 0.2)
    let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    let transition = try WorkspaceTransition.command("layout.equalize", parameters: [:], workspace: workspace, revisions: revisions)
    let facts = transition.changes.filter { $0.topic == "host.layout.resized" }
    #expect(facts.count == 2)
    #expect(facts.map { $0.payload["path"] } == [.array([]), .array([.string("first")])])
    #expect(facts.map { $0.payload["afterFraction"] } == [.number(2.0 / 3.0), .number(0.5)])
    #expect(facts.allSatisfy { $0.payload["layout"] == nil })
    #expect(facts.allSatisfy { $0.payload["beforeWorkspaceRevision"] == .string("test:w:0") && $0.payload["workspaceRevision"] == .string("test:w:1") })
}

@Test func semanticNativeTabObservationAndExplicitMoveAgreeOnMembershipFacts() throws {
    var workspace = Workspace()
    let second = try workspace.newTab()
    let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    let command = try WorkspaceTransition.command("tab.move", parameters: ["tab": .string(second.description), "group": .string("w1"), "index": .integer(0)], workspace: workspace, revisions: revisions)
    let native = try WorkspaceTransition(observing: command.workspace, from: workspace, revisions: revisions, action: .nativeTabs)
    let moved = try #require(command.changes.first { $0.topic == "host.tab.moved" })
    let observed = try #require(native.changes.first { $0.topic == "host.tab.moved" })
    #expect(moved.tab == observed.tab && moved.payload["beforeGroupId"] == .string("w2"))
    #expect(moved.payload["afterGroupId"] == .string("w1"))
    #expect(moved.payload.filter { $0.key != "actionKind" } == observed.payload.filter { $0.key != "actionKind" })
}

@Test func semanticRootSplitAndMoveDescribeOnlyActualEffects() throws {
    var workspace = Workspace()
    _ = try workspace.split(PaneID(1), direction: .right)
    let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    let root = try WorkspaceTransition.command("pane.split", parameters: ["pane": .string("p1"), "target": .string("root"), "direction": .string("up"),
                                               "type": .string("browser"), "newPaneFraction": .number(0.25), "focus": .string("preserve")], workspace: workspace, revisions: revisions)
    let creation = try #require(root.changes.first { $0.topic == "host.pane.created" })
    #expect(creation.payload["targetKind"] == .string("root"))
    #expect(creation.payload["type"] == .string("browser") && creation.payload["newPaneFraction"] == .number(0.25))
    #expect(creation.payload["focus"] == .string("preserve"))
    #expect(!root.changes.contains { $0.topic == "host.layout.resized" || $0.topic == "host.pane.type.changed" })
    let moved = try WorkspaceTransition.command("pane.move", parameters: ["pane": .string("p1"), "target": .string("p3"), "direction": .string("left")],
                                                workspace: root.workspace, revisions: root.revisions)
    let move = try #require(moved.changes.first { $0.topic == "host.pane.moved" })
    #expect(move.pane == PaneID(1) && move.payload["destinationPaneId"] == .string("p3"))
    #expect(move.payload["direction"] == .string("left"))
    #expect(!moved.changes.contains { $0.topic == "host.pane.created" || $0.topic == "host.pane.closed" })
}

@Test func semanticNewTabPrecedesItsPaneAndLegacyIgnoredArgumentsAreNotInventedIntent() throws {
    let workspace = Workspace()
    let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    let created = try WorkspaceTransition.command("tab.new", parameters: [:], workspace: workspace, revisions: revisions)
    #expect(Array(created.changes.map(\.topic).prefix(2)) == ["host.tab.created", "host.pane.created"])
    #expect(created.changes[0].payload["beforeLayoutRevision"] == .null)
    let legacy = try WorkspaceTransition.command("split.right", parameters: ["newPaneFraction": .number(0.9), "target": .string("root"), "focus": .string("preserve")],
                                                 workspace: workspace, revisions: revisions)
    let fact = try #require(legacy.changes.first)
    #expect(fact.payload["newPaneFraction"] == .number(0.5))
    #expect(fact.payload["targetKind"] == .string("pane") && fact.payload["focus"] == .string("new"))
}

@Test func semanticFocusAndDetachAliasesAgreeAndStaleObservationsFail() throws {
    var workspace = Workspace()
    _ = try workspace.split(PaneID(1), direction: .right)
    var revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    let arrow = try WorkspaceTransition.command("focus.left", parameters: [:], workspace: workspace, revisions: revisions)
    let explicit = try WorkspaceTransition.command("pane.focus", parameters: ["pane": .string("p1")], workspace: workspace, revisions: revisions)
    #expect(arrow.changes == explicit.changes)
    #expect(throws: RPCFailure.self) {
        try WorkspaceTransition(observing: arrow.workspace, from: arrow.workspace, revisions: revisions, action: .nativeFocus)
    }
    _ = try workspace.newTab(in: GroupID(1))
    try workspace.focusTab(TabID(1))
    revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    let next = try WorkspaceTransition.command("tab.next", parameters: [:], workspace: workspace, revisions: revisions)
    let select = try WorkspaceTransition.command("tab.select2", parameters: [:], workspace: workspace, revisions: revisions)
    let focus = try WorkspaceTransition.command("tab.focus", parameters: ["tab": .string("t2")], workspace: workspace, revisions: revisions)
    #expect(next.changes == select.changes && next.changes == focus.changes)
    let detached = try WorkspaceTransition.command("tab.detach", parameters: [:], workspace: workspace, revisions: revisions)
    let shortcut = try WorkspaceTransition.command("tab.detachCurrent", parameters: [:], workspace: workspace, revisions: revisions)
    #expect(detached.changes == shortcut.changes)
}

@Test func preparedTransitionRevalidatesModelAndLedgerBeforeAssignment() throws {
    let workspace = Workspace()
    let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    let prepared = try WorkspaceTransition.command("split.right", parameters: [:], workspace: workspace, revisions: revisions)
    try prepared.requireCurrentBase(workspace: workspace, revisions: revisions)
    #expect(throws: RPCFailure.self) { try prepared.requireCurrentBase(workspace: prepared.workspace, revisions: prepared.revisions) }
    #expect(throws: RPCFailure.self) { try prepared.requireCurrentBase(workspace: prepared.workspace, revisions: revisions) }
    let coincidentRevision = WorkspaceRevisions(epoch: "test", workspace: prepared.workspace)
    #expect(coincidentRevision.revision == revisions.revision)
    #expect(throws: RPCFailure.self) { try prepared.requireCurrentBase(workspace: prepared.workspace, revisions: coincidentRevision) }
    #expect(throws: RPCFailure.self) { try prepared.requireCurrentBase(workspace: workspace, revisions: WorkspaceRevisions(epoch: "other", workspace: workspace)) }
}

@Test func semanticUnchangedWritesAndTopologyCollapseDoNotInventResizes() throws {
    var workspace = Workspace()
    _ = try workspace.split(PaneID(1), direction: .right)
    try workspace.setManualTitle("same", for: PaneID(1))
    let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    let title = try WorkspaceTransition.command("pane.title.set", parameters: ["pane": .string("p1"), "title": .string(" same ")], workspace: workspace, revisions: revisions)
    let size = try WorkspaceTransition.command("layout.resize", parameters: ["path": .array([]), "firstChildFraction": .number(0.5)], workspace: workspace, revisions: revisions)
    #expect(title.changes.isEmpty && size.changes.isEmpty)
    let selfMove = try WorkspaceTransition.command("pane.move", parameters: ["pane": .string("p1"), "target": .string("p1"), "direction": .string("right")], workspace: workspace, revisions: revisions)
    #expect(selfMove.changes.isEmpty && !selfMove.changed)
    let closed = try WorkspaceTransition.command("pane.close", parameters: ["pane": .string("p1")], workspace: workspace, revisions: revisions)
    #expect(!closed.changes.contains { $0.topic == "host.layout.resized" })
    #expect(workspace.panes.count == 2 && revisions.revision == "test:w:0")
}
