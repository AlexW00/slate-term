import CryptoKit
import Foundation
import SlateTermCore

/// The colors a terminal palette resolves to, as lowercase #rrggbb strings.
public struct TerminalColors: Equatable, Sendable, Encodable {
    public let background: String
    public let foreground: String
    public let cursor: String
    public let cursorText: String
    public let selectionBackground: String
    public let selectionForeground: String
    public let ansi: [String]

    /// Ghostty's built-in ANSI colors (terminal/color.zig), used for entries a palette leaves unset.
    static let defaultANSI = [
        "#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
        "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
    ]

    /// Takes the normalized keys produced by `TerminalPalette.parse`.
    /// Unset cursor and selection colors approximate Ghostty's inverted defaults.
    init(_ colors: [String: String]) {
        background = colors["background"]!
        foreground = colors["foreground"]!
        cursor = colors["cursor-color"] ?? foreground
        cursorText = colors["cursor-text"] ?? background
        selectionBackground = colors["selection-background"] ?? foreground
        selectionForeground = colors["selection-foreground"] ?? background
        ansi = (0..<16).map { colors["palette = \($0)"] ?? Self.defaultANSI[$0] }
    }

    /// Light when the background's WCAG relative luminance is above the
    /// point where black and white text have equal contrast.
    public var isLight: Bool {
        let value = Int(background.dropFirst(), radix: 16) ?? 0
        let channels = [value >> 16, (value >> 8) & 0xff, value & 0xff].map { channel -> Double in
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2] > 0.179
    }
}

/// The effective terminal appearance that plugins read through appearance.get.
public struct AppearanceSnapshot: Equatable, Sendable {
    public let setting: AppConfiguration.Theme
    /// Nil while light or dark is forced, because AppKit then reports the forced appearance.
    public let systemDark: Bool?
    public let darkSlot: Bool
    public let paletteName: String
    public let colors: TerminalColors
    public let fontFamily: String
    public let fontSize: Double
    public let minimumContrast: Double

    public init(configuration: AppConfiguration, systemDark: Bool?, darkSlot: Bool, colors: TerminalColors) {
        setting = configuration.theme
        self.systemDark = configuration.theme == .system ? systemDark : nil
        self.darkSlot = darkSlot
        paletteName = (darkSlot ? configuration.terminal.darkTheme : configuration.terminal.lightTheme).rawValue
        self.colors = colors
        fontFamily = configuration.terminal.fontFamily
        fontSize = configuration.terminal.fontSize
        minimumContrast = configuration.terminal.minimumContrast
    }

    public var tone: String { colors.isLight ? "light" : "dark" }
    public var slot: String { darkSlot ? "dark" : "light" }

    /// A content hash, so equal appearances share a revision and no-op applies keep it.
    public var revision: String {
        let fields = try! JSONEncoder.sorted.encode(content)
        return SHA256.hash(data: fields).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private var content: JSONValue {
        .object([
            "tone": .string(tone),
            "systemAppearance": systemDark.map { .string($0 ? "dark" : "light") } ?? .null,
            "setting": .string(setting.rawValue),
            "slot": .string(slot),
            "paletteName": .string(paletteName),
            "palette": .object([
                "background": .string(colors.background), "foreground": .string(colors.foreground),
                "cursor": .string(colors.cursor), "cursorText": .string(colors.cursorText),
                "selectionBackground": .string(colors.selectionBackground),
                "selectionForeground": .string(colors.selectionForeground),
                "ansi": .array(colors.ansi.map(JSONValue.string)),
            ]),
            "font": .object(["family": .string(fontFamily), "size": .number(fontSize)]),
            "minimumContrast": .number(minimumContrast),
        ])
    }

    /// The appearance.get result.
    public var json: JSONValue {
        guard case .object(var fields) = content else { return content }
        fields["revision"] = .string(revision)
        return .object(fields)
    }

    /// The host.appearance.changed payload. Clients re-read appearance.get.
    public var eventPayload: JSONValue {
        .object(["revision": .string(revision), "tone": .string(tone), "slot": .string(slot)])
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
