import ArgumentParser
import Testing
@testable import SlateTermCLI

@Test func fileChooserCLIAliasesCarryExplicitSelection() throws {
    let select = try WebCLI.parse(["choose-files", "--pane", "p1", "--chooser-id", "chooser",
                                  "--file", "/tmp/a", "--file", "/tmp/b"])
    #expect(select.action.method == "web.chooseFiles")
    #expect(select.chooserId == "chooser" && select.file == ["/tmp/a", "/tmp/b"])
    #expect(try WebCLI.parse(["file-chooser", "--pane", "p1"]).action.method == "web.fileChooser")
    #expect(try WebCLI.parse(["cancel-file-chooser", "--pane", "p1", "--chooser-id", "chooser"]).action.method == "web.cancelFileChooser")
}

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

@Test func browserCompletionAliasesCarryResourceIdentities() throws {
    let response = try WebCLI.parse(["respond-dialog", "--pane", "p1", "--popup-id", "popup", "--dialog-id", "dialog", "--response", "accept", "--text", ""])
    #expect(response.action.method == "web.respondDialog" && response.popupId == "popup" && response.text == "")
    let save = try BrowserCommand.parse(["save-download", "--pane", "p1", "--download-id", "download", "--path", "/tmp/result"])
    #expect(save.action.method == "browser.saveDownload" && save.downloadId == "download")
    #expect(try BrowserCommand.parse(["close-popup", "--pane", "p1", "--popup-id", "popup"]).action.method == "browser.closePopup")
    #expect(try BrowserCommand.parse(["show-downloads", "--pane", "p1"]).action.method == "browser.showDownloads")
}
