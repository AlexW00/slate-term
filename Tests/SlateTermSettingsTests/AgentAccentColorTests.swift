import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func agentAccentColorsRoundTripAndResetWithoutLosingOtherSettings() throws {
    let source = "# keep\n[agents]\nshow_activity = false # display\n[agents.colors]\nclaude = '#abcdef' # warm\n'my.agent' = '#123456'\n[terminal]\nfont_size = 17 # points\n"
    let colors: [String: JSONValue] = ["codex": .string("#102030"), "my.agent": .string("#ABCDEF")]
    let changed = try ConfigurationPatch.updating(source: source, values: ["agents.colors": .object(colors)])
    let config = try AppConfiguration.parse(changed)
    #expect(config.agentColors == ["codex": "#102030", "my.agent": "#ABCDEF"])
    #expect(!config.showAgentActivity && config.terminal.fontSize == 17)
    #expect(changed.contains("# keep") && changed.contains("# display") && changed.contains("# warm") && changed.contains("# points"))
    #expect(config.changedKeys(from: try AppConfiguration.parse(source)) == ["agents.colors"])
    #expect(config.restartRequired(from: try AppConfiguration.parse(source)).isEmpty)
    #expect(try JSONValue.encoding(config).object?["agents"]?.object?["colors"] == .object(colors))
    // Other writers must accept the format emitted by a color write.
    let followup = try ConfigurationPatch.updating(source: changed, values: ["terminal.font_size": .integer(19)])
    #expect(try AppConfiguration.parse(followup).agentColors == config.agentColors)
    let reset = try ConfigurationPatch.updating(source: followup, values: ["agents.colors": .object([:])])
    #expect(try AppConfiguration.parse(reset).agentColors.isEmpty)
    let native = try AppConfiguration.updating(source: reset, values: ["agents.colors": AgentAccentColors.literal(config.agentColors)])
    #expect(try AppConfiguration.parse(native).agentColors == config.agentColors)
}

@Test func agentAccentColorsRejectInvalidNamesColorsAndBounds() throws {
    #expect(try AppConfiguration.parse("").agentColors.isEmpty)
    for (name, color) in [("", "#123456"), ("bad name", "#123456"), ("Claude", "#123456"),
                          ("codex:reviewer", "#123456"), ("x", "red"), ("x", "#123"),
                          ("x", "#12345678"), ("x", "#12345g"), (String(repeating: "a", count: 33), "#123456")] {
        #expect(throws: (any Error).self) {
            try ConfigurationPatch.updating(source: "", values: ["agents.colors": .object([name: .string(color)])])
        }
    }
    for value: JSONValue in [.null, .string("#123456"), .array([]), .object(["codex": .integer(12)])] {
        #expect(throws: (any Error).self) { try ConfigurationPatch.updating(source: "", values: ["agents.colors": value]) }
    }
    for literal in ["'#123456'", "12", "true", "[]", "{codex = 12}", "{codex = '#123'}"] {
        #expect(throws: (any Error).self) { try AppConfiguration.parse("[agents]\ncolors = " + literal) }
        #expect(throws: (any Error).self) { try AppConfiguration.updating(source: "", values: ["agents.colors": literal]) }
    }
    let tooMany = Dictionary(uniqueKeysWithValues: (0..<65).map { ("agent\($0)", JSONValue.string("#123456")) })
    #expect(throws: (any Error).self) { try ConfigurationPatch.updating(source: "", values: ["agents.colors": .object(tooMany)]) }
}

@Test func agentAccentColorsMatchActorFamiliesAndPreserveFallback() {
    let overrides: [String: UInt32] = ["codex": 0x123456, "my.agent": 0xABCDEF]
    #expect(PresenceColor.rgb(for: "Codex:reviewer", overrides: overrides) == 0x123456)
    #expect(PresenceColor.rgb(for: "my.agent:worker", overrides: overrides) == 0xABCDEF)
    #expect(PresenceColor.rgb(for: "claude", overrides: overrides) == PresenceColor.known["claude"])
    #expect(PresenceColor.rgb(for: "other", overrides: overrides) == PresenceColor.rgb(for: "other"))
}
