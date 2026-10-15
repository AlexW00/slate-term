import Foundation
import Testing
@testable import SlateTermCore

@Test func savedLayoutCatalogSeparatesLibraryActionsFromPaneDefaults() {
    let defaults = AutomationDefaults(pane: PaneID(2), tab: TabID(2), pluginID: "notes", instanceID: "instance", scope: "tab")
    let reads: [AutomationMethod] = [.layoutsList, .layoutsGet, .layoutsFields, .layoutsValidate, .layoutsWindows, .layoutsStartupStatus]
    let writes: [AutomationMethod] = [.layoutsCreate, .layoutsUpdate, .layoutsCapture, .layoutsOpen]
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
        #expect(command.contract.workspaceIndependent)
        #expect(AutomationMethod.commandRun.resolving(["id": .string(command.id)], defaults: defaults) == ["id": .string(command.id)])
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
    let opening = try definition.opening(in: before, replacing: GroupID(1))
    let transition = try WorkspaceTransition(observing: opening.workspace, from: before, revisions: revisions, action: .savedLayoutOpen)
    #expect(transition.changed)
    #expect(transition.beforeWorkspaceRevision == revisions.revision)
    #expect(transition.revisions.revision != revisions.revision)
    #expect(transition.workspace.tabs.contains { $0.id == untouched })
    #expect(transition.changes.contains { $0.topic == "host.pane.closed" && $0.pane == PaneID(1) })
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
