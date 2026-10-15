import Foundation
import Testing
@testable import SlateTermCore

@Test func revisionTracksLegacyMutationsButNotNoOpsOrUnrelatedFocusAsLayout() throws {
    var workspace = Workspace()
    var revisions = WorkspaceRevisions(epoch: "app-A", workspace: workspace)
    let first = revisions.revision
    let layout = revisions.layoutRevision(TabID(1))
    #expect(revisions.observe(workspace).isEmpty)
    #expect(revisions.revision == first)
    let second = try workspace.split(PaneID(1), direction: .right)
    let changes = revisions.observe(workspace)
    #expect(changes.contains { $0.topic == "host.pane.created" })
    #expect(revisions.revision != first)
    #expect(revisions.layoutRevision(TabID(1)) != layout)
    let splitRevision = revisions.layoutRevision(TabID(1))
    try workspace.focus(PaneID(1))
    _ = revisions.observe(workspace)
    #expect(revisions.layoutRevision(TabID(1)) == splitRevision)
    try workspace.setManualTitle("named", for: second)
    #expect(revisions.observe(workspace).contains { $0.topic == "host.pane.title.changed" })
    #expect(revisions.layoutRevision(TabID(1)) == splitRevision)
    try workspace.setType(second, to: .browser)
    #expect(revisions.observe(workspace).contains { $0.topic == "host.pane.type.changed" })
    #expect(revisions.layoutRevision(TabID(1)) != splitRevision)
    #expect(throws: RPCFailure.self) { try revisions.requireLayout(layout!, tab: TabID(1)) }
    let other = WorkspaceRevisions(epoch: "app-B", workspace: workspace)
    #expect(throws: RPCFailure.self) { try other.requireWorkspace(revisions.revision) }
}

@Test func revisionsIncludeNativeGroupsAndKeepUnaffectedTabsStable() throws {
    var workspace = Workspace()
    var revisions = WorkspaceRevisions(epoch: "app", workspace: workspace)
    let firstLayout = revisions.layoutRevision(TabID(1))
    let second = try workspace.newTab(in: GroupID(1))
    _ = revisions.observe(workspace)
    #expect(revisions.layoutRevision(TabID(1)) == firstLayout)
    try workspace.adoptTabGroups([[second, TabID(1)]])
    #expect(revisions.observe(workspace).contains { $0.topic == "host.tabs.changed" })
    #expect(revisions.layoutRevision(TabID(1)) == firstLayout)
    try workspace.closeTab(second)
    #expect(revisions.observe(workspace).contains { $0.topic == "host.tab.closed" })
    #expect(revisions.layoutRevision(second) == nil)
}

@Test func backgroundPaneRoutesTabCommandsToItsLiveOwnerNotKeyTab() throws {
    var workspace = Workspace()
    let background = workspace.tabs[0].id
    let foreground = try workspace.newTab()
    #expect(workspace.keyTabID == foreground)
    #expect(try workspace.resolvedTab(pane: PaneID(1)).id == background)
    #expect(throws: (any Error).self) { try workspace.resolvedTab(pane: PaneID(1), tab: foreground) }
    #expect(throws: (any Error).self) { try workspace.resolvedTab(pane: PaneID(999)) }
    _ = try CommandRegistry.execute("tab.close", params: ["pane": .string("p1")], workspace: &workspace)
    #expect(workspace.tabs.map(\.id) == [foreground])
    #expect(workspace.keyTabID == foreground)
}

@Test func zoomVisibilityInvalidatesLayoutButOrdinaryFocusDoesNot() throws {
    var workspace = Workspace()
    let other = try workspace.split(PaneID(1), direction: .right)
    var revisions = WorkspaceRevisions(epoch: "app", workspace: workspace)
    let before = revisions.layoutRevision(TabID(1))
    try workspace.focus(PaneID(1))
    _ = revisions.observe(workspace)
    #expect(revisions.layoutRevision(TabID(1)) == before)
    try workspace.toggleZoom(PaneID(1))
    _ = revisions.observe(workspace)
    let zoomed = revisions.layoutRevision(TabID(1))
    #expect(zoomed != before)
    try workspace.focus(other)
    _ = revisions.observe(workspace)
    let refocused = revisions.layoutRevision(TabID(1))
    #expect(refocused != zoomed)
    try workspace.toggleZoom(other)
    _ = revisions.observe(workspace)
    #expect(revisions.layoutRevision(TabID(1)) != refocused)
}

@Test func contextualAndCrossEpochRoutingDoNotReuseLaunchingSession() throws {
    let context = try APITarget.resolve(scope: "tab", environment: inherited)
    #expect(context["contextPane"] == .string("p1"))
    #expect(context["pane"] == nil && context["tab"] == nil && context["expectedAnchorSessionId"] == nil)
    let service = try APITarget.resolve(scope: "tab", environment: ["SLATE_TERM_TAB_ID": "t2"])
    #expect(service["tab"] == .string("t2"))
    #expect(throws: RPCFailure.self) { try APITarget.resolve(instance: "new-app", environment: inherited) }
    let overridden = try APITarget.resolve(pane: "p1", instance: "new-app", environment: inherited)
    #expect(overridden["expectedInstanceId"] == .string("new-app"))
    #expect(overridden["expectedAnchorSessionId"] == nil)
}

private let inherited: [String: String] = ["SLATE_TERM_SOCKET": "/tmp/a", "SLATE_TERM_INSTANCE_ID": "app",
    "SLATE_TERM_PANE_ID": "p1", "SLATE_TERM_TAB_ID": "t1", "SLATE_TERM_SESSION_ID": "s1"]

@Test func routingNeverCarriesSessionToSiblingAndDistinguishesHints() throws {
    let own = try APITarget.resolve(environment: inherited)
    #expect(own["pane"] == .string("p1"))
    #expect(own["tab"] == nil) // The host resolves current membership, never the stale launch tab.
    #expect(own["expectedAnchorSessionId"] == .string("s1"))
    #expect(own["expectedInstanceId"] == .string("app"))
    let sibling = try APITarget.resolve(pane: "p2", environment: inherited)
    #expect(sibling["expectedAnchorSessionId"] == nil)
    #expect(sibling["sessionId"] == nil)
    let explicitTab = try APITarget.resolve(tab: "t2", environment: inherited)
    #expect(explicitTab["pane"] == nil)
    #expect(explicitTab["expectedAnchorSessionId"] == nil)
    let active = try APITarget.resolve(active: true, environment: inherited)
    #expect(active["pane"] == nil)
    #expect(active["tab"] == nil)
    #expect(active["expectedAnchorSessionId"] == nil)
    #expect(active["expectedInstanceId"] == .string("app"))
    #expect(throws: RPCFailure.self) { try APITarget.resolve(pane: "p2", active: true, environment: inherited) }
}

@Test func routingRejectsCrossAppInheritedTargetsAndPoisonedIdentity() throws {
    #expect(throws: RPCFailure.self) { try APITarget.resolve(socket: "/tmp/b", environment: inherited) }
    let other = try APITarget.resolve(pane: "p2", socket: "/tmp/b", environment: inherited)
    #expect(other["pane"] == .string("p2"))
    #expect(other["expectedInstanceId"] == nil)
    #expect(other["expectedAnchorSessionId"] == nil)
    var bad = inherited
    bad["SLATE_TERM_PANE_ID"] = "garbage"
    #expect(throws: (any Error).self) { try APITarget.resolve(environment: bad) }
    let service = try APITarget.resolve(environment: ["SLATE_TERM_TAB_ID": "t2"])
    #expect(service["tab"] == .string("t2"))
    #expect(service["pane"] == nil)
}

@Test func guardNegotiationPreservesOnlyTheKnownLegacyV1Contract() throws {
    let legacy: JSONValue = .object(["apiVersion": .integer(1), "identityGuards": .bool(true), "workspaceRevisions": .bool(true),
                                     "surface": .string("administrative"), "methods": .array([.string("config.patch")])])
    #expect(try APIGuards.supported(by: legacy) == APIGuards.legacyNames)
    #expect(try APIGuards.supported(by: legacy).contains("expectedWriteRevision") == false)
    #expect(try APIGuards.supported(by: legacy).isDisjoint(with: ["expectedViewId", "expectedDocumentId"]))
    #expect(throws: RPCFailure.self) { try APIGuards.supported(by: .object(["identityGuards": .bool(true)])) }
    var modern = legacy.object!
    modern["guards"] = .array([.string("expectedInstanceId")])
    #expect(try APIGuards.supported(by: .object(modern)) == ["expectedInstanceId"])
    modern["guards"] = .null
    #expect(throws: RPCFailure.self) { try APIGuards.supported(by: .object(modern)) }
}

@Test func commandExposureKeepsContributionsSeparateFromAdministration() throws {
    #expect(CommandContract.forCommand("appearance.dark").pluginAccessible == false)
    #expect(CommandContract.forCommand("appearance.set").requiresArguments)
    #expect(CommandContract.forCommand("appearance.dark").workspaceIndependent)
    #expect(CommandContract.forCommand("plugin.service.start").pluginAccessible)
    #expect(!CommandContract.forCommand("plugins.service.start").pluginAccessible)
    #expect(CommandContract.forCommand("config.reload").pluginAccessible, "Preserve the explicitly documented legacy reload exception")
}

@Test func rpcFailureDataIsAdditiveAndPreservesLegacyDecoding() throws {
    let old = try JSONDecoder().decode(RPCFailure.self, from: Data(#"{"code":-32602,"message":"invalid"}"#.utf8))
    #expect(old.data == nil)
    let failure = RPCFailure(code: APIError.settingsWriteFailed, message: "failed", data: .object(["persisted": .bool(false), "outcome": .string("unknown")]))
    let restored = try JSONDecoder().decode(RPCFailure.self, from: JSONEncoder().encode(failure))
    #expect(restored.data == failure.data)
    #expect(restored.code == failure.code)
}

@Test func paginationCannotCrossRevisionsQueriesOrEpochs() throws {
    let cursor = InspectionCursor(revision: "a:w:1", scope: "global", offset: 2, eventCursor: "a:10")
    let encoded = try cursor.encoded()
    #expect(try InspectionCursor.decode(encoded, revision: "a:w:1", scope: "global") == cursor)
    #expect(throws: RPCFailure.self) { try InspectionCursor.decode(encoded, revision: "a:w:2", scope: "global") }
    #expect(throws: RPCFailure.self) { try InspectionCursor.decode(encoded, revision: "b:w:1", scope: "global") }
    #expect(throws: RPCFailure.self) { try InspectionCursor.decode(encoded, revision: "a:w:1", scope: "tab:t1") }
    #expect(throws: RPCFailure.self) { try InspectionCursor.decode("garbage", revision: "a:w:1", scope: "global") }
}
