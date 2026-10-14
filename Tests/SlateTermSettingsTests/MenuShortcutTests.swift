import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func workspaceMenuActionsHaveDistinctDefaultShortcuts() throws {
    let bindings = AppConfiguration.defaults.keyBindings
    for id in CommandRegistry.commands.map(\.id) where !["pane.type", "pane.focus", "tab.focus"].contains(id) {
        #expect(bindings.values.contains(id), "Missing shortcut for \(id)")
    }
    #expect(bindings[try KeyChord.parse("cmd+alt+d")] == "split.left")
    #expect(bindings[try KeyChord.parse("cmd+alt+shift+d")] == "split.up")
    #expect(bindings[try KeyChord.parse("cmd+alt+left")] == "focus.left")
    #expect(bindings[try KeyChord.parse("cmd+alt+right")] == "focus.right")
    #expect(bindings[try KeyChord.parse("cmd+alt+up")] == "focus.up")
    #expect(bindings[try KeyChord.parse("cmd+alt+down")] == "focus.down")
    #expect(bindings[try KeyChord.parse("cmd+shift+e")] == "layout.equalize")
    #expect(bindings[try KeyChord.parse("cmd+shift+r")] == "config.reload")
    let customized = try AppConfiguration.parse("[keybind]\n'cmd+alt+left' = 'unbound'\n'cmd+shift+e' = 'split.left'")
    #expect(customized.keyBindings[try KeyChord.parse("cmd+alt+left")] == nil)
    #expect(customized.keyBindings[try KeyChord.parse("cmd+shift+e")] == "split.left")
}
