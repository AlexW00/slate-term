import Testing
import SlateTermCore
@testable import SlateTermCLI

@Test func tabTitleAliasesUseSharedCommands() throws {
    #expect(Tabs.Action.setTitle.commandID == "tab.title.set")
    #expect(Tabs.Action.clearTitle.commandID == "tab.title.clear")
    for action in [Tabs.Action.setTitle, .clearTitle] {
        #expect(CommandRegistry.commands.contains { $0.id == action.commandID })
    }
    let set = try Tabs.parse(["set-title", "--tab", "t2", "--title", "Build"])
    #expect(set.title == "Build" && set.target.tab == "t2")
    #expect(CommandContract.forCommand("tab.title.set").requiresArguments)
    #expect(!CommandContract.forCommand("tab.title.clear").requiresArguments)
    #expect(!CommandContract.forCommand("tab.rename").requiresArguments)
}

@Test func tabTitleCLIRejectsUnrelatedArgumentsBeforeConnecting() throws {
    for arguments in [["set-title"], ["clear-title", "--title", "bad"], ["list", "--title", "bad"], ["set-title", "--title", "Build", "--index", "0"], ["clear-title", "--group", "w1"], ["set-title", "--title", "Build", "--focus-policy", "target"]] {
        let command = try Tabs.parse(arguments + ["--active"])
        #expect(throws: (any Error).self) { try command.run() }
    }
}
