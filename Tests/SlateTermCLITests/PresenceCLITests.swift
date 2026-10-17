import Testing
import SlateTermCore
@testable import SlateTermCLI

private let originEnvironment = [
    "SLATE_TERM_ACTOR": "claude", "SLATE_TERM_SOCKET": "/tmp/slate.sock",
    "SLATE_TERM_PANE_ID": "p1", "SLATE_TERM_INSTANCE_ID": "app-1", "SLATE_TERM_SESSION_ID": "session-1"
]

@Test func presenceOriginIsIndependentOfTheActionTarget() throws {
    let command = try TerminalCommand.parse(["capture", "--pane", "p2"])
    let declared = try command.connection.presenceActor(environment: originEnvironment, service: nil)
    let actor = try #require(declared)
    #expect(actor.home == "p1")
    #expect(actor.origin == (try PresenceOrigin(instanceID: "app-1", sessionID: "session-1")))
}

@Test func externalOrIncompleteOriginsStillAllowAgentLabels() throws {
    let connection = try Connection.parse(["--actor", "codex"])
    for removed in ["SLATE_TERM_SESSION_ID", "SLATE_TERM_INSTANCE_ID", "SLATE_TERM_PANE_ID"] {
        var env = originEnvironment
        env.removeValue(forKey: removed)
        let declared = try connection.presenceActor(environment: env, service: nil)
        let actor = try #require(declared)
        #expect(actor.name == "codex" && actor.origin == nil)
    }
    #expect(try connection.presenceActor(environment: [:], service: nil)?.home == nil)
}

@Test func foreignSocketOrAppNeverInheritsAnOrigin() throws {
    for arguments in [["--socket", "/tmp/other.sock"], ["--expected-instance-id", "app-2"]] {
        let connection = try Connection.parse(arguments)
        let declared = try connection.presenceActor(environment: originEnvironment, service: nil)
        let actor = try #require(declared)
        #expect(actor.home == nil && actor.origin == nil)
    }
}

@Test func presenceFocusCLIAndCatalogHaveNoInheritedTarget() throws {
    let focus = try PresenceCLI.parse(["focus", "--activity-id", "a7"])
    let request = try focus.request
    #expect(request.method == "presence.focus")
    #expect(request.params == ["activityId": .string("a7")])
    #expect(throws: (any Error).self) { try PresenceCLI.parse(["focus"]).request }
    #expect(throws: (any Error).self) { try PresenceCLI.parse(["focus", "--activity-id", "a7", "--pane", "p1"]).request }
    let method = try #require(AutomationMethod(rawValue: "presence.focus"))
    #expect(method.isPublic && method.admission == .mutation)
    #expect(method.resolving(["activityId": .string("a7")], defaults: .init(pane: PaneID(2), tab: TabID(1))) == ["activityId": .string("a7")])
}
