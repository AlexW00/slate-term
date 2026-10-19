import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func typedConfigPatchPreservesCommentsAndRejectsCrossNamespaceOrInvalidValues() throws {
    let source = "# keep\n[appearance]\ntheme = 'auto' # follow OS\n[plugins.\"acme.tools\".custom]\ncount = 7\n"
    let changed = try ConfigurationPatch.updating(source: source, values: ["appearance.theme": .string("dark"), "terminal.font_size": .integer(15)])
    #expect(changed.contains("# keep"))
    #expect(changed.contains("# follow OS"))
    #expect(changed.contains("[plugins.\"acme.tools\".custom]\ncount = 7"))
    #expect(try AppConfiguration.parse(changed).theme == .dark)
    #expect(try AppConfiguration.parse(changed).terminal.fontSize == 15)
    for values: [String: JSONValue] in [
        ["appearance.theme": .bool(true)], ["terminal.font_size": .integer(0)],
        ["appearance.theme": .null], ["plugins.acme.tools": .object([:])],
        ["terminal.unknown": .string("x")], ["terminal.font_size": .number(.infinity)]
    ] {
        #expect(throws: (any Error).self) { try ConfigurationPatch.updating(source: source, values: values) }
    }
    #expect(throws: (any Error).self) { try ConfigurationPatch.updating(source: "not valid TOML", values: ["appearance.theme": .string("light")]) }
    #expect(try ConfigurationPatch.updating(source: source, values: [:]) == source)
}

@Test func configPatchCannotInjectTOMLThroughStrings() throws {
    let value = "line\n[plugins.evil]\nsecret = true\n\""
    #expect(throws: (any Error).self) { try ConfigurationPatch.updating(source: "", values: ["appearance.theme": .string(value)]) }
    #expect(throws: (any Error).self) { try ConfigurationPatch.updating(source: "", values: ["terminal.font_family": .string(value)]) }
    let quoted = "Font \" # [plugins.evil] secret = true"
    let output = try ConfigurationPatch.updating(source: "", values: ["terminal.font_family": .string(quoted)])
    let parsed = try AppConfiguration.parse(output)
    #expect(parsed.terminal.fontFamily == quoted)
    #expect(parsed.plugins.isEmpty)
}

@Test func unfocusedPaneDimmingValidatesAndRoundTripsWithoutRestart() throws {
    #expect(try AppConfiguration.parse("").unfocusedPaneDim == 0.08)
    let source = "# keep\n[appearance]\nunfocused_pane_dim = 0.08 # shade\n"
    for amount in [0.0, 0.35, 1.0] {
        let updated = try ConfigurationPatch.updating(source: source, values: ["appearance.unfocused_pane_dim": .number(amount)])
        let config = try AppConfiguration.parse(updated)
        #expect(config.unfocusedPaneDim == amount)
        #expect(updated.contains("# keep") && updated.contains("# shade"))
        #expect(config.changedKeys(from: .defaults) == ["appearance.unfocused_pane_dim"])
        #expect(config.restartRequired(from: .defaults).isEmpty)
        let encoded = try JSONValue.encoding(config)
        #expect(encoded.object?["appearance"]?.object?["unfocused_pane_dim"] == (try JSONValue.encoding(amount)))
    }
    for literal in ["-0.1", "1.01", "nan", "inf", "true", "'0.5'", "2026-10-19T00:00:00Z"] {
        #expect(throws: (any Error).self) { try AppConfiguration.parse("[appearance]\nunfocused_pane_dim = " + literal) }
    }
}
