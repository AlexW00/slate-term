import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

private let bundledThemes = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent(".build/bootstrap/ghostty/zig-out/share/ghostty/themes")

@Test(.enabled(if: FileManager.default.fileExists(atPath: bundledThemes.path)))
func everyBundledThemeParsesCompletely() throws {
    for theme in AppConfiguration.BundledTerminalTheme.allCases {
        let source = try String(contentsOf: bundledThemes.appendingPathComponent(theme.rawValue), encoding: .utf8)
        let colors = try TerminalPalette.parse(source).colors
        // Bundled themes define every key, so no fallback may be used.
        for key in ["cursor-color", "cursor-text", "selection-background", "selection-foreground"] + (0..<16).map({ "palette = \($0)" }) {
            #expect(source.contains(key), "\(theme.rawValue) lacks \(key)")
        }
        #expect(colors.ansi.count == 16)
    }
}

@Test func missingPaletteKeysUseFallbacks() throws {
    let colors = try TerminalPalette.parse("background = #102030\nforeground = #E0E0E0\npalette = 1=#FF0000\n").colors
    #expect(colors.background == "#102030")
    #expect(colors.foreground == "#e0e0e0")
    #expect(colors.cursor == "#e0e0e0")
    #expect(colors.cursorText == "#102030")
    #expect(colors.selectionBackground == "#e0e0e0")
    #expect(colors.selectionForeground == "#102030")
    #expect(colors.ansi[1] == "#ff0000")
    #expect(colors.ansi[0] == "#1d1f21")
    #expect(colors.ansi.count == 16)
}

@Test func toneFollowsThePaletteNotTheSlot() throws {
    let dark = try TerminalPalette.parse("background = #1e1e2e\nforeground = #cdd6f4\n").colors
    let light = try TerminalPalette.parse("background = #fdf6e3\nforeground = #586e75\n").colors
    let configuration = try AppConfiguration.parse("[appearance]\ntheme = \"light\"\n")
    let snapshot = AppearanceSnapshot(configuration: configuration, systemDark: true, darkSlot: false, colors: dark)
    #expect(snapshot.tone == "dark")
    #expect(snapshot.slot == "light")
    #expect(snapshot.systemDark == nil, "Forced appearance hides the system value")
    #expect(AppearanceSnapshot(configuration: configuration, systemDark: nil, darkSlot: false, colors: light).tone == "light")
}

@Test func revisionIsStableForEqualAppearancesAndChangesOtherwise() throws {
    let configuration = AppConfiguration.defaults
    let colors = try TerminalPalette.parse("background = #000000\nforeground = #ffffff\n").colors
    let first = AppearanceSnapshot(configuration: configuration, systemDark: true, darkSlot: true, colors: colors)
    let same = AppearanceSnapshot(configuration: configuration, systemDark: true, darkSlot: true, colors: colors)
    let flipped = AppearanceSnapshot(configuration: configuration, systemDark: false, darkSlot: false, colors: colors)
    #expect(first.revision == same.revision)
    #expect(first.revision != flipped.revision)
    guard case .object(let fields) = first.json else { Issue.record("Expected an object"); return }
    #expect(fields["revision"] == .string(first.revision))
    #expect(fields["setting"] == .string("system"))
    #expect(fields["systemAppearance"] == .string("dark"))
    #expect(first.eventPayload == .object(["revision": .string(first.revision), "tone": .string("dark"), "slot": .string("dark")]))
}
