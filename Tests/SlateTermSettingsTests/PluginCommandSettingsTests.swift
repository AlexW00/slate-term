import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func pluginBindingsAndSettingsDoNotRequireLoadedPlugins() throws {
    let source = """
    [keybind]
    "cmd+shift+b" = "plugin.sidebar.toggle"
    [plugins.sidebar]
    side = "left"
    width = 0.25
    enabled = true
    count = 2
    tags = ["a", "b"]
    [plugins."acme.tools".custom]
    nested = "value"
    """
    let configuration = try AppConfiguration.parse(source)
    #expect(configuration.keyBindings[try KeyChord.parse("cmd+shift+b")] == "plugin.sidebar.toggle")
    #expect(configuration.plugins["sidebar"]?["width"] == .number(0.25))
    #expect(configuration.plugins["sidebar"]?["enabled"] == .bool(true))
    #expect(configuration.plugins["sidebar"]?["count"] == .integer(2))
    #expect(configuration.plugins["acme.tools"]?["custom"] == .object(["nested": .string("value")]))
    #expect(try AppConfiguration.parse("[plugins.tools]\ncustom = { nested = 'value' }").plugins["tools"]?["custom"] == .object(["nested": .string("value")]))
    #expect(configuration.changedKeys(from: .defaults).contains("plugins"))
    #expect(!configuration.restartRequired(from: .defaults).contains("plugins"))
    let encoded = try JSONValue.encoding(configuration)
    #expect(encoded.object?["plugins"]?.object?["sidebar"]?.object?["side"] == .string("left"))
    let updated = try AppConfiguration.updating(source: source, values: ["keybind.cmd+shift+b": AppConfiguration.quotedString("unbound")])
    #expect(try AppConfiguration.parse(updated).plugins == configuration.plugins)
}

@Test func invalidPluginSettingsAndCommandNamesAreRejected() {
    for source in [
        "[keybind]\n\"cmd+b\" = \"plugin.tools\"",
        "[keybind]\n\"cmd+b\" = \"split.typo\"",
        "[plugins]\nsidebar = 42",
        "[plugins.\"../bad\"]\nwidth = 1",
        "[plugins.tools]\nvalue = nan",
        "[plugins.tools]\nvalue = 2026-10-14",
        "plugins = 42",
        "[plugins.tools]\nvalue = \"\(String(repeating: "a", count: 65_536))\"",
    ] { #expect(throws: (any Error).self) { try AppConfiguration.parse(source) } }
}

@Test func pluginCatalogPersistsHeadlessCommands() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var catalog = try PluginCatalog(directory: directory)
    let plugin = try PluginRegistration.parse(Data(#"{"id":"tools","title":"Tools","commands":[{"id":"go","title":"Go","executable":"/bin/sh"}]}"#.utf8))
    try catalog.register(plugin, replace: false)
    #expect(try PluginCatalog(directory: directory).registrations == [plugin])
    try catalog.remove(plugin.id)
    #expect(try PluginCatalog(directory: directory).registrations.isEmpty)
}
