import Carbon
import Foundation

@main
nonisolated struct TerminalKeysChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func rejects(_ input: String, as expected: TerminalKeyError) throws {
        do {
            _ = try TerminalKey(parsing: input)
            throw Failure(description: "Accepted invalid chord: \(input.debugDescription)")
        } catch let error as TerminalKeyError {
            try require(error == expected, "\(input.debugDescription): expected \(expected), got \(error)")
            try require(error.errorDescription?.isEmpty == false, "Missing localized error")
        }
    }

    static func main() async throws {
        // Carbon constants independently check every mapping against the active SDK.
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
            ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
            ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
            ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z)
        ]
        let digits: [(String, Int, String)] = [
            ("0", kVK_ANSI_0, ")"), ("1", kVK_ANSI_1, "!"), ("2", kVK_ANSI_2, "@"),
            ("3", kVK_ANSI_3, "#"), ("4", kVK_ANSI_4, "$"), ("5", kVK_ANSI_5, "%"),
            ("6", kVK_ANSI_6, "^"), ("7", kVK_ANSI_7, "&"), ("8", kVK_ANSI_8, "*"),
            ("9", kVK_ANSI_9, "(")
        ]
        let punctuation: [(String, Int, String, String)] = [
            ("minus", kVK_ANSI_Minus, "-", "_"), ("equal", kVK_ANSI_Equal, "=", "+"),
            ("left-bracket", kVK_ANSI_LeftBracket, "[", "{"),
            ("right-bracket", kVK_ANSI_RightBracket, "]", "}"),
            ("semicolon", kVK_ANSI_Semicolon, ";", ":"), ("quote", kVK_ANSI_Quote, "'", "\""),
            ("backslash", kVK_ANSI_Backslash, "\\", "|"), ("comma", kVK_ANSI_Comma, ",", "<"),
            ("period", kVK_ANSI_Period, ".", ">"), ("slash", kVK_ANSI_Slash, "/", "?"),
            ("backtick", kVK_ANSI_Grave, "`", "~")
        ]
        let nonprinting: [(String, Int, UInt32)] = [
            ("enter", kVK_Return, 13), ("tab", kVK_Tab, 9), ("escape", kVK_Escape, 27),
            ("backspace", kVK_Delete, 127), ("delete", kVK_ForwardDelete, 0),
            // Ghostty's pinned macOS map calls Carbon Help/Insert the Insert key.
            ("insert", kVK_Help, 0), ("home", kVK_Home, 0), ("end", kVK_End, 0),
            ("pageup", kVK_PageUp, 0), ("pagedown", kVK_PageDown, 0),
            ("up", kVK_UpArrow, 0), ("down", kVK_DownArrow, 0),
            ("left", kVK_LeftArrow, 0), ("right", kVK_RightArrow, 0),
            ("f1", kVK_F1, 0), ("f2", kVK_F2, 0), ("f3", kVK_F3, 0),
            ("f4", kVK_F4, 0), ("f5", kVK_F5, 0), ("f6", kVK_F6, 0),
            ("f7", kVK_F7, 0), ("f8", kVK_F8, 0), ("f9", kVK_F9, 0),
            ("f10", kVK_F10, 0), ("f11", kVK_F11, 0), ("f12", kVK_F12, 0)
        ]
        let printable = letters.map { ($0.0, $0.1, $0.0, $0.0.uppercased()) }
            + digits.map { ($0.0, $0.1, $0.0, $0.2) } + punctuation
            + [("space", kVK_Space, " ", " ")]
        let fixtures: [(String, Int, UInt32, String?, String?)] = printable.map {
            ($0.0, $0.1, $0.2.unicodeScalars.first!.value, $0.2, $0.3)
        } + nonprinting.map { ($0.0, $0.1, $0.2, nil, nil) }
        let combinations: [(String, Set<TerminalKey.Modifier>)] = [
            ("", []), ("ctrl+", [.ctrl]), ("alt+", [.alt]), ("shift+", [.shift]),
            ("ctrl+alt+", [.ctrl, .alt]), ("ctrl+shift+", [.ctrl, .shift]),
            ("alt+shift+", [.alt, .shift]), ("ctrl+alt+shift+", [.ctrl, .alt, .shift])
        ]
        for (name, code, base, plain, shifted) in fixtures {
            for (prefix, modifiers) in combinations {
                let chord = prefix + name
                let key = try TerminalKey(parsing: chord)
                let text = modifiers.contains(.shift) ? shifted : plain
                try require(key.keyCode == UInt32(code), "\(chord): Carbon keycode")
                try require(key.unshiftedCodepoint == base, "\(chord): base codepoint")
                try require(key.text == text, "\(chord): printable US text")
                try require(key.modifiers == modifiers, "\(chord): modifiers")
                let consumed: Set<TerminalKey.Modifier> = modifiers.contains(.shift) && shifted != plain ? [.shift] : []
                try require(key.consumedModifiers == consumed, "\(chord): consumed modifiers")
                try require(try TerminalKey(parsing: chord.uppercased()) == key, "\(chord): case independence")
            }
        }
        let canonical = try TerminalKey(parsing: "ctrl+alt+shift+a")
        for permutation in ["ctrl+shift+alt+a", "alt+ctrl+shift+a", "alt+shift+ctrl+a",
                            "shift+ctrl+alt+a", "shift+alt+ctrl+a"] {
            try require(try TerminalKey(parsing: permutation) == canonical, "Modifier order: \(permutation)")
        }
        try rejects("", as: .empty)
        for input in ["+a", "ctrl++a", "ctrl+", "a+", "ctrl+alt+", " a", "a ", "ctrl +a",
                      "a\n", "a\r", "a\t", "\0", "\u{1B}", "\u{7F}", "é", "日本語", "Ａ", "a\u{301}"] {
            try rejects(input, as: .invalidSyntax)
        }
        for modifier in ["ctrl", "alt", "shift"] {
            try rejects("\(modifier)+\(modifier.uppercased())+a", as: .duplicateModifier(modifier))
        }
        for modifier in ["cmd", "command", "super", "meta", "control", "option", "fn", "caps", "a"] {
            try rejects("\(modifier)+a", as: .unknownModifier(modifier))
        }
        for name in ["ctrl", "alt", "shift", "cmd", "super", "return", "esc", "f0", "f13", "f01",
                     "page-up", "pgdn", "aa", "1a", "😀", "-", "=", "[", "]", ";", "'", "\\", ",", ".", "/", "`", "?", "A B"] {
            let expected: TerminalKeyError = name.utf8.allSatisfy { (0x21...0x7E).contains($0) }
                ? .unknownKey(name.lowercased()) : .invalidSyntax
            try rejects(name, as: expected)
        }
        try rejects(String(repeating: "a", count: 128), as: .unknownKey(String(repeating: "a", count: 128)))
        try rejects(String(repeating: "a", count: 129), as: .tooLong)
        try rejects(String(repeating: "é", count: 64), as: .invalidSyntax)
        try rejects(String(repeating: "é", count: 65), as: .tooLong)
        // Parsing and value transport must remain usable outside MainActor default isolation.
        let detached = try await Task.detached { try TerminalKey(parsing: "CtRl+AlT+ShIfT+A") }.value
        try require(detached == canonical, "Nonisolated Sendable parser")
        print("PASS terminal keys: \(fixtures.count) SDK mappings × \(combinations.count) modifier sets; grammar, UTF-8 bounds, detached parsing")
    }
}
