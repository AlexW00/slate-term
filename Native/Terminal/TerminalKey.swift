import Foundation

/// A logical US-ASCII terminal key, independent of the active layout or IME.
/// Parse named punctuation (e.g. shift+equal), not literal symbols or text entry.
nonisolated struct TerminalKey: Sendable, Equatable {
    enum Modifier: String, Sendable, Hashable {
        case ctrl, alt, shift
    }

    let keyCode: UInt32
    let unshiftedCodepoint: UInt32
    let text: String?
    let modifiers: Set<Modifier>
    let consumedModifiers: Set<Modifier>

    /// One key preceded by unique ctrl/alt/shift modifiers, in any order.
    /// Case is insignificant; whitespace, controls, aliases and symbols are not accepted.
    init(parsing input: String) throws {
        guard input.utf8.count <= 128 else { throw TerminalKeyError.tooLong }
        guard !input.isEmpty else { throw TerminalKeyError.empty }
        guard input.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw TerminalKeyError.invalidSyntax
        }
        let parts = input.lowercased().split(separator: "+", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty }), let last = parts.last else {
            throw TerminalKeyError.invalidSyntax
        }
        var modifiers = Set<Modifier>()
        for part in parts.dropLast() {
            guard let modifier = Modifier(rawValue: String(part)) else {
                throw TerminalKeyError.unknownModifier(String(part))
            }
            guard modifiers.insert(modifier).inserted else {
                throw TerminalKeyError.duplicateModifier(String(part))
            }
        }
        let name = String(last)
        if let mapping = Self.printable[name] {
            keyCode = mapping.code
            unshiftedCodepoint = UInt32(mapping.plain.utf8.first!)
            text = modifiers.contains(.shift) ? mapping.shifted : mapping.plain
            consumedModifiers = modifiers.contains(.shift) && mapping.shifted != mapping.plain ? [.shift] : []
        } else if let mapping = Self.nonprinting[name] {
            keyCode = mapping.code
            unshiftedCodepoint = mapping.base
            text = nil
            consumedModifiers = []
        } else {
            throw TerminalKeyError.unknownKey(name)
        }
        self.modifiers = modifiers
    }

    // Physical codes verified against the local macOS SDK HIToolbox/Events.h.
    // Keep Carbon out of the parser; the standalone checks compare all codes to SDK constants.
    private static let printable: [String: (code: UInt32, plain: String, shifted: String)] = [
        "a": (0x00, "a", "A"), "b": (0x0B, "b", "B"), "c": (0x08, "c", "C"),
        "d": (0x02, "d", "D"), "e": (0x0E, "e", "E"), "f": (0x03, "f", "F"),
        "g": (0x05, "g", "G"), "h": (0x04, "h", "H"), "i": (0x22, "i", "I"),
        "j": (0x26, "j", "J"), "k": (0x28, "k", "K"), "l": (0x25, "l", "L"),
        "m": (0x2E, "m", "M"), "n": (0x2D, "n", "N"), "o": (0x1F, "o", "O"),
        "p": (0x23, "p", "P"), "q": (0x0C, "q", "Q"), "r": (0x0F, "r", "R"),
        "s": (0x01, "s", "S"), "t": (0x11, "t", "T"), "u": (0x20, "u", "U"),
        "v": (0x09, "v", "V"), "w": (0x0D, "w", "W"), "x": (0x07, "x", "X"),
        "y": (0x10, "y", "Y"), "z": (0x06, "z", "Z"),
        "0": (0x1D, "0", ")"), "1": (0x12, "1", "!"), "2": (0x13, "2", "@"),
        "3": (0x14, "3", "#"), "4": (0x15, "4", "$"), "5": (0x17, "5", "%"),
        "6": (0x16, "6", "^"), "7": (0x1A, "7", "&"), "8": (0x1C, "8", "*"),
        "9": (0x19, "9", "("), "space": (0x31, " ", " "),
        "minus": (0x1B, "-", "_"), "equal": (0x18, "=", "+"),
        "left-bracket": (0x21, "[", "{"), "right-bracket": (0x1E, "]", "}"),
        "semicolon": (0x29, ";", ":"), "quote": (0x27, "'", "\""),
        "backslash": (0x2A, "\\", "|"), "comma": (0x2B, ",", "<"),
        "period": (0x2F, ".", ">"), "slash": (0x2C, "/", "?"), "backtick": (0x32, "`", "~")
    ]

    private static let nonprinting: [String: (code: UInt32, base: UInt32)] = [
        "enter": (0x24, 13), "tab": (0x30, 9), "escape": (0x35, 27), "backspace": (0x33, 127),
        "delete": (0x75, 0),
        // Carbon calls 0x72 Help; the pinned Ghostty macOS keycode table maps it to Insert.
        "insert": (0x72, 0), "home": (0x73, 0), "end": (0x77, 0),
        "pageup": (0x74, 0), "pagedown": (0x79, 0),
        "up": (0x7E, 0), "down": (0x7D, 0), "left": (0x7B, 0), "right": (0x7C, 0),
        "f1": (0x7A, 0), "f2": (0x78, 0), "f3": (0x63, 0), "f4": (0x76, 0),
        "f5": (0x60, 0), "f6": (0x61, 0), "f7": (0x62, 0), "f8": (0x64, 0),
        "f9": (0x65, 0), "f10": (0x6D, 0), "f11": (0x67, 0), "f12": (0x6F, 0)
    ]
}

nonisolated enum TerminalKeyError: Error, LocalizedError, Sendable, Equatable {
    case empty
    case tooLong
    case invalidSyntax
    case unknownModifier(String)
    case duplicateModifier(String)
    case unknownKey(String)
    case closed
    case rejected

    var errorDescription: String? {
        switch self {
        case .empty: "A terminal key is required"
        case .tooLong: "A terminal key chord must not exceed 128 UTF-8 bytes"
        case .invalidSyntax: "Use one named terminal key with optional ctrl+alt+shift modifiers; no whitespace or controls"
        case .unknownModifier(let name): "Unsupported terminal modifier '\(name)'; use ctrl, alt or shift (workspace commands use the command registry)"
        case .duplicateModifier(let name): "Terminal modifier '\(name)' must appear only once"
        case .unknownKey(let name): "Unsupported terminal key '\(name)'; use a letter, digit or supported key name"
        case .closed: "The terminal is closed"
        case .rejected: "The terminal engine did not accept the key press"
        }
    }
}
