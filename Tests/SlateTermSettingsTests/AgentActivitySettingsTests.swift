import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func agentActivityDefaultsOnAndRoundtripsThroughPatch() throws {
    #expect(AppConfiguration.defaults.showAgentActivity)
    #expect(try AppConfiguration.parse("").showAgentActivity)
    let source = "# keep\n[terminal]\nfont_size = 14\n"
    let changed = try ConfigurationPatch.updating(source: source, values: ["agents.show_activity": .bool(false)])
    let parsed = try AppConfiguration.parse(changed)
    #expect(!parsed.showAgentActivity)
    #expect(changed.contains("# keep") && changed.contains("show_activity"))
    #expect(parsed.changedKeys(from: try AppConfiguration.parse(source)) == ["agents.show_activity"])
    #expect(parsed.restartRequired(from: try AppConfiguration.parse(source)).isEmpty)
    let restored = try ConfigurationPatch.updating(source: changed, values: ["agents.show_activity": .bool(true)])
    #expect(try AppConfiguration.parse(restored).showAgentActivity)
}

@Test func agentActivityRejectsInvalidValuesAndUnknownKeys() throws {
    for invalid in ["show_activity = 1", "show_activity = 'yes'", "surprise = true"] {
        #expect(throws: (any Error).self) { try AppConfiguration.parse("[agents]\n" + invalid) }
    }
    #expect(throws: (any Error).self) { try ConfigurationPatch.updating(source: "", values: ["agents.show_activity": .string("off")]) }
}

@Test func agentActivityCommandsAreGlobalAndArgumentFree() {
    for id in ["agents.activity.show", "agents.activity.hide", "agents.activity.toggle"] {
        #expect(CommandRegistry.commands.contains { $0.id == id })
        let contract = CommandContract.forCommand(id)
        #expect(contract.workspaceIndependent && !contract.requiresArguments)
    }
}
