import Foundation
import Testing
@testable import SlateTermSettings

@Test func importingPalettesAddsNamedCopiesWithoutOverwritingOrShadowing() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palette-import-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = PaletteLibrary(directory: directory.appendingPathComponent("palettes"))
    let source = directory.appendingPathComponent("Ocean.theme")
    let firstColors = "background = #102030\nforeground = #eeeeee\n"
    try firstColors.write(to: source, atomically: true, encoding: .utf8)
    #expect(try library.entries().isEmpty)
    let first = try library.importPalette(from: source)
    #expect(first.name == "Ocean")
    #expect(first.url == library.directory.appendingPathComponent("Ocean.conf"))
    #expect(try String(contentsOf: first.url, encoding: .utf8) == firstColors)
    #expect(try library.importPalette(from: source) == first)
    let secondColors = "background = #abcdef\nforeground = #123456\n"
    try secondColors.write(to: source, atomically: true, encoding: .utf8)
    let second = try library.importPalette(from: source)
    #expect(second.name == "Ocean-2")
    #expect(try String(contentsOf: first.url, encoding: .utf8) == firstColors)
    #expect(try String(contentsOf: second.url, encoding: .utf8) == secondColors)
    #expect(try library.importPalette(from: source) == second)
    let bundledName = directory.appendingPathComponent("Nord.conf")
    try firstColors.write(to: bundledName, atomically: true, encoding: .utf8)
    #expect(try library.importPalette(from: bundledName).name == "Nord-2")
    #expect(try library.entries().map(\.name) == ["Nord-2", "Ocean", "Ocean-2"])
    try FileManager.default.removeItem(at: source)
    let configuration = try AppConfiguration.parse("[terminal]\nlight_theme = 'Ocean'\ndark_theme = 'Ocean-2'")
    _ = try configuration.terminal.resolvePalettes(directory: library.directory)
}

@Test func importingDoesNotReuseAnExternalSymlinkAsItsCopy() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palette-link-\(UUID())")
    let library = PaletteLibrary(directory: directory.appendingPathComponent("palettes"))
    try FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("Ocean.conf")
    try "background = #102030\nforeground = #ffffff\n".write(to: source, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: library.directory.appendingPathComponent("Ocean.conf"), withDestinationURL: source)
    let imported = try library.importPalette(from: source)
    #expect(imported.name == "Ocean-2")
    try FileManager.default.removeItem(at: source)
    #expect(try TerminalPalette.load(from: imported.url).source.contains("background = #102030"))
}

@Test func invalidImportsDoNotCreateAvailablePalettes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bad-palette-import-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = PaletteLibrary(directory: directory.appendingPathComponent("palettes"))
    let source = directory.appendingPathComponent("Bad.conf")
    try "background = #000000\nforeground = #ffffff\ncommand = /bin/false\n".write(to: source, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try library.importPalette(from: source) }
    #expect(try library.entries().isEmpty)
}

@Test(arguments: ["/tmp/palette", "~/palette", "../palette", "relative/palette", "..", ".hidden", "folder\\palette", "palette.conf", " padded ", "", "bad\nname", "bad\u{2028}name", "nested/\u{0301}Ocean", "folder\\\u{0301}palette", "scheme:\u{0301}name", ".\u{0301}hidden", String(repeating: "a", count: 129)])
func paletteReferencesAcceptNamesOnly(name: String) {
    #expect(throws: (any Error).self) { try AppConfiguration.TerminalTheme(parsing: name) }
    #expect(throws: (any Error).self) {
        try AppConfiguration.parse("[terminal]\ndark_theme = " + AppConfiguration.quotedString(name))
    }
}
