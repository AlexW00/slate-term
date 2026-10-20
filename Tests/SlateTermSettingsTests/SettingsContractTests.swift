import Foundation
import Testing
import SlateTermCore
import SlateTermSettings
import SlateTermTestSupport

private let settingsSchemaDefinitions = AutomationContracts.settingsDefinitions.merging(AutomationContracts.notificationDefinitions) { _, _ in
    preconditionFailure("Duplicate schema definition")
}
private let settingsSchemaFormats: SchemaFormatChecks = [
    "slate-palette-name": { (try? AppConfiguration.TerminalTheme(parsing: $0)) != nil },
    "slate-key-chord": { (try? KeyChord.parse($0)) != nil },
    "slate-keybinding-setting": { $0.hasPrefix("keybind.") && (try? KeyChord.parse(String($0.dropFirst(8)))) != nil },
    "slate-search-url-template": { (try? AppConfiguration.parse("[browser]\nsearch_url = " + AppConfiguration.quotedString($0))) != nil },
    "slate-configuration-line": { (try? AppConfiguration.parse("[terminal]\nfont_family = " + AppConfiguration.quotedString($0))) != nil },
    "slate-working-directory": { (try? AppConfiguration.parse("[terminal]\nworking_directory = " + AppConfiguration.quotedString($0))) != nil },
    "slate-shell-path": { (try? AppConfiguration.parse("[terminal]\nshell_integration = 'off'\nshell = " + AppConfiguration.quotedString($0))) != nil }
]

@Test func settingsContractsAcceptRealConfigurationAndAppearanceEncoders() throws {
    let sources = ["", """
        [appearance]
        theme = 'auto'
        [terminal]
        font_size = 17.5
        light_theme = 'My Palette'
        cursor_style = 'block_hollow'
        [keybind]
        'cmd+x' = 'plugin.notes.send'
        [plugins.'notes.preview']
        'dotted.key' = [1, 2, 3]
        [notifications]
        banners = 'other_apps'
        [agents.colors]
        codex = '#123456'
        'my.agent' = '#abcdef'
        """, "[appearance]\ntheme = 'dark'\n"]
    let colors = try TerminalPalette.parse("background = #102030\nforeground = #ffffff\n").colors
    for source in sources {
        let configuration = try AppConfiguration.parse(source)
        let value = try JSONValue.encoding(configuration)
        #expect(schemaAccepts(settingsSchemaDefinitions["AppConfiguration"]!, value,
            definitions: settingsSchemaDefinitions, formats: settingsSchemaFormats))
        let appearance = AppearanceSnapshot(configuration: configuration, systemDark: true, darkSlot: true, colors: colors)
        #expect(schemaAccepts(AutomationContracts.settings[.appearanceGet]!.result, appearance.json,
            definitions: settingsSchemaDefinitions, formats: settingsSchemaFormats))
        var fields = value.object!
        fields.removeValue(forKey: "terminal")
        #expect(!schemaAccepts(settingsSchemaDefinitions["AppConfiguration"]!, .object(fields), definitions: settingsSchemaDefinitions))
    }
}

@Test func configurationPatchContractsAgreeWithTypedSourceEditing() throws {
    let schema = AutomationContracts.settings[.configPatch]!.input
    let samples: [[String: JSONValue]] = [[:], ["terminal.font_size": .number(16.5)], ["terminal.font_size": .integer(257)],
        ["appearance.unfocused_pane_dim": .number(0.35)], ["appearance.unfocused_pane_dim": .integer(0)],
        ["appearance.unfocused_pane_dim": .integer(1)], ["appearance.unfocused_pane_dim": .number(-0.1)],
        ["appearance.unfocused_pane_dim": .number(1.1)], ["appearance.unfocused_pane_dim": .bool(true)],
        ["appearance.unfocused_pane_dim": .null], ["appearance.theme": .string("auto")], ["appearance.theme": .string("system")], ["appearance.theme": .string("unknown")],
        ["terminal.working_directory": .string("~/Projects")], ["terminal.working_directory": .string("/tmp/project with spaces")],
        ["terminal.working_directory": .string("relative")], ["terminal.working_directory": .string("~someone/path")],
        ["terminal.working_directory": .string("/tmp/invalid\tpath")], ["terminal.working_directory": .string("")],
        ["terminal.inherit_working_directory": .bool(false)], ["terminal.inherit_working_directory": .string("false")],
        ["terminal.saved_output_lines": .integer(0)], ["terminal.saved_output_lines": .integer(100_000)],
        ["terminal.saved_output_lines": .integer(-1)], ["terminal.saved_output_lines": .integer(100_001)],
        ["terminal.saved_output_lines": .number(1.5)], ["terminal.saved_output_lines": .bool(true)],
        ["terminal.saved_output_lines": .string("10000")], ["terminal.saved_output_lines": .null],
        ["terminal.padding_x": .integer(64)], ["terminal.padding_x": .number(1.5)], ["terminal.font_thicken": .string("true")],
        ["terminal.dark_theme": .string("My Palette")], ["terminal.dark_theme": .string("../bad")],
        ["keybind.cmd+x": .string("pane.focus")], ["keybind.CMD+🦊": .string("unbound")],
        ["keybind.cmd+x": .string("plugin.notes.send")], ["keybind.cmd+x": .string("plugin.notes.send\n")],
        ["keybind.ctrl+\r": .string("pane.focus")], ["keybind.cmd+x": .string("unknown.command")],
        ["keybind.cmd+": .string("pane.focus")], ["browser.search_url": .string("https://example.test/?q={query}")],
        ["browser.search_url": .string("https://{query}.example.test/")], ["notifications.minimum_seconds": .integer(0)],
        ["terminal.font_family": .string("\n")], ["terminal.font_family": .null], ["terminal.unknown": .bool(true)],
        ["plugins.notes.option": .bool(true)]]
    let colorSamples: [[String: JSONValue]] = [
        ["agents.colors": .object([:])], ["agents.colors": .object(["codex": .string("#123456"), "my.agent": .string("#abcdef")])],
        ["agents.colors": .object(["Codex": .string("#123456")])], ["agents.colors": .object(["a:b": .string("#123456")])],
        ["agents.colors": .object(["a": .string("red")])], ["agents.colors": .object(["a": .null])],
        ["agents.colors": .null], ["agents.colors": .string("#123456")],
        ["agents.colors": .object(Dictionary(uniqueKeysWithValues: (0..<65).map { ("agent\($0)", .string("#123456")) }))]
    ]
    for values in samples + colorSamples {
        let input: JSONValue = .object(["values": .object(values), "expectedSourceRevision": .string("source")])
        let accepted = (try? ConfigurationPatch.updating(source: "", values: values)) != nil
        #expect(schemaAccepts(schema, input, definitions: settingsSchemaDefinitions, formats: settingsSchemaFormats) == accepted)
    }
    #expect(!schemaAccepts(schema, .object(["values": .object([:])]), definitions: settingsSchemaDefinitions))
    #expect(!schemaAccepts(schema, .object(["values": .object([:]), "expectedWriteRevision": .string("wrongGuard")]), definitions: settingsSchemaDefinitions))
    let inherited = AutomationMethod.pluginSettingsGet.resolving([:], defaults: .init(pluginID: "notes"))
    #expect(schemaAccepts(AutomationContracts.settings[.pluginSettingsGet]!.input, .object(inherited), definitions: settingsSchemaDefinitions))
    #expect(!schemaAccepts(AutomationContracts.settings[.appearanceGet]!.input, .object(["ignored": .bool(true)])))
    #expect(schemaAccepts(AutomationContracts.settings[.configGet]!.input, .object(["ignored": .bool(true)])))
}

@Test func pluginPatchContractsKeepLiteralPathsDeletionAndBounds() throws {
    let schema = AutomationContracts.settings[.pluginSettingsPatch]!.input
    func set(_ path: [String], _ value: JSONValue) -> JSONValue {
        .object(["op": .string("set"), "path": .array(path.map(JSONValue.string)), "value": value])
    }
    var depth31 = JSONValue.string("leaf")
    for _ in 0..<31 { depth31 = .array([depth31]) }
    let depth32 = JSONValue.array([depth31])
    let samples: [[JSONValue]] = [[], [set(["dotted.key", "quoted\"key"], .array([.bool(true), .string("text")]))],
        [set(["option"], .null)], [.object(["op": .string("delete"), "path": .array([.string("gone")])])],
        [.object(["op": .string("delete"), "path": .array([.string("gone")]), "value": .null])],
        [set([], .integer(1))], [set([""], .integer(1))], [set([String(repeating: "é", count: 513)], .integer(1))],
        [set(["parent"], .object([:])), set(["parent", "child"], .bool(true))],
        [set(["nested"], depth32)], [set(["nested"], .array([depth32]))],
        [set(["parent", "nested"], depth31)], [set(["parent", "nested"], depth32)],
        [set(["large"], .string(String(repeating: "x", count: 65_536)))],
        (0..<33).map { set(["key\($0)"], .bool(true)) }]
    for operations in samples {
        let input: JSONValue = .object(["id": .string("notes"), "operations": .array(operations), "expectedWriteRevision": .string("source")])
        let accepted = (try? PluginSettingsPatch.updating(source: "", pluginID: "notes", operations: operations)) != nil
        #expect(schemaAccepts(schema, input, definitions: settingsSchemaDefinitions, formats: settingsSchemaFormats) == accepted)
    }
}

@Test func settingsContractsPreserveReloadAndWriteResponseDistinctions() {
    let reload: JSONValue = .object(["changed": .array([.string("terminal.font_size")]), "restartRequired": .array([]), "operationId": .string(UUID().uuidString)])
    #expect(schemaAccepts(AutomationContracts.settings[.configReload]!.result, reload, definitions: settingsSchemaDefinitions))
    #expect(!schemaAccepts(AutomationContracts.settings[.configPatch]!.result, reload, definitions: settingsSchemaDefinitions))
    let namespace: JSONValue = .object(["id": .string("notes"), "values": .object([:]), "appliedValues": .object([:]),
        "sourceValid": .bool(false), "writeRevision": .string("source")])
    #expect(schemaAccepts(AutomationContracts.settings[.pluginSettingsGet]!.result, namespace, definitions: settingsSchemaDefinitions))
    #expect(!schemaAccepts(AutomationContracts.settings[.pluginSettingsPatch]!.result, namespace, definitions: settingsSchemaDefinitions))
    #expect(AutomationContracts.settings[.configPatch]!.errors.contains(APIError.settingsWriteFailed))
    #expect(!schemaAccepts(AutomationContracts.settings[.pluginSettingsGet]!.input, .object(["id": .string("notes\n")]), definitions: settingsSchemaDefinitions))
    #expect(Set(AutomationContracts.settings.keys) == Set<AutomationMethod>([
        .configGet, .configValidate, .configReload, .configPatch, .configResetOverrides,
        .pluginSettingsGet, .pluginSettingsPatch, .paletteList, .paletteImport, .appearanceGet
    ]))
}
