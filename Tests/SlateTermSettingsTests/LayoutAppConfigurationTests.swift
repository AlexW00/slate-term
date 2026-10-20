import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func layoutConfigurationLayersExplicitValuesAndNestedPluginSettings() throws {
    let parent = """
    [terminal]
    font_size = 19
    font_family = 'Parent Mono'
    [appearance]
    theme = 'dark'
    [plugins."acme.tools".options]
    enabled = true
    count = 3
    [plugins."acme.tools"]
    items = [{ name = 'parent', count = 1 }]
    """
    let overrides = """
    terminal = { font_size = 13 }
    [plugins."acme.tools".options]
    enabled = false
    [plugins."acme.tools"]
    items = [{ name = 'local', count = 2 }]
    """
    let result = try LayoutAppConfiguration.parse(parentSource: parent, overridesSource: overrides)
    #expect(result.terminal.fontSize == 13)
    #expect(result.terminal.fontFamily == "Parent Mono")
    #expect(result.theme == .dark)
    #expect(result.plugins["acme.tools"]?["options"] == .object(["enabled": .bool(false), "count": .integer(3)]))
    #expect(result.plugins["acme.tools"]?["items"] == .array([.object(["name": .string("local"), "count": .integer(2)])]))
}

@Test func layoutConfigurationCanonicalizesBindingOverridesAndPreservesUnbound() throws {
    let result = try LayoutAppConfiguration.parse(
        parentSource: "[keybind]\n'shift+cmd+x' = 'split.right'\n'cmd+d' = 'unbound'\n",
        overridesSource: "[keybind]\n'cmd+shift+x' = 'split.down'\n")
    #expect(result.keyBindings[try KeyChord.parse("cmd+shift+x")] == "split.down")
    #expect(result.keyBindings[try KeyChord.parse("cmd+d")] == nil)
    #expect(throws: (any Error).self) {
        try LayoutAppConfiguration.parse(parentSource: "", overridesSource: "[keybind]\n'cmd+shift+x' = 'split.right'\n'shift+cmd+x' = 'split.down'\n")
    }
}

@Test func layoutConfigurationValidatesRelatedFieldsAfterMerging() throws {
    let result = try LayoutAppConfiguration.parse(parentSource: "[terminal]\nshell_integration = 'off'\n",
        overridesSource: "[terminal]\nshell = '/tmp/$literal/zsh'\n")
    #expect(result.terminal.shell == "/tmp/$literal/zsh")
    #expect(throws: (any Error).self) {
        try LayoutAppConfiguration.parse(parentSource: "[terminal]\nfont_size = 18\n", overridesSource: "[terminal]\nfont_szie = 12\n")
    }
}

@Test func layoutConfigurationFallsBackFromInvalidParentWithoutWritingEitherFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("parent.toml"), overrides = root.appendingPathComponent("overrides.toml")
    let parentText = "[terminal]\nfont_size = 'broken'\n", overrideText = "[terminal]\nfont_size = 24\n"
    try parentText.write(to: parent, atomically: true, encoding: .utf8)
    try overrideText.write(to: overrides, atomically: true, encoding: .utf8)
    let result = try LayoutAppConfiguration.load(parentURL: parent, overridesURL: overrides)
    #expect(result.configuration.terminal.fontSize == 24)
    #expect(result.parentError != nil)
    #expect(try String(contentsOf: parent, encoding: .utf8) == parentText)
    #expect(try String(contentsOf: overrides, encoding: .utf8) == overrideText)
    try FileManager.default.removeItem(at: parent)
    #expect(try LayoutAppConfiguration.load(parentURL: parent, overridesURL: overrides).parentError == nil)
    try "[terminal]\nfont_size = 0\n".write(to: overrides, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try LayoutAppConfiguration.load(parentURL: parent, overridesURL: overrides) }
}

@Test func layoutConfigurationResetRevealsParentAndPreservesUnrelatedSource() throws {
    let source = "# local settings\n[terminal]\nfont_size = 24 # local size\nfont_family = 'Local Mono' # keep\n[keybind]\n'shift+cmd+x' = 'split.right'\n[plugins.example.options]\ncount = 2\n"
    let reset = try LayoutAppConfiguration.resetOverrides(keys: ["terminal.font_size", "keybind.cmd+shift+x"], source: source)
    #expect(reset.contains("# local settings"))
    #expect(reset.contains("font_family = 'Local Mono' # keep"))
    #expect(reset.contains("[plugins.example.options]\ncount = 2"))
    let result = try LayoutAppConfiguration.parse(parentSource: "[terminal]\nfont_size = 18\n[keybind]\n'cmd+shift+x' = 'split.down'\n", overridesSource: reset)
    #expect(result.terminal.fontSize == 18)
    #expect(result.terminal.fontFamily == "Local Mono")
    #expect(result.keyBindings[try KeyChord.parse("cmd+shift+x")] == "split.down")
    #expect(try LayoutAppConfiguration.overriddenSettingKeys(source: reset) == ["terminal.font_family"])
    #expect(throws: (any Error).self) { try LayoutAppConfiguration.resetOverrides(keys: ["terminal.font_size"], source: "terminal = { font_size = 20 }") }
}

@Test func layoutConfigurationWriterUsesInheritedValidationAndOnlyEditsRequestedFields() throws {
    let parent = "[terminal]\nshell_integration = 'off'\nfont_size = 22\nfont_family = 'Inherited Mono'\n"
    let source = "# local\n[terminal]\nshell = '/tmp/$literal/zsh' # literal path\n"
    let result = try LayoutAppConfiguration.updating(source: source, values: ["terminal.font_size": "13"]) {
        try LayoutAppConfiguration.parse(parentSource: parent, overridesSource: $0)
    }
    #expect(result.contains("shell = '/tmp/$literal/zsh' # literal path"))
    #expect(!result.contains("font_family"))
    #expect(!result.contains("shell_integration"))
    #expect(try LayoutAppConfiguration.parse(parentSource: parent, overridesSource: result).terminal.fontSize == 13)
    #expect(try LayoutAppConfiguration.overriddenSettingKeys(source: result) == ["terminal.font_size", "terminal.shell"])
    #expect(throws: (any Error).self) {
        try LayoutAppConfiguration.updating(source: source, values: ["terminal.font_size": "0"]) {
            try LayoutAppConfiguration.parse(parentSource: parent, overridesSource: $0)
        }
    }
    #expect(throws: (any Error).self) {
        try LayoutAppConfiguration.updating(source: source, values: ["terminal.font_szie": "16"]) {
            try LayoutAppConfiguration.parse(parentSource: parent, overridesSource: $0)
        }
    }
}

@Test func layoutConfigurationPluginDeleteRevealsInheritedValuesWithoutCopyingThem() throws {
    let parent = "[terminal]\nshell_integration = 'off'\n[plugins.example.options]\ncount = 3\nenabled = true\n"
    let source = "[terminal]\nshell = '/tmp/$literal/zsh' # keep\n[plugins.example.options]\ncount = 7\n"
    let result = try LayoutAppConfiguration.updatingPluginSettings(source: source, pluginID: "example", operations: [
        .object(["op": .string("delete"), "path": .array([.string("options"), .string("count")])]),
        .object(["op": .string("set"), "path": .array([.string("local")]), "value": .bool(true)])
    ]) { try LayoutAppConfiguration.parse(parentSource: parent, overridesSource: $0) }
    #expect(result.contains("shell = '/tmp/$literal/zsh' # keep"))
    #expect(!result.contains("count"))
    #expect(!result.contains("enabled"))
    let configuration = try LayoutAppConfiguration.parse(parentSource: parent, overridesSource: result)
    #expect(configuration.plugins["example"]?["options"] == .object(["count": .integer(3), "enabled": .bool(true)]))
    #expect(configuration.plugins["example"]?["local"] == .bool(true))
}

@Test func layoutConfigurationResetRejectsUnsupportedKeysAndInvalidRequests() throws {
    for keys in [[], ["terminal.font_szie"], ["terminal.font_size", "terminal.font_size"], ["plugins.example.value"], ["keybind.not-a-chord"]] {
        #expect(throws: (any Error).self) { try LayoutAppConfiguration.resetOverrides(keys: keys, source: "") }
    }
}

@Test func layoutConfigurationParentRuntimeValidationFallsBackButCanRecover() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appendingPathComponent("parent.toml"), overrides = root.appendingPathComponent("overrides.toml")
    try "[terminal]\nfont_size = 20\n".write(to: parent, atomically: true, encoding: .utf8)
    try "[appearance]\ntheme = 'dark'\n".write(to: overrides, atomically: true, encoding: .utf8)
    let failed = try LayoutAppConfiguration.load(parentURL: parent, overridesURL: overrides) { _ in
        throw ConfigurationError.invalid("Missing parent palette")
    }
    #expect(failed.parentError?.contains("Missing parent palette") == true)
    #expect(failed.configuration.terminal.fontSize == AppConfiguration.defaults.terminal.fontSize)
    #expect(failed.configuration.theme == .dark)
    let recovered = try LayoutAppConfiguration.load(parentURL: parent, overridesURL: overrides)
    #expect(recovered.parentError == nil)
    #expect(recovered.configuration.terminal.fontSize == 20)
    #expect(recovered.configuration.theme == .dark)
}
