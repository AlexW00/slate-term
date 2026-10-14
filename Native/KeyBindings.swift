import AppKit
import SlateTermSettings

extension KeyChord {
    var nativeKey: String { keyEquivalent }
    var nativeModifiers: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if modifiers.contains(.cmd) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.alt) { result.insert(.option) }
        if modifiers.contains(.ctrl) { result.insert(.control) }
        return result
    }

    var displayLabel: String {
        let prefix = (modifiers.contains(.ctrl) ? "⌃" : "") + (modifiers.contains(.alt) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.cmd) ? "⌘" : "")
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↵", "escape": "⎋", "tab": "⇥", "space": "Space", "plus": "+"]
        return prefix + (names[key] ?? key.uppercased())
    }

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags == nativeModifiers else { return false }
        // AppKit control events can carry control characters, while its
        // charactersIgnoringModifiers still includes shifted punctuation.
        return event.charactersIgnoringModifiers?.lowercased() == nativeKey
            || event.characters(byApplyingModifiers: [])?.lowercased() == nativeKey
    }
}
