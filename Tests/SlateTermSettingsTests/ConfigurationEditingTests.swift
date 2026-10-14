import Testing
@testable import SlateTermSettings

@Test func settingsEditsPreserveUnrelatedValuesAndComments() throws {
    let source = """
    # My terminal
    [terminal] # defaults
    font_size = 18.5  # keep this note
    font_family = 'Mono #1'
    [keybind]
    'cmd+d' = 'unbound' # deliberate override
    """
    let result = try AppConfiguration.updating(source: source, values: [
        "terminal.font_size": "22", "appearance.theme": "'dark'", "terminal.shell_integration": "'off'",
    ])
    let configuration = try AppConfiguration.parse(result)
    #expect(configuration.terminal.fontSize == 22)
    #expect(configuration.theme == .dark)
    #expect(configuration.terminal.shellIntegration == .off)
    #expect(configuration.terminal.fontFamily == "Mono #1")
    #expect(configuration.keyBindings[try KeyChord.parse("cmd+d")] == nil)
    #expect(result.contains("font_size = 22  # keep this note"))
    #expect(result.contains("'cmd+d' = 'unbound' # deliberate override"))
    #expect(result.contains("[terminal] # defaults"))
}

@Test func settingsEditsHandleDottedKeysQuotedKeysAndEscapedStrings() throws {
    let source = "terminal.font_size = 15\n'keybind'.'cmd+.' = 'split.down'\n"
    let family = "A \"quoted\" \\ font"
    let result = try AppConfiguration.updating(source: source, values: [
        "terminal.font_size": "20.5", "terminal.font_family": AppConfiguration.quotedString(family),
        "keybind.cmd+.": "'split.right'",
    ])
    let configuration = try AppConfiguration.parse(result)
    #expect(configuration.terminal.fontSize == 20.5)
    #expect(configuration.terminal.fontFamily == family)
    #expect(configuration.keyBindings[try KeyChord.parse("cmd+.")] == "split.right")
    #expect(result.contains("terminal.font_size = 20.5"))
}

@Test func settingsEditsRejectInvalidChangesAndUnsupportedSyntax() throws {
    #expect(throws: (any Error).self) {
        try AppConfiguration.updating(source: "", values: ["terminal.font_size": "0"])
    }
    #expect(throws: (any Error).self) {
        try AppConfiguration.updating(source: "", values: ["terminal.font_size": "16\nfont_family = 'Injected'"])
    }
    #expect(throws: (any Error).self) {
        try AppConfiguration.updating(source: "[terminal]\nfont_szie = 13", values: ["appearance.theme": "'dark'"])
    }
    for source in ["terminal = { font_size = 13 }", "[terminal]\nfont_family = '''Mono'''"] {
        #expect(throws: ConfigurationError.self) {
            try AppConfiguration.updating(source: source, values: ["terminal.font_size": "16"])
        }
    }
}

@Test func settingsEditsValidateRelatedValuesTogether() throws {
    let result = try AppConfiguration.updating(source: "", values: [
        "terminal.shell": AppConfiguration.quotedString("/tmp/$literal/zsh"),
        "terminal.shell_integration": "'off'",
    ])
    #expect(try AppConfiguration.parse(result).terminal.shell == "/tmp/$literal/zsh")
}

@Test func settingsEditsRecognizeEquivalentKeybindingNames() throws {
    let result = try AppConfiguration.updating(
        source: "[keybind]\n'shift+cmd+x' = 'split.down' # custom shortcut\n",
        values: ["keybind.cmd+shift+x": "'split.right'"])
    #expect(try AppConfiguration.parse(result).keyBindings[KeyChord.parse("cmd+shift+x")] == "split.right")
    #expect(result.contains("'shift+cmd+x' = 'split.right' # custom shortcut"))
}
