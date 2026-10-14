import CryptoKit
import Darwin
import Foundation

extension AppConfiguration {
    public enum BundledTerminalTheme: String, Codable, CaseIterable, Sendable {
        case builtinLight = "Builtin Light", builtinDark = "Builtin Dark"
        case catppuccinLatte = "Catppuccin Latte", catppuccinMocha = "Catppuccin Mocha"
        case catppuccinFrappe = "Catppuccin Frappe", catppuccinMacchiato = "Catppuccin Macchiato"
        case solarizedLight = "iTerm2 Solarized Light", solarizedDark = "iTerm2 Solarized Dark"
        case dracula = "Dracula", nord = "Nord", nordLight = "Nord Light"
        case gruvboxLight = "Gruvbox Light", gruvboxDark = "Gruvbox Dark"
        case tokyoNight = "TokyoNight", tokyoNightDay = "TokyoNight Day"
        case atomOneLight = "Atom One Light", atomOneDark = "Atom One Dark"
        case githubLight = "GitHub Light Default", githubDark = "GitHub Dark Default"
        case rosePine = "Rose Pine", rosePineDawn = "Rose Pine Dawn"
        case ayuLight = "Ayu Light", ayuMirage = "Ayu Mirage"
        case everforestLight = "Everforest Light Med", everforestDark = "Everforest Dark Med"
    }

    public struct TerminalTheme: Hashable, Sendable, Codable {
        public let rawValue: String
        public var bundled: BundledTerminalTheme? { BundledTerminalTheme(rawValue: rawValue) }

        public init(_ theme: BundledTerminalTheme) { rawValue = theme.rawValue }

        public init(parsing value: String) throws {
            guard !value.isEmpty, value.utf8.count <= 128,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  value.unicodeScalars.first != ".", value.unicodeScalars.first != "~", !value.lowercased().hasSuffix(".conf"),
                  !value.unicodeScalars.contains(where: {
                      $0 == "/" || $0 == "\\" || $0 == ":" || CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
                  }) else {
                throw ConfigurationError.invalid("Use a palette name without a path or .conf extension (maximum 128 UTF-8 bytes)")
            }
            rawValue = value
        }

        public init(from decoder: any Decoder) throws {
            do { try self.init(parsing: decoder.singleValueContainer().decode(String.self)) }
            catch {
                throw ConfigurationError.invalid("\(decoder.codingPath.map(\.stringValue).joined(separator: ".")): \(error)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        fileprivate func resolve(directory: URL) throws -> ResolvedTerminalPalette {
            if let bundled { return .bundled(bundled) }
            let file = directory.appendingPathComponent(rawValue + ".conf")
            do { return .custom(try TerminalPalette.load(from: file)) }
            catch let error as POSIXError where error.code == .ENOENT {
                throw ConfigurationError.invalid("Palette ‘\(rawValue)’ was not found. Add \(rawValue).conf to the palettes folder beside config.toml, or select another palette.")
            } catch let error as ConfigurationError {
                throw ConfigurationError.invalid("Could not load palette ‘\(rawValue)’: \(error)")
            } catch {
                throw ConfigurationError.invalid("Could not read palette ‘\(rawValue)’: \(error.localizedDescription)")
            }
        }
    }
}

public struct ResolvedTerminalPalettes: Sendable {
    fileprivate let light: ResolvedTerminalPalette
    fileprivate let dark: ResolvedTerminalPalette

    func engineValue(directory: URL, bundledDirectory: URL) throws -> String {
        "light:\(try light.engineValue(directory: directory, bundledDirectory: bundledDirectory)),dark:\(try dark.engineValue(directory: directory, bundledDirectory: bundledDirectory))"
    }
}

extension AppConfiguration.Terminal {
    public func resolvePalettes(directory: URL) throws -> ResolvedTerminalPalettes {
        // Parse both before writing any snapshots, including the inactive mode.
        try ResolvedTerminalPalettes(light: lightTheme.resolve(directory: directory), dark: darkTheme.resolve(directory: directory))
    }
}

private enum ResolvedTerminalPalette: Sendable {
    case bundled(AppConfiguration.BundledTerminalTheme)
    case custom(TerminalPalette)

    func engineValue(directory: URL, bundledDirectory: URL) throws -> String {
        let file: URL
        switch self {
        // Bare names let Ghostty's user-theme directory shadow bundled themes.
        // Only use the app's trusted resource path for these selections.
        case .bundled(let theme): file = bundledDirectory.appendingPathComponent(theme.rawValue)
        case .custom(let palette):
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let digest = SHA256.hash(data: Data(palette.source.utf8)).map { String(format: "%02x", $0) }.joined()
            file = directory.appendingPathComponent("\(digest).conf")
            // Content-addressed snapshots keep previous runtime configs stable
            // across rejected reloads and later light/dark switches. Never pass
            // the original file to Ghostty: theme files can set non-color options.
            try palette.source.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        var quoted = "\""
        for scalar in file.path.unicodeScalars {
            switch scalar.value {
            case 0x22: quoted += "\\\""
            case 0x5c: quoted += "\\\\"
            case 0...0x1f, 0x7f: quoted += String(format: "\\x%02x", scalar.value)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}

/// A bounded, color-only subset of Ghostty's theme format. Construction always
/// parses and normalizes values; raw file contents never reach the engine.
public struct TerminalPalette: Equatable, Sendable {
    public let source: String
    private init(source: String) { self.source = source }
    private static let maximumBytes = 65_536
    private static let colorKeys: Set<String> = [
        "background", "foreground", "cursor-color", "cursor-text", "selection-background", "selection-foreground",
    ]

    public static func load(from url: URL, followingSymbolicLinks: Bool = true) throws -> TerminalPalette {
        // O_NONBLOCK prevents a FIFO/device path from hanging the settings UI.
        // fstat checks the opened descriptor, not a potentially replaced path.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followingSymbolicLinks ? 0 : O_NOFOLLOW))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            throw ConfigurationError.invalid("Palette must be a regular file")
        }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes, let source = String(data: data, encoding: .utf8) else {
            throw ConfigurationError.invalid("Palette must be UTF-8 and at most 64 KiB")
        }
        return try parse(source)
    }

    public static func parse(_ source: String) throws -> TerminalPalette {
        guard source.utf8.count <= maximumBytes else { throw ConfigurationError.invalid("Palette exceeds 64 KiB") }
        var colors: [String: String] = [:]
        for (index, rawLine) in source.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            func invalid(_ message: String) -> ConfigurationError { .invalid("Palette line \(index + 1): \(message)") }
            guard let equal = line.firstIndex(of: "=") else { throw invalid("Expected color = #RRGGBB") }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            let identity: String
            if key == "palette" {
                guard let separator = value.firstIndex(of: "="),
                      let number = Int(value[..<separator].trimmingCharacters(in: .whitespaces)), (0...255).contains(number) else {
                    throw invalid("Palette entries must use palette = 0...255=#RRGGBB")
                }
                identity = "palette = \(number)"
                value = value[value.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            } else {
                guard colorKeys.contains(key) else { throw invalid("Unsupported color setting '\(key)'") }
                identity = key
            }
            if value.hasPrefix("#") { value.removeFirst() }
            guard value.utf8.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw invalid("Colors must be six hexadecimal digits, optionally prefixed by #")
            }
            guard colors.updateValue("#" + value.lowercased(), forKey: identity) == nil else {
                throw invalid("Duplicate color setting '\(identity)'")
            }
        }
        guard colors["background"] != nil, colors["foreground"] != nil else {
            throw ConfigurationError.invalid("Palette must define background and foreground")
        }
        return TerminalPalette(source: colors.keys.sorted().map { key in
            key + (key.hasPrefix("palette = ") ? "=" : " = ") + colors[key]!
        }.joined(separator: "\n") + "\n")
    }
}
