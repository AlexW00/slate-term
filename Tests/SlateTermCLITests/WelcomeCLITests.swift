import Testing
import SlateTermCore
@testable import SlateTermCLI

@Test func welcomeCopyContainsOnlyHeadingAndShortCommandDescriptions() {
    #expect(WelcomeContent.current.title == "Welcome to Slate Terminal!")
    #expect(WelcomeContent.current.paragraphs == [
        "Teach your coding agent how to run commands and manage panes in Slate Terminal with \(WelcomeContent.skillCommand)",
        "To stop showing this message, run \(WelcomeContent.readCommand)"
    ])
}

@Test func welcomeCLIUsesSharedOperationsWithoutWorkspaceTargets() throws {
    let show = try WelcomeCLI.parse([])
    #expect(show.request.method == "welcome.get")
    #expect(show.request.params.isEmpty)
    let read = try WelcomeCLI.parse(["--read", "--json"])
    #expect(read.request.method == "command.run")
    #expect(read.request.params == ["id": .string("welcome.read")])
    #expect(read.connection.json)
    let reset = try WelcomeCLI.parse(["--reset"])
    #expect(reset.request.params == ["id": .string("welcome.unread")])
    let unread = try WelcomeCLI.parse(["--unread"])
    #expect(unread.request.params == reset.request.params)
    #expect(throws: (any Error).self) { try WelcomeCLI.parse(["--read", "--reset"]) }
    #expect(throws: (any Error).self) { try WelcomeCLI.parse(["--read", "--unread"]) }
}

@Test func welcomeIsDiscoverableAndWorkspaceIndependentAcrossSurfaces() throws {
    let method = try #require(AutomationMethod(rawValue: "welcome.get"))
    #expect(method.family == .synchronous)
    #expect(method.admission == .read)
    let defaults = AutomationDefaults(pane: PaneID(1), tab: TabID(1), pluginID: "fixture", instanceID: "fixture", scope: "tab")
    #expect(method.resolving([:], defaults: defaults).isEmpty)
    for id in ["welcome.read", "welcome.unread", "welcome.reset"] {
        let command = try #require(CommandRegistry.commands.first { $0.id == id })
        #expect(command.title.contains("Welcome Message"))
        #expect(command.contract.workspaceIndependent)
        #expect(!command.contract.requiresArguments)
        #expect(AutomationMethod.commandRun.resolving(["id": .string(id)], defaults: defaults) == ["id": .string(id)])
    }
    #expect(WelcomeContent.current.text.contains(WelcomeContent.skillCommand))
    #expect(WelcomeContent.current.text.contains(WelcomeContent.readCommand))
}
