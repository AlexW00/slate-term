import Foundation
import Testing
import SlateTermCore
import SlateTermSettings
import SlateTermTestSupport

@Test func settingsCommandSchemasMatchTheSharedConfigurationPatchBoundary() throws {
    let formats: SchemaFormatChecks = ["slate-palette-name": { (try? AppConfiguration.TerminalTheme(parsing: $0)) != nil }]
    for size in [JSONValue.integer(1), .number(17.5), .integer(256), .integer(257), .integer(0), .null, .string("16")] {
        let input: JSONValue = .object(["id": .string("terminal.font.set"), "size": size])
        let accepted = (try? ConfigurationPatch.updating(source: "", values: ["terminal.font_size": size])) != nil
        #expect(schemaAccepts(AutomationContracts.applicationCommands["terminal.font.set"]!.input, input) == accepted)
    }
    for name in ["Builtin Light", "My Palette", "../outside", "", "custom\n"] {
        let input: JSONValue = .object(["id": .string("terminal.palette.set"), "slot": .string("light"), "name": .string(name)])
        let accepted = (try? ConfigurationPatch.updating(source: "", values: ["terminal.light_theme": .string(name)])) != nil
        #expect(schemaAccepts(AutomationContracts.applicationCommands["terminal.palette.set"]!.input, input, formats: formats) == accepted)
    }
    #expect(schemaAccepts(AutomationContracts.applicationCommands["appearance.set"]!.input, .object(["id": .string("appearance.set"), "mode": .string("auto")])) )
    // Commands accept auto, not the stored configuration encoder's system spelling.
    #expect(!schemaAccepts(AutomationContracts.applicationCommands["appearance.set"]!.input, .object(["id": .string("appearance.set"), "mode": .string("system")])) )
    #expect(schemaAccepts(AutomationContracts.applicationCommands["appearance.light"]!.input, .object(["id": .string("appearance.light"), "mode": .null, "expectedSourceRevision": .string("revision")])) )
    #expect(!schemaAccepts(AutomationContracts.applicationCommands["warnings.close.reset"]!.input, .object(["id": .string("warnings.close.reset"), "expectedSourceRevision": .string("revision")])) )
}
