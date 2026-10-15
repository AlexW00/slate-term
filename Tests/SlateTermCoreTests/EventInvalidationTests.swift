import Foundation
import Testing
@testable import SlateTermCore

@Test func tabLocalWorkspaceInvalidationsDoNotWakeUnrelatedTabs() throws {
    var workspace = Workspace()
    _ = try workspace.newTab()
    let transition = try WorkspaceTransition.command("pane.title.set", parameters: ["pane": .string("p1"), "title": .string("build")],
                                                     workspace: workspace, revisions: WorkspaceRevisions(epoch: "test", workspace: workspace))
    let invalidation = try #require(transition.changes.first { $0.topic == "host.workspace.changed" })
    #expect(invalidation.tab == TabID(1))
    var journal = try EventJournal()
    let cursor = journal.cursor
    _ = try journal.appendBatch(transition.changes.map { EventPublication(topic: $0.topic, payload: .object($0.payload), tab: $0.tab, pane: $0.pane) })
    #expect(try journal.batch(after: cursor, filter: EventFilter(topics: ["host.workspace.*"], tab: TabID(2))).events.isEmpty)
    #expect(try journal.batch(after: cursor, filter: EventFilter(topics: ["host.workspace.*"], tab: TabID(1))).events.count == 1)
    #expect(try journal.batch(after: cursor).events.count == transition.changes.count)
}

@Test func workspaceWideChangesStillInvalidateGlobalAndTabReaders() throws {
    var workspace = Workspace()
    _ = try workspace.newTab()
    let revisions = WorkspaceRevisions(epoch: "test", workspace: workspace)
    for transition in [
        try WorkspaceTransition.command("tab.focus", parameters: ["tab": .string("t1")], workspace: workspace, revisions: revisions),
        try WorkspaceTransition.command("tab.move", parameters: ["tab": .string("t2"), "group": .string("w1"), "index": .integer(0)], workspace: workspace, revisions: revisions)
    ] {
        let invalidation = try #require(transition.changes.first { $0.topic == "host.workspace.changed" })
        #expect(invalidation.tab == nil)
    }
}
