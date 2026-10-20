import Foundation
import Testing
@testable import SlateTermCore

@Test func savedLayoutCatalogSeparatesLibraryActionsFromPaneDefaults() {
    let defaults = AutomationDefaults(pane: PaneID(2), tab: TabID(2), pluginID: "notes", instanceID: "instance", scope: "tab")
    let reads: [AutomationMethod] = [.layoutsList, .layoutsGet, .layoutsFields, .layoutsValidate, .layoutsWindows, .layoutsStartupStatus]
    let writes: [AutomationMethod] = [.layoutsCreate, .layoutsUpdate, .layoutsCapture, .layoutsOpen, .layoutsLauncher]
    for method in reads + writes {
        #expect(method.isPublic)
        #expect(method.family == .synchronous)
        #expect(method.admission == (reads.contains(method) ? .read : .mutation))
        #expect(method.resolving([:], defaults: defaults).isEmpty)
    }
    #expect(AutomationMethod.layoutConfiguration.admission == .read)
    #expect(AutomationMethod.layoutConfiguration.resolving([:], defaults: defaults)["pane"] == .string("p2"))
    #expect(AutomationMethod.layoutConfiguration.resolving(["pane": .string("p9")], defaults: defaults) == ["pane": .string("p9")])
    #expect(AutomationMethod.layoutConfiguration.resolving([:], defaults: .init()).isEmpty)
    for command in CommandRegistry.commands where command.id.hasPrefix("layouts.") {
        let capture = command.id == "layouts.captureWindow"
        #expect(command.contract.workspaceIndependent == !capture)
        var expected: [String: JSONValue] = ["id": .string(command.id)]
        if capture { expected["pane"] = .string("p2"); expected["tab"] = .string("t2") }
        #expect(AutomationMethod.commandRun.resolving(["id": .string(command.id)], defaults: defaults) == expected)
    }
    #expect(APIGuards.names.contains("expectedSavedLayoutRevision"))
    #expect(!APIGuards.legacyNames.contains("expectedSavedLayoutRevision"))
}

@Test func savedLayoutOpeningPreparesAttributedFactsWithoutCopyingConfiguration() throws {
    var before = Workspace()
    let untouched = try before.newTab()
    let revisions = WorkspaceRevisions(epoch: "fixture", workspace: before)
    var definition = SavedLayoutDefinition.blank()
    definition.tabs[0].panes[0].configuration = ["command": .string("private command"), "directory": .string("/private/path")]
    let opening = try definition.opening(in: before)
    let transition = try WorkspaceTransition(observing: opening.workspace, from: before, revisions: revisions, action: .savedLayoutOpen)
    #expect(transition.changed)
    #expect(transition.beforeWorkspaceRevision == revisions.revision)
    #expect(transition.revisions.revision != revisions.revision)
    #expect(transition.workspace.tabs.contains { $0.id == untouched })
    #expect(!transition.changes.contains { $0.topic == "host.pane.closed" })
    #expect(before.groups.allSatisfy { opening.workspace.groups.contains($0) })
    #expect(transition.changes.contains { $0.topic == "host.pane.created" })
    for fact in transition.changes {
        #expect(fact.payload["actionKind"] == .string("layouts.open"))
        #expect(fact.payload["workspaceRevision"] == .string(transition.revisions.revision))
        let encoded = String(decoding: try JSONEncoder().encode(fact.payload), as: UTF8.self)
        #expect(!encoded.contains("private"))
    }
    try transition.requireCurrentBase(workspace: before, revisions: revisions)
    try before.setManualTitle("Changed during preparation", for: PaneID(1))
    #expect(throws: RPCFailure.self) { try transition.requireCurrentBase(workspace: before, revisions: revisions) }
}

@Test func restoringOriginalLayoutReplacesAllGroupsWithoutReusingIdentities() throws {
    var before = Workspace()
    _ = try before.split(PaneID(1), direction: .right)
    _ = try before.newTab()
    try before.setDefaultTabTitle("Project App")
    let revisions = WorkspaceRevisions(epoch: "restore", workspace: before)
    var definition = SavedLayoutDefinition.blank()
    definition.tabs.append(SavedLayoutTab(name: "Browser", layout: .pane(PaneID(2)), panes: [SavedLayoutPane(id: PaneID(2), type: "browser")]))
    let restored = try definition.restoring(in: before)
    #expect(restored.workspace.groups.count == 1)
    #expect(restored.workspace.tabs.count == definition.tabs.count)
    #expect(restored.workspace.defaultTabTitle == "Project App")
    #expect(Set(restored.workspace.panes.map(\.id)).isDisjoint(with: before.panes.map(\.id)))
    #expect(Set(restored.workspace.tabs.map(\.id)).isDisjoint(with: before.tabs.map(\.id)))
    var roundTrip = try Workspace.restore(restored.workspace.encoded())
    try roundTrip.setDefaultTabTitle("Project App")
    #expect(roundTrip == restored.workspace)
    let transition = try WorkspaceTransition(observing: restored.workspace, from: before, revisions: revisions, action: .savedLayoutRestoreOriginal)
    #expect(transition.changes.filter { $0.topic == "host.pane.closed" }.count == before.panes.count)
    #expect(transition.changes.filter { $0.topic == "host.pane.created" }.count == restored.workspace.panes.count)
    #expect(transition.changes.allSatisfy { $0.payload["actionKind"] == .string("layouts.restoreOriginal") })
    try transition.requireCurrentBase(workspace: before, revisions: revisions)
    try before.setManualTitle("Changed", for: PaneID(1))
    #expect(throws: RPCFailure.self) { try transition.requireCurrentBase(workspace: before, revisions: revisions) }
    var invalid = definition
    invalid.tabs[0].layout = .pane(PaneID(999))
    #expect(throws: RPCFailure.self) { try invalid.restoring(in: before) }
}
