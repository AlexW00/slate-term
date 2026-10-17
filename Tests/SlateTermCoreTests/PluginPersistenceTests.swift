import Foundation
import Testing
@testable import SlateTermCore

private func set(_ key: String, _ value: JSONValue) -> JSONValue {
    .array([.object(["op": .string("set"), "key": .string(key), "value": value])])
}

@Test func pluginPatchesAreGuardedBoundedAndDistinguishNullFromDeletion() throws {
    let empty = PluginDataDocument()
    let written = try empty.changing(operations: set("note", .null), expectedRevision: empty.revision)
    #expect(written.values["note"] == .null)
    #expect(written.revision != empty.revision)
    #expect(try written.changing(operations: set("note", .null), expectedRevision: written.revision) == written)
    #expect(throws: RPCFailure.self) { try written.changing(operations: set("note", .string("stale")), expectedRevision: empty.revision) }
    let deleted = try written.changing(operations: .array([.object(["op": .string("delete"), "key": .string("note")])]), expectedRevision: written.revision)
    #expect(deleted.values.isEmpty)
    #expect(throws: RPCFailure.self) { try empty.changing(operations: .array([
        .object(["op": .string("set"), "key": .string("same"), "value": .integer(1)]),
        .object(["op": .string("delete"), "key": .string("same")])]), expectedRevision: empty.revision) }
    #expect(throws: RPCFailure.self) { try empty.changing(operations: set("large", .string(String(repeating: "x", count: 16_385))), expectedRevision: empty.revision) }
    #expect(throws: RPCFailure.self) { try empty.changing(operations: .array([.object(["op": .string("delete"), "key": .string("x"), "value": .null])]), expectedRevision: empty.revision) }
}

@Test func resetOfEmptyDataIsAGenerationBarrier() throws {
    let before = PluginDataDocument()
    let after = try before.changing(operations: nil, expectedRevision: before.revision)
    #expect(after.values.isEmpty)
    #expect(after.revision != before.revision)
    #expect(throws: RPCFailure.self) { try after.changing(operations: set("pending", .bool(true)), expectedRevision: before.revision) }
}

@Test func panelLifetimeIsIndependentOfRuntimeAndPaneSlot() throws {
    var workspace = Workspace()
    try workspace.setType(PaneID(1), to: .registered("notes"))
    let panel = try #require(workspace.panes[0].pluginPanel)
    try workspace.setPluginConfiguration(["project": .string("alpha")], for: PaneID(1))
    try workspace.patchPluginState(PaneID(1), expectedPanelId: panel.panelId, expectedRevision: panel.stateRevision, operations: set("selection", .string("one")))
    let saved = try #require(workspace.panes[0].pluginPanel)
    let otherTab = try workspace.newTab()
    let target = try workspace.resolvedTab(tab: otherTab).focusedPane
    try workspace.move(PaneID(1), beside: target, direction: .left)
    #expect(workspace.panes.first { $0.id == PaneID(1) }?.pluginPanel == saved)
    let restored = try Workspace.restore(workspace.encoded())
    #expect(restored == workspace)
    #expect(restored.panes.first { $0.id == PaneID(1) }?.pluginPanel?.configuration["project"] == .string("alpha"))
    try workspace.setType(PaneID(1), to: .registered("notes"))
    #expect(workspace.panes.first { $0.id == PaneID(1) }?.pluginPanel == saved)
    try workspace.setType(PaneID(1), to: .browser)
    try workspace.setType(PaneID(1), to: .registered("notes"))
    let replacement = try #require(workspace.panes.first { $0.id == PaneID(1) }?.pluginPanel)
    #expect(replacement.panelId != saved.panelId && replacement.state.isEmpty)
    #expect(throws: RPCFailure.self) { try workspace.patchPluginState(PaneID(1), expectedPanelId: saved.panelId, expectedRevision: saved.stateRevision, operations: set("stale", .bool(true))) }
}

@Test func panelResetAndStateChangesAreNotLayoutChanges() throws {
    var workspace = Workspace()
    try workspace.setType(PaneID(1), to: .registered("notes"))
    let original = workspace
    let panel = try #require(workspace.panes[0].pluginPanel)
    let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    try workspace.patchPluginState(PaneID(1), expectedPanelId: panel.panelId, expectedRevision: panel.stateRevision, operations: nil)
    let transition = try WorkspaceTransition(observing: workspace, from: original, revisions: revisions, action: .pluginPanelReset)
    #expect(transition.changed)
    #expect(transition.revisions.layoutRevision(TabID(1)) == revisions.layoutRevision(TabID(1)))
    #expect(transition.changes.map(\.topic) == ["host.plugin.panel-state.changed", "host.workspace.changed"])
    #expect(workspace.panes[0].pluginPanel?.panelId == panel.panelId)
    var journal = try EventJournal()
    try journal.appendBatch(transition.changes.map { EventPublication(topic: $0.topic, payload: .object($0.payload), source: .host, tab: $0.tab, pane: $0.pane) })
    let json = try workspace.publicJSON()
    #expect(json.object?["panes"] != nil)
    #expect(!String(data: try JSONEncoder().encode(json), encoding: .utf8)!.contains("stateRevision"))
    #expect(throws: RPCFailure.self) { try workspace.patchPluginState(PaneID(1), expectedPanelId: panel.panelId, expectedRevision: panel.stateRevision, operations: set("queued", .bool(true))) }
}

@Test func pluginSnapshotRejectsOldSchemaAndDuplicatePanelIdentity() throws {
    var workspace = Workspace()
    try workspace.setType(PaneID(1), to: .registered("notes"))
    _ = try workspace.split(PaneID(1), direction: .right, type: .registered("notes"))
    var object = try #require(JSONSerialization.jsonObject(with: workspace.encoded()) as? [String: Any])
    var panes = try #require(object["panes"] as? [[String: Any]])
    panes[1]["pluginPanel"] = panes[0]["pluginPanel"]
    object["panes"] = panes
    #expect(throws: (any Error).self) { try Workspace.restore(JSONSerialization.data(withJSONObject: object)) }
    object = try #require(JSONSerialization.jsonObject(with: Workspace().encoded()) as? [String: Any])
    object["schemaVersion"] = 1
    #expect(throws: (any Error).self) { try Workspace.restore(JSONSerialization.data(withJSONObject: object)) }
}
