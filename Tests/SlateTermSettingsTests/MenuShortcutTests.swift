import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func workspaceMenuActionsHaveDistinctDefaultShortcuts() throws {
    let bindings = AppConfiguration.defaults.keyBindings
    for command in CommandRegistry.commands {
        #expect(bindings.values.contains(command.id) == !command.key.isEmpty,
                "Default shortcut contract differs for \(command.id)")
    }
    #expect(bindings[try KeyChord.parse("cmd+alt+d")] == "split.left")
    #expect(bindings[try KeyChord.parse("cmd+alt+shift+d")] == "split.up")
    #expect(bindings[try KeyChord.parse("cmd+alt+left")] == "focus.left")
    #expect(bindings[try KeyChord.parse("cmd+alt+right")] == "focus.right")
    #expect(bindings[try KeyChord.parse("cmd+alt+up")] == "focus.up")
    #expect(bindings[try KeyChord.parse("cmd+alt+down")] == "focus.down")
    #expect(bindings[try KeyChord.parse("cmd+shift+e")] == "layout.equalize")
    #expect(bindings[try KeyChord.parse("cmd+shift+r")] == "config.reload")
    #expect(bindings[try KeyChord.parse("ctrl+cmd+n")] == "tab.detachCurrent")
    let noDetachShortcut = try AppConfiguration.parse("[keybind]\n'ctrl+cmd+n' = 'unbound'")
    #expect(noDetachShortcut.keyBindings[try KeyChord.parse("ctrl+cmd+n")] == nil)
    #expect(noDetachShortcut.keyBindings[try KeyChord.parse("cmd+n")] == "window.new")
    #expect(!bindings.values.contains("pane.rename"))
    let rename = try #require(CommandRegistry.commands.first { $0.id == "pane.rename" })
    #expect(!rename.contract.requiresArguments && !rename.contract.workspaceIndependent)
    let renameBinding = try AppConfiguration.parse("[keybind]\n'cmd+shift+r' = 'pane.rename'")
    #expect(renameBinding.keyBindings[try KeyChord.parse("cmd+shift+r")] == "pane.rename")
    #expect(bindings[try KeyChord.parse("cmd+shift+return")] == "pane.zoom")
    #expect(!bindings.values.contains("pane.copyID"))
    let copyBinding = try AppConfiguration.parse("[keybind]\n'cmd+shift+i' = 'pane.copyID'")
    #expect(copyBinding.keyBindings[try KeyChord.parse("cmd+shift+i")] == "pane.copyID")
    let appearanceBinding = try AppConfiguration.parse("[keybind]\n'cmd+shift+l' = 'appearance.light'")
    #expect(appearanceBinding.keyBindings[try KeyChord.parse("cmd+shift+l")] == "appearance.light")
    #expect(!bindings.values.contains("terminal.font.increase"), "Application font commands must not steal pane-local zoom chords")
    let customized = try AppConfiguration.parse("[keybind]\n'cmd+alt+left' = 'unbound'\n'cmd+shift+e' = 'split.left'")
    #expect(customized.keyBindings[try KeyChord.parse("cmd+alt+left")] == nil)
    #expect(customized.keyBindings[try KeyChord.parse("cmd+shift+e")] == "split.left")
}
