import ArgumentParser
import Testing
@testable import SlateTermCLI

@Test func firstPassCLIAliasesParseTypedInputs() throws {
    let frame = try WindowsCLI.parse(["frame", "--window-id", "window-a", "--x", "20", "--y", "30", "--width", "900", "--height", "600"])
    #expect(frame.action == .frame && frame.width == 900)
    #expect(try WindowsCLI.parse(["fullscreen", "--window-id", "window-a", "--enabled", "false"]).enabled == false)
    #expect(try WarningsCLI.parse(["close", "--suppressed", "true"]).suppressed)
    #expect(throws: (any Error).self) { try WarningsCLI.parse(["type", "--suppressed", "1"]) }
    let value = try WebCLI.parse(["set-value", "--pane", "p1", "--ref", "v:d:1", "--value", "2026-10-16"])
    #expect(value.action.method == "web.setValue" && value.value == ["2026-10-16"])
    #expect(try WebCLI.parse(["check", "--pane", "p1", "--ref", "v:d:1", "--checked", "false"]).checked == false)
    #expect(try WebCLI.parse(["key", "--pane", "p1", "--ref", "v:d:1", "--key", "shift+tab"]).key == "shift+tab")
}

@Test func windowCLIRejectsUnrelatedPayloadBeforeConnecting() throws {
    for arguments in [["get", "--window-id", "w", "--width", "200"], ["restore", "--window-id", "w", "--activate"],
                      ["frame", "--window-id", "w", "--width", "200"], ["fullscreen", "--window-id", "w"],
                      ["minimize", "--window-id", "w", "--enabled", "true"]] {
        var command = try WindowsCLI.parse(arguments)
        #expect(throws: ValidationError.self) { try command.run() }
    }
}
