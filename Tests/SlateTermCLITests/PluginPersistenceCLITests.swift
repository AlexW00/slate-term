import Testing
import SlateTermCore
@testable import SlateTermCLI

@Test func pluginPersistenceCLIHasExplicitNamespacesAndStateGuards() throws {
    let data = try Plugins.parse(["data", "patch", "notes", "--expected-data-revision", "revision", "--operations", "[{\"op\":\"set\",\"key\":\"one\",\"value\":null}]"])
    #expect(data.action == .data && data.namespace == "notes")
    let panel = try Plugins.parse(["panel-state", "reset", "--pane", "p2", "--expected-panel-id", "panel", "--expected-state-revision", "state"])
    #expect(panel.pane == "p2" && panel.expectedPanelId == "panel")
    let contract = CommandContract.forCommand("plugins.panelState.reset")
    #expect(!contract.workspaceIndependent && contract.requiresArguments)
    #expect(Set(contract.required) == ["expectedPanelId", "expectedStateRevision"])
}

@Test func pluginPersistenceCLIRejectsAmbiguousOptionsBeforeConnection() throws {
    for args in [
        ["data", "get", "notes", "--pane", "p1"],
        ["data", "reset", "notes", "--expected-data-revision", "r"],
        ["data", "get", "notes", "--force"],
        ["panel-state", "get", "notes", "--pane", "p1"],
        ["panel-state", "reset", "--pane", "p1"],
        ["panel-state", "get", "--pane", "p1", "--expected-panel-id", "bad"],
        ["settings", "get", "notes", "--expected-data-revision", "bad"],
        ["data", "patch", "notes", "--expected-data-revision", "r", "--operations", "[{\"op\":\"delete\",\"key\":\"x\",\"value\":null}]"]
    ] {
        let command = try Plugins.parse(args)
        #expect(throws: (any Error).self) { try command.run() }
    }
}
