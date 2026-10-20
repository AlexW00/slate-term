import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func restoredDisplayTextPreservesUnicodeAndNeutralizesControls() {
    let source = "日本語 e\u{301} 🧪\r\n\0\u{1b}]52;c;clipboard\u{7}\u{9}tail\u{9b}6n"
    let output = SavedTerminalOutput(text: source, capturedAt: Date(), ended: true)
    #expect(output.terminalDisplayText == "日本語 e\u{301} 🧪\n��]52;c;clipboard�    tail�6n")
    let large = SavedTerminalOutput(text: String(repeating: "\0", count: SavedTerminalOutput.maximumBytes),
                                   capturedAt: Date(), ended: true)
    #expect(large.terminalDisplayText.utf8.count <= SavedTerminalOutput.maximumBytes)
}

@Test func savedOutputKeepsNewestLogicalLinesAndTrailingNewline() {
    for (source, expected) in [("first\nsecond\nthird\n", "second\nthird\n"),
                               ("first\nsecond\nthird", "second\nthird"),
                               ("first\r\nsecond\r\nthird\r\n", "second\r\nthird\r\n"),
                               ("first\n\n", "first\n\n"), ("", "")] {
        #expect(SavedTerminalOutput.boundedText(source, lineLimit: 2) == expected)
    }
    #expect(SavedTerminalOutput.boundedText("first\n\n", lineLimit: 1) == "\n")
    #expect(SavedTerminalOutput.lineCount("") == 0)
    #expect(SavedTerminalOutput.lineCount("one\n") == 1)
    #expect(SavedTerminalOutput.lineCount("one\n\n") == 2)
    #expect(SavedTerminalOutput.lineCount("one\r\ntwo") == 2)
    for limit in [-1, 0, 100_001, Int.max] {
        #expect(SavedTerminalOutput.boundedText("discard", lineLimit: limit).isEmpty)
    }
}

@Test func savedOutputByteBoundPreservesUnicodeCharacters() {
    let tail = "日本語👩🏽‍💻e\u{301}\n"
    let source = String(repeating: "a", count: SavedTerminalOutput.maximumBytes) + tail
    let bounded = SavedTerminalOutput.boundedText(source, lineLimit: 10_000)
    #expect(bounded.utf8.count == SavedTerminalOutput.maximumBytes)
    #expect(bounded.hasSuffix(tail))
    #expect(SavedTerminalOutput.boundedText("before👩🏽‍💻", lineLimit: 1, byteLimit: 3).isEmpty)
    #expect(SavedTerminalOutput.boundedText("beforee\u{301}", lineLimit: 1, byteLimit: 3) == "e\u{301}")
    #expect(SavedTerminalOutput.boundedText("text", lineLimit: 1, byteLimit: -1).isEmpty)
    #expect(SavedTerminalOutput.boundedText(source, lineLimit: 1, byteLimit: Int.max).utf8.count <= SavedTerminalOutput.maximumBytes)
}

@Test func savedOutputConfigurationUsesStrictIntegerBoundsAndLivePatches() throws {
    #expect(AppConfiguration.defaults.terminal.savedOutputLines == 10_000)
    #expect(try AppConfiguration.parse("").terminal.savedOutputLines == 10_000)
    let source = "# keep\n[terminal]\nsaved_output_lines = 10000 # history\nfont_size = 14\n"
    for limit in [0, 1, 100_000] {
        let updated = try ConfigurationPatch.updating(source: source, values: ["terminal.saved_output_lines": .integer(limit)])
        let config = try AppConfiguration.parse(updated)
        #expect(config.terminal.savedOutputLines == limit)
        #expect(updated.contains("# keep") && updated.contains("# history") && updated.contains("font_size = 14"))
        #expect(config.changedKeys(from: try AppConfiguration.parse(source)) == ["terminal.saved_output_lines"])
        #expect(config.restartRequired(from: try AppConfiguration.parse(source)).isEmpty)
        #expect(try JSONValue.encoding(config).object?["terminal"]?.object?["saved_output_lines"] == .integer(limit))
    }
    for literal in ["-1", "100001", "1.0", "true", "'1000'", "[10]", "nan", "2026-10-20T00:00:00Z"] {
        #expect(throws: (any Error).self) { try AppConfiguration.parse("[terminal]\nsaved_output_lines = " + literal) }
        #expect(throws: (any Error).self) { try AppConfiguration.updating(source: source, values: ["terminal.saved_output_lines": literal]) }
    }
    for value: JSONValue in [.integer(-1), .integer(100_001), .number(1.5), .string("1"), .bool(true), .null] {
        #expect(throws: (any Error).self) { try ConfigurationPatch.updating(source: source, values: ["terminal.saved_output_lines": value]) }
    }
}

@Test func savedOutputRestorationReadsLegacyAndFiltersRemovedOrChangedPanes() throws {
    let legacy = Data(#"{"version":1,"directories":{},"browserURLs":{},"windowFrames":{}}"#.utf8)
    #expect(try JSONDecoder().decode(WorkspaceRestoration.self, from: legacy).terminalOutput.isEmpty)
    let nullOutput = Data(#"{"version":1,"directories":{},"browserURLs":{},"windowFrames":{},"terminalOutput":null}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(WorkspaceRestoration.self, from: nullOutput) }
    let date = Date(timeIntervalSince1970: 1_792_454_400)
    let record = SavedTerminalOutput(text: "old output\n", capturedAt: date, ended: true)
    var restoration = WorkspaceRestoration()
    var workspace = Workspace()
    let browser = try workspace.split(PaneID(1), direction: .right)
    try workspace.setType(browser, to: .browser)
    restoration.terminalOutput = ["p1": record, browser.description: record, "p999": record]
    #expect(throws: (any Error).self) { try restoration.validate(for: workspace) }
    let retained = restoration.retained(for: workspace)
    #expect(retained.terminalOutput == ["p1": record])
    try retained.validate(for: workspace)
    #expect(try JSONDecoder().decode(WorkspaceRestoration.self, from: JSONEncoder().encode(retained)) == retained)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-output-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WorkspaceStore(directory: directory)
    try store.save(workspace, restoration: retained)
    #expect(try store.loadSnapshot()?.restoration == retained)
}

@Test func savedOutputRejectsMalformedRecordsAndWorkspaceBudgetOverflow() throws {
    for json in [#"{"text":"ok","ended":true}"#,
                 #"{"text":2,"capturedAt":0,"ended":true}"#,
                 #"{"text":"ok","capturedAt":1e100,"ended":true}"#,
                 #"{"text":"ok","capturedAt":0,"ended":"yes"}"#] {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(SavedTerminalOutput.self, from: Data(json.utf8)) }
    }
    var restoration = WorkspaceRestoration()
    for record in [SavedTerminalOutput(text: "ok", capturedAt: Date(timeIntervalSince1970: .infinity), ended: false),
                   SavedTerminalOutput(text: String(repeating: "x", count: SavedTerminalOutput.maximumBytes + 1), capturedAt: Date(), ended: true),
                   SavedTerminalOutput(text: String(repeating: "x\n", count: 100_001), capturedAt: Date(), ended: false)] {
        restoration.terminalOutput = ["p1": record]
        #expect(throws: (any Error).self) { try restoration.validate(for: Workspace()) }
    }
    var workspace = Workspace()
    let full = SavedTerminalOutput(text: String(repeating: "x", count: SavedTerminalOutput.maximumBytes), capturedAt: Date(), ended: true)
    restoration.terminalOutput = ["p1": full]
    for _ in 0..<7 {
        let pane = try workspace.split(PaneID(1), direction: .right)
        restoration.terminalOutput[pane.description] = full
    }
    try restoration.validate(for: workspace)
    let overflow = try workspace.split(PaneID(1), direction: .right)
    restoration.terminalOutput[overflow.description] = SavedTerminalOutput(text: "x", capturedAt: Date(), ended: true)
    #expect(throws: (any Error).self) { try restoration.validate(for: workspace) }
}
