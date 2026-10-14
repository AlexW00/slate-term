import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

private func rendering(_ configuration: AppConfiguration) throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palette-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    return try configuration.terminal.renderingConfiguration(palettes: configuration.terminal.resolvePalettes(directory: directory), directory: directory, bundledDirectory: URL(fileURLWithPath: "/bundled-palettes"))
}

@Test func renderingSettingsMapToEngineOptionsAndReportChanges() throws {
    let configuration = try AppConfiguration.parse("""
    [appearance]
    theme = "auto"
    [terminal]
    font_thicken = true
    minimum_contrast = 4.5
    cursor_style = "underline"
    cursor_blink = "off"
    padding_x = 12
    padding_y = 8
    light_theme = "Catppuccin Latte"
    dark_theme = "Catppuccin Mocha"
    """)
    #expect(configuration.theme == .system)
    #expect(try rendering(configuration) == """
    font-family = SF Mono
    font-size = 13.0
    font-thicken = true
    minimum-contrast = 4.5
    cursor-style = underline
    cursor-style-blink = false
    window-padding-x = 12
    window-padding-y = 8
    theme = light:"/bundled-palettes/Catppuccin Latte",dark:"/bundled-palettes/Catppuccin Mocha"
    """)
    #expect(Set(configuration.changedKeys(from: .defaults)) == Set([
        "terminal.font_thicken", "terminal.minimum_contrast", "terminal.cursor_style", "terminal.cursor_blink",
        "terminal.padding_x", "terminal.padding_y", "terminal.light_theme", "terminal.dark_theme",
    ]))
    #expect(configuration.restartRequired(from: .defaults) == ["terminal.padding_x", "terminal.padding_y"])
    let encoded = try JSONValue.encoding(configuration).object?["terminal"]?.object
    #expect(encoded?["font_thicken"] == .bool(true))
    #expect(encoded?["minimum_contrast"] == .number(4.5))
    #expect(encoded?["cursor_style"] == .string("underline"))
    #expect(encoded?["cursor_blink"] == .string("off"))
    #expect(encoded?["padding_x"] == .integer(12))
    #expect(encoded?["padding_y"] == .integer(8))
    #expect(encoded?["light_theme"] == .string("Catppuccin Latte"))
    #expect(encoded?["dark_theme"] == .string("Catppuccin Mocha"))
}

@Test func renderingDefaultsPreserveEngineBehavior() throws {
    let configuration = try AppConfiguration.parse("")
    #expect(configuration.terminal.minimumContrast == 1)
    #expect(!configuration.terminal.fontThicken)
    #expect(configuration.terminal.cursorStyle == .block)
    #expect(configuration.terminal.cursorBlink == .auto)
    #expect(configuration.terminal.paddingX == 2)
    #expect(configuration.terminal.paddingY == 2)
    #expect(try rendering(configuration).contains("cursor-style-blink = \n"))
    #expect(try rendering(configuration).contains("theme = light:\"/bundled-palettes/Builtin Light\",dark:\"/bundled-palettes/Builtin Dark\""))
    #expect(try AppConfiguration.parse("[appearance]\ntheme = 'system'") == configuration)
    let boundaries = try AppConfiguration.parse("[terminal]\nminimum_contrast = 21\npadding_x = 0\npadding_y = 64\ncursor_blink = 'on'")
    #expect(try rendering(boundaries).contains("cursor-style-blink = true"))
    #expect(boundaries.terminal.minimumContrast == 21)
}

@Test(arguments: [
    "font_thicken = 'true'", "minimum_contrast = 0.9", "minimum_contrast = 21.1",
    "minimum_contrast = nan", "minimum_contrast = inf", "minimum_contrast = '3'",
    "minimum_contrast = 1970-01-01T00:00:13Z", "minimum_contrast = true",
    "padding_x = -1", "padding_y = 65", "padding_x = 2.5", "padding_y = '8'",
    "padding_x = 1970-01-01T00:00:13Z", "padding_y = true",
    "cursor_style = 'beam'", "cursor_blink = true", "cursor_blink = 'sometimes'",
    "light_theme = 'relative/theme'", "dark_theme = '/tmp/theme'", "dark_theme = '~/theme'",
    "light_theme = '../theme'", "dark_theme = 'my.conf'", "light_theme = ''",
    "dark_theme = \"Builtin Dark\\ncommand = /bin/false\"",
])
func invalidRenderingSettingsAreRejected(assignment: String) {
    #expect(throws: (any Error).self) { try AppConfiguration.parse("[terminal]\n" + assignment) }
}

@Test func appearanceEditsPreserveCommentsAndUnrelatedSettings() throws {
    let source = """
    # My terminal
    [appearance]
    theme = 'system' # follow macOS
    [terminal]
    shell = '/bin/zsh'
    minimum_contrast = 1 # original colors
    """
    let updated = try AppConfiguration.updating(source: source, values: [
        "appearance.theme": "\"dark\"", "terminal.minimum_contrast": "3",
        "terminal.cursor_style": "\"bar\"", "terminal.dark_theme": "\"Catppuccin Mocha\"",
        "terminal.padding_x": "8", "terminal.font_thicken": "true",
    ])
    #expect(updated.contains("# My terminal"))
    #expect(updated.contains("# follow macOS"))
    #expect(updated.contains("minimum_contrast = 3 # original colors"))
    #expect(updated.contains("shell = '/bin/zsh'"))
    let parsed = try AppConfiguration.parse(updated)
    #expect(parsed.theme == .dark)
    #expect(parsed.terminal.cursorStyle == .bar)
    #expect(parsed.terminal.darkTheme == AppConfiguration.TerminalTheme(.catppuccinMocha))
    #expect(parsed.terminal.paddingX == 8)
    #expect(parsed.terminal.fontThicken)
}
