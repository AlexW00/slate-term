import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

private let paletteSource = """
# A color-only Ghostty palette
background = #101820
foreground = F0F1F2
cursor-color = #AaBbCc
selection-background = #223344
palette = 1=#DD4455
palette = 255 = #ABCDEF
"""

@Test func customPaletteNormalizesOnlyColorSettings() throws {
    let palette = try TerminalPalette.parse(paletteSource)
    #expect(palette.source == """
    background = #101820
    cursor-color = #aabbcc
    foreground = #f0f1f2
    palette = 1=#dd4455
    palette = 255=#abcdef
    selection-background = #223344

    """)
}

@Test(arguments: [
    "command = /bin/false", "config-file = /tmp/other", "theme = Dracula", "clipboard-read = allow",
    "font-size = 24", "background-opacity = 0.5", "background = #ffffff",
    "palette = -1=#ffffff", "palette = 256=#ffffff", "palette = 1.5=#ffffff",
    "palette = 1=#ffffff\npalette = 01=#000000", "cursor-color = red", "cursor-color = #abc",
    "cursor-color = #abcdef # inline comment", "cursor-color = #abcdef\u{0}",
    "cursor-color = #ffffff\nkeybind = ctrl+a=quit", "[theme=dark]", "cursor-text = cell-background",
])
func unsafeOrUnsupportedPaletteLinesAreRejected(line: String) {
    #expect(throws: (any Error).self) { try TerminalPalette.parse("background = #000000\nforeground = #ffffff\n" + line) }
}

@Test func paletteRequiresBaseColorsAndBoundsInput() {
    #expect(throws: (any Error).self) { try TerminalPalette.parse("# empty palette") }
    #expect(throws: (any Error).self) { try TerminalPalette.parse("background = #ffffff") }
    #expect(throws: (any Error).self) { try TerminalPalette.parse(String(repeating: "#", count: 65_537)) }
}

@Test func customFilesResolveBeforeEngineSnapshotAndCannotInjectOptions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palette,\"test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("my palette.conf")
    try paletteSource.write(to: file, atomically: true, encoding: .utf8)
    let configuration = try AppConfiguration.parse("""
    [terminal]
    light_theme = "my palette"
    dark_theme = "my palette"
    """)
    let resolved = try configuration.terminal.resolvePalettes(directory: directory)
    // Changing the original after parsing cannot alter the engine input.
    try "command = /bin/false\n".write(to: file, atomically: true, encoding: .utf8)
    let snapshots = directory.appendingPathComponent("snapshots")
    let engine = try configuration.terminal.renderingConfiguration(palettes: resolved, directory: snapshots, bundledDirectory: directory)
    let files = try FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
    #expect(files.count == 1)
    #expect(try String(contentsOf: files[0], encoding: .utf8) == TerminalPalette.parse(paletteSource).source)
    #expect(engine.contains("theme = light:\""))
    #expect(engine.contains("palette,\\\"test-"))
    #expect(!engine.contains("my palette.conf"))
    #expect(!engine.contains("/bin/false"))
    #expect(configuration.changedKeys(from: .defaults) == ["terminal.light_theme", "terminal.dark_theme"])
    #expect(configuration.restartRequired(from: .defaults).isEmpty)
    #expect(try JSONValue.encoding(configuration).object?["terminal"]?.object?["light_theme"] == .string("my palette"))
    #expect(throws: (any Error).self) { try configuration.terminal.resolvePalettes(directory: directory) }
    // The editor can replace a broken palette name without reading that file.
    let repaired = try AppConfiguration.updating(source: "[terminal]\ndark_theme = 'my palette'",
                                                values: ["terminal.dark_theme": "'Dracula'"])
    #expect(try AppConfiguration.parse(repaired).terminal.darkTheme.rawValue == "Dracula")
}

@Test func paletteFileLoaderRejectsMissingNonregularOversizedAndNonUTF8Files() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palette-files-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: (any Error).self) { try TerminalPalette.load(from: directory) }
    #expect(throws: (any Error).self) { try TerminalPalette.load(from: directory.appendingPathComponent("missing")) }
    let pipe = directory.appendingPathComponent("pipe")
    #expect(mkfifo(pipe.path, 0o600) == 0)
    #expect(throws: (any Error).self) { try TerminalPalette.load(from: pipe) }
    let file = directory.appendingPathComponent("palette")
    try Data(repeating: 0x23, count: 65_537).write(to: file)
    #expect(throws: (any Error).self) { try TerminalPalette.load(from: file) }
    try Data([0xff]).write(to: file)
    #expect(throws: (any Error).self) { try TerminalPalette.load(from: file) }
}

@Test func inactiveCustomPaletteIsAlsoValidated() throws {
    let configuration = try AppConfiguration.parse("[appearance]\ntheme = 'light'\n[terminal]\ndark_theme = 'Missing \(UUID())'")
    #expect(throws: (any Error).self) { try configuration.terminal.resolvePalettes(directory: FileManager.default.temporaryDirectory) }
    #expect(throws: (any Error).self) { try AppConfiguration.parse("[terminal]\nlight_theme = '~/palettes/mine'") }
}
