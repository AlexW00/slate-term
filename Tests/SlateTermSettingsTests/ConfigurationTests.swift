import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func missingConfigurationFieldsUseDefaultsAndOverridesAreTyped() throws {
    #expect(try AppConfiguration.parse("") == .defaults)
    let config = try AppConfiguration.parse("""
    [terminal]
    font_size = 18.5
    [appearance]
    theme = "light"
    """)
    #expect(config.terminal.fontSize == 18.5)
    #expect(config.terminal.fontFamily == "SF Mono")
    #expect(config.terminal.shell == "/bin/zsh")
    #expect(config.theme == .light)
    #expect(config.restoreWorkspace)
    #expect(config.keyBindings[try KeyChord.parse("cmd+d")] == "split.right")
}

@Test func keybindingsMergeDefaultsCanonicalizeAndCanBeRemoved() throws {
    let config = try AppConfiguration.parse("""
    [keybind]
    "shift+cmd+x" = "split.down"
    "cmd+d" = "unbound"
    """)
    #expect(config.keyBindings[try KeyChord.parse("cmd+shift+x")] == "split.down")
    #expect(config.keyBindings[try KeyChord.parse("cmd+d")] == nil)
    #expect(config.keyBindings[try KeyChord.parse("cmd+t")] == "tab.new")
    #expect(try KeyChord.parse("shift+CMD+X").description == "cmd+shift+x")
    #expect(try KeyChord.parse("cmd+ ") == KeyChord.parse("cmd+space"))
    #expect(try KeyChord.parse("cmd+\u{f702}") == KeyChord.parse("cmd+left"))
}

@Test(arguments: [
    "[terminal]\nfont_size = 0", "[terminal]\nfont_size = inf", "[terminal]\nfont_size = nan",
    "[terminal]\nfont_size = 1000", "[terminal]\nshell = 'zsh'", "[terminal]\nshell_integration = 'maybe'",
    "[appearance]\ntheme = 'mystery'", "[terminal]\nfont_szie = 16", "[termnal]\nfont_size = 16",
    "[keybind]\n'cmd+d' = 'does.not.exist'", "[keybind]\n'cmd+cmd+d' = 'split.right'",
    "[keybind]\n'cmd+wat+d' = 'split.right'", "[keybind]\n'cmd+d+e' = 'split.right'",
    "[keybind]\n'cmd+shift+d' = 'split.right'\n'shift+cmd+d' = 'split.down'",
    "[terminal]\nfont_family = \"bad\\ncommand = /bin/evil\"",
    "[terminal]\nfont_family = \"SF Mono\\r\\ncommand = /bin/false\"",
    "[terminal]\nshell = \"/bin/zsh\\r\\nfont_size = 2\"",
    "[terminal]\nfont_size = 1970-01-01T00:00:13Z",
    "[terminal]\nshell = '/tmp/$literal/zsh'", "[terminal]\nshell = '/tmp/`literal`/zsh'",
    "[terminal]\nshell = '/tmp/\\literal/zsh'",
    "[terminal]\nfont_size = '13'", "[terminal]\nfont_size = true", "[terminal]\nfont_size = [13]",
    "[keybind]\n'cmd+space' = 'split.right'\n'cmd+ ' = 'split.down'",
    "[keybind]\n'cmd+left' = 'split.right'\n'cmd+\u{f702}' = 'split.down'", "[keybind]\n\"cmd+\\u0000\" = 'split.down'",
])
func invalidConfigurationIsRejected(source: String) {
    #expect(throws: (any Error).self) { try AppConfiguration.parse(source) }
}

@Test(.enabled(if: geteuid() != 0)) func unreadableConfigurationIsNotMistakenForAnAbsentFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-config-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { chmod(directory.path, 0o700); try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.toml")
    try "[terminal]\nfont_size = 18".write(to: file, atomically: true, encoding: .utf8)
    #expect(chmod(directory.path, 0) == 0)
    #expect(throws: (any Error).self) { try AppConfiguration.load(from: file) }
}

@Test func disablingIntegrationAllowsLiteralShellMetacharacters() throws {
    let config = try AppConfiguration.parse("[terminal]\nshell = '/tmp/$literal/zsh'\nshell_integration = 'off'\n")
    #expect(config.terminal.shell == "/tmp/$literal/zsh")
}

@Test func shellValidationRejectsDirectoriesAndAllowsExecutableSymlinks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-shell-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let alias = directory.appendingPathComponent("zsh")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: "/bin/zsh"))
    let valid = try AppConfiguration.parse("[terminal]\nshell = '\(alias.path)'\n")
    try valid.validateShellExecutable()
    let invalid = try AppConfiguration.parse("[terminal]\nshell = '/bin'\n")
    #expect(throws: (any Error).self) { try invalid.validateShellExecutable() }
}

@Test func reloadPlanningDistinguishesLiveSettingsFromProcessSettings() throws {
    let next = try AppConfiguration.parse("""
    [terminal]
    shell = "/bin/bash"
    shell_integration = "off"
    font_size = 17
    [layout]
    restore_workspace = false
    """)
    #expect(next.changedKeys(from: .defaults) == ["layout.restore_workspace", "terminal.font_size", "terminal.shell", "terminal.shell_integration"])
    #expect(next.restartRequired(from: .defaults) == ["terminal.shell", "terminal.shell_integration"])
    let encoded = try JSONValue.encoding(next)
    #expect(encoded.object?["keybind"]?.object?["cmd+d"] == .string("split.right"))
}

@Test func browserSearchEscapesQueriesAndPreservesAddresses() throws {
    let configuration = try AppConfiguration.parse("[browser]\nsearch_url = 'https://example.com/find?q={query}&source=slate'")
    let query = "日本語 & + # /?"
    let url = try configuration.browser.addressURL(for: query)
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(items == [URLQueryItem(name: "q", value: query), URLQueryItem(name: "source", value: "slate")])
    #expect(try configuration.browser.addressURL(for: " example.com/path ").absoluteString == "https://example.com/path")
    #expect(try configuration.browser.addressURL(for: "http://localhost:3000/").absoluteString == "http://localhost:3000/")
    #expect(try configuration.browser.addressURL(for: "localhost:3000/").absoluteString == "https://localhost:3000/")
    #expect(try configuration.browser.addressURL(for: "https://example.com/日本語 a").path == "/日本語 a")
    for path in ["/tmp/Local page 日本語 #1.html", "~/Local page.html"] {
        let expected = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        #expect(try configuration.browser.addressURL(for: path) == expected)
        #expect(try configuration.browser.addressURL(for: expected.absoluteString) == expected)
    }
    #expect(throws: (any Error).self) { try configuration.browser.addressURL(for: "file://remote/tmp/test") }
    #expect(configuration.changedKeys(from: .defaults) == ["browser.search_url"])
    #expect(configuration.restartRequired(from: .defaults).isEmpty)
    #expect(try JSONValue.encoding(configuration).object?["browser"]?.object?["search_url"] == .string(configuration.browser.searchURL))
}

@Test(arguments: ["https://example.com/", "file:///tmp/{query}", "https://{query}.example.com/search", "https://user:pass@example.com/?q={query}", "https://example.com/?q={query}\n", "https://example.com/?q={query} "])
func invalidSearchTemplatesAreRejected(template: String) {
    #expect(throws: (any Error).self) { try AppConfiguration.parse("[browser]\nsearch_url = '''\(template)'''") }
}

@Test func navigationBindingsCanBeConfiguredAndUnbound() throws {
    let configuration = try AppConfiguration.parse("""
    [keybind]
    "cmd+[" = "unbound"
    "ctrl+b" = "browser.back"
    "ctrl+alt+h" = "unbound"
    "cmd+1" = "tab.select3"
    """)
    #expect(configuration.keyBindings[try KeyChord.parse("cmd+[")] == nil)
    #expect(configuration.keyBindings[try KeyChord.parse("ctrl+b")] == "browser.back")
    #expect(configuration.keyBindings[try KeyChord.parse("cmd+l")] == "browser.focusAddress")
    #expect(configuration.keyBindings[try KeyChord.parse("ctrl+alt+h")] == nil)
    #expect(configuration.keyBindings[try KeyChord.parse("ctrl+alt+l")] == "focus.right")
    #expect(configuration.keyBindings[try KeyChord.parse("cmd+1")] == "tab.select3")
    #expect(configuration.keyBindings[try KeyChord.parse("cmd+shift+]")] == "tab.next")
}

@Test func terminalDirectoryDefaultsAndOverridesApplyToNewSessions() throws {
    let defaults = AppConfiguration.defaults.terminal
    #expect(defaults.inheritWorkingDirectory)
    #expect(defaults.workingDirectory == "~")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let inherited = root.appendingPathComponent("project with spaces")
    try FileManager.default.createDirectory(at: inherited, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = "[terminal]\nworking_directory = \(AppConfiguration.quotedString(root.path))\n"
    let config = try AppConfiguration.parse(source)
    #expect(config.terminal.startingDirectory(inheriting: inherited.path) == inherited.path)
    #expect(config.terminal.startingDirectory(inheriting: nil) == root.path)
    #expect(config.terminal.startingDirectory(inheriting: root.appendingPathComponent("missing").path) == root.path)
    #expect(config.terminal.startingDirectory(inheriting: "relative") == root.path)
    let disabled = try AppConfiguration.parse(source + "inherit_working_directory = false\n")
    #expect(disabled.terminal.startingDirectory(inheriting: inherited.path) == root.path)
    #expect(disabled.restartRequired(from: .defaults).isEmpty)
    #expect(Set(disabled.changedKeys(from: .defaults)) == ["terminal.working_directory", "terminal.inherit_working_directory"])
    try FileManager.default.removeItem(at: inherited)
    #expect(config.terminal.startingDirectory(inheriting: inherited.path) == root.path)
    let missing = try AppConfiguration.parse("[terminal]\nworking_directory = '/nonexistent-slate-test-directory'\n")
    #expect(missing.terminal.startingDirectory(inheriting: nil) == NSHomeDirectory())
    let patched = try ConfigurationPatch.updating(source: "# keep\n", values: [
        "terminal.working_directory": .string(root.path), "terminal.inherit_working_directory": .bool(false)])
    #expect(patched.contains("# keep"))
    #expect(try AppConfiguration.parse(patched).terminal == disabled.terminal)
}

@Test(arguments: ["", "relative/path", "~someone/path", "/tmp\ninvalid", "/tmp\u{0}invalid"])
func invalidTerminalWorkingDirectoriesAreRejected(path: String) {
    #expect(throws: (any Error).self) {
        try AppConfiguration.parse("[terminal]\nworking_directory = \(AppConfiguration.quotedString(path))\n")
    }
}
