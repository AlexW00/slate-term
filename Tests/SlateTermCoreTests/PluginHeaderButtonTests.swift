import Foundation
import Testing
@testable import SlateTermCore

private func headerPlugin(_ buttons: [[String: Any]]) throws -> PluginRegistration {
    try PluginRegistration.parse(JSONSerialization.data(withJSONObject: [
        "id": "tools", "title": "Tools",
        "commands": [["id": "inspect", "title": "Inspect", "executable": "/bin/echo"]],
        "headerButtons": buttons,
    ]))
}
private let headerButton: [String: String] = ["id": "inspect", "title": "Inspect Pane", "symbol": "info.circle", "command": "inspect"]

@Test func headerButtonsMatchAllBuiltinsAndPluginTypesAndRoundtrip() throws {
    let all = try headerPlugin([headerButton])
    #expect(!all.hasPanel)
    #expect(all.headerButtons[0].paneTypes == ["*"])
    #expect(all.headerButtons[0].matches(paneType: "terminal"))
    #expect(all.headerButtons[0].matches(paneType: "acme.notes"))
    #expect(all.headerButtons[0].namespacedID(plugin: all.id) == "plugin.tools.header.inspect")
    #expect(try PluginRegistration.parse(JSONEncoder().encode(all)) == all)
    var specific: [String: Any] = headerButton
    specific["paneTypes"] = ["terminal", "acme.notes"]
    let button = try headerPlugin([specific]).headerButtons[0]
    #expect(button.matches(paneType: "terminal"))
    #expect(button.matches(paneType: "acme.notes"))
    #expect(!button.matches(paneType: "browser"))
    #expect(!button.matches(paneType: "notes"))
}

@Test func headerButtonsRejectAmbiguousInvalidOrUnownedContributions() throws {
    for (key, value) in [
        ("id", "a.b" as Any), ("id", "Bad"), ("id", String(repeating: "a", count: 65)),
        ("title", " "), ("title", "New\nline"), ("title", String(repeating: "a", count: 101)),
        ("symbol", ""), ("symbol", "<img>"), ("symbol", String(repeating: "a", count: 129)),
        ("command", "missing"), ("command", "plugin.other.inspect"), ("command", "pane.copyID"),
        ("paneTypes", [] as [String]), ("paneTypes", ["*", "terminal"]), ("paneTypes", ["terminal", "terminal"]),
        ("paneTypes", ["Terminal"]), ("paneTypes", ["bad..type"]), ("paneTypes", "terminal"),
        ("paneTypes", (0..<33).map { "type\($0)" }), ("callback", "javascript:alert(1)"),
    ] {
        var invalid: [String: Any] = headerButton
        invalid[key] = value
        #expect(throws: (any Error).self) { try headerPlugin([invalid]) }
    }
    #expect(throws: (any Error).self) { try headerPlugin([headerButton, headerButton]) }
    let many: [[String: Any]] = (0..<9).map { index in
        var button: [String: Any] = headerButton
        button["id"] = "action\(index)"
        return button
    }
    #expect(throws: (any Error).self) { try headerPlugin(many) }
    #expect(try headerPlugin(Array(many.prefix(8))).headerButtons.count == 8)
}
