import Darwin
import Foundation
import SlateTermCore
import TOMLDecoder

public enum ConfigurationError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): message } }
}

public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public enum Modifier: String, CaseIterable, Sendable { case cmd, shift, alt, ctrl }
    public let modifiers: Set<Modifier>
    public let key: String
    public var keyEquivalent: String { Self.namedKeys[key] ?? key }
    private static let namedKeys = ["left": "\u{f702}", "right": "\u{f703}", "up": "\u{f700}", "down": "\u{f701}",
                                    "return": "\r", "escape": "\u{1b}", "tab": "\t", "space": " ", "plus": "+"]
    public var description: String {
        (Modifier.allCases.filter { modifiers.contains($0) }.map(\.rawValue) + [key]).joined(separator: "+")
    }

    public static func parse(_ source: String) throws -> KeyChord {
        let parts = source.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let rawKey = parts.last ?? ""
        let key = namedKeys.first(where: { $0.value == rawKey })?.key ?? rawKey
        let literal = key.unicodeScalars.count == 1 && !key.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }
        guard literal || namedKeys[key] != nil else { throw ConfigurationError.invalid("Invalid keybinding: \(source)") }
        var modifiers = Set<Modifier>()
        for part in parts.dropLast() {
            guard let modifier = Modifier(rawValue: part), modifiers.insert(modifier).inserted else {
                throw ConfigurationError.invalid("Unknown or duplicate modifier in keybinding: \(source)")
            }
        }
        return KeyChord(modifiers: modifiers, key: key)
    }
}

public struct AppConfiguration: Equatable, Sendable, Encodable {
    public enum Theme: String, Codable, Sendable {
        case system, light, dark
        public init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let theme = Self(rawValue: value == "auto" ? "system" : value) else {
                throw ConfigurationError.invalid("appearance.theme must be auto, system, light, or dark")
            }
            self = theme
        }
    }
    public enum ShellIntegration: String, Codable, Sendable { case auto, off }
    public enum CursorStyle: String, Codable, CaseIterable, Sendable { case block, bar, underline, blockHollow = "block_hollow" }
    public enum CursorBlink: String, Codable, Sendable { case auto, on, off }
    public struct Terminal: Equatable, Sendable, Encodable {
        public let shell: String
        public let workingDirectory: String
        public let inheritWorkingDirectory: Bool
        /// Latest output lines retained across launches; zero disables saving output.
        public let savedOutputLines: Int
        public let fontFamily: String
        /// Typographic points. Slate Terminal accepts finite sizes in 1...256.
        public let fontSize: Double
        public let shellIntegration: ShellIntegration
        public let fontThicken: Bool
        /// WCAG contrast ratio, from 1 (unchanged) to 21.
        public let minimumContrast: Double
        public let cursorStyle: CursorStyle
        public let cursorBlink: CursorBlink
        /// Symmetric padding in points; Slate Terminal accepts integers in 0...64.
        public let paddingX: Int
        public let paddingY: Int
        public let lightTheme: TerminalTheme
        public let darkTheme: TerminalTheme
        enum CodingKeys: String, CodingKey {
            case workingDirectory = "working_directory", inheritWorkingDirectory = "inherit_working_directory"
            case savedOutputLines = "saved_output_lines"
            case shell, fontFamily = "font_family", fontSize = "font_size", shellIntegration = "shell_integration"
            case fontThicken = "font_thicken", minimumContrast = "minimum_contrast"
            case cursorStyle = "cursor_style", cursorBlink = "cursor_blink"
            case paddingX = "padding_x", paddingY = "padding_y", lightTheme = "light_theme", darkTheme = "dark_theme"
        }

        /// Resolve a split's observed directory before the configured default, then home.
        public func startingDirectory(inheriting directory: String?) -> String {
            let fallback = (workingDirectory as NSString).expandingTildeInPath
            for candidate in [inheritWorkingDirectory ? directory : nil, fallback].compactMap({ $0 }) {
                var isDirectory: ObjCBool = false
                guard candidate.hasPrefix("/"), !candidate.utf8.contains(0),
                      FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue,
                      FileManager.default.isExecutableFile(atPath: candidate) else { continue }
                return candidate
            }
            return NSHomeDirectory()
        }

        /// Only rendering options: shell command and integration remain app-owned.
        public func renderingConfiguration(palettes: ResolvedTerminalPalettes, directory: URL, bundledDirectory: URL) throws -> String {
            let blink = switch cursorBlink { case .auto: ""; case .on: "true"; case .off: "false" }
            return """
            font-family = \(fontFamily)
            font-size = \(fontSize)
            font-thicken = \(fontThicken)
            minimum-contrast = \(minimumContrast)
            cursor-style = \(cursorStyle.rawValue)
            cursor-style-blink = \(blink)
            window-padding-x = \(paddingX)
            window-padding-y = \(paddingY)
            theme = \(try palettes.engineValue(directory: directory, bundledDirectory: bundledDirectory))
            """
        }
    }
    public struct Browser: Equatable, Sendable, Encodable {
        public let searchURL: String
        enum CodingKeys: String, CodingKey { case searchURL = "search_url" }

        fileprivate init(searchURL: String) { self.searchURL = searchURL }

        fileprivate static func parse(_ template: String) throws -> Browser {
            let sample = template.replacingOccurrences(of: "{query}", with: "slate-search")
            guard template.contains("{query}"),
                  !template.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
                  let url = URL(string: sample), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  let authority = template.components(separatedBy: "://").dropFirst().first?.split(whereSeparator: { "/?#".contains($0) }).first,
                  !authority.contains("{query}") else {
                throw ConfigurationError.invalid("browser.search_url must be an HTTP or HTTPS URL with {query} in its path or query, and no credentials")
            }
            return Browser(searchURL: template)
        }

        public func addressURL(for text: String) throws -> URL {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw ConfigurationError.invalid("Enter a URL or search term") }
            let hasScheme = value.contains("://") || value.hasPrefix("about:") || value.lowercased().hasPrefix("file:")
            if value.hasPrefix("/") || value.hasPrefix("~/") { return try BrowserURL.parse(value) }
            let host = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
            let looksLikeAddress = !value.contains(where: { $0.isWhitespace }) &&
                (host.contains(".") || host == "localhost" || host.hasPrefix("localhost:") || host.hasPrefix("["))
            if hasScheme || looksLikeAddress {
                return try BrowserURL.parse(value, assumingHTTPS: true)
            }
            let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            guard let query = value.addingPercentEncoding(withAllowedCharacters: unreserved),
                  let url = URL(string: searchURL.replacingOccurrences(of: "{query}", with: query)) else {
                throw ConfigurationError.invalid("Could not create a search URL")
            }
            return url
        }
    }
    public let browser: Browser
    public let theme: Theme
    public var unfocusedPaneDim: Double = 0.08
    public let terminal: Terminal
    public let restoreWorkspace: Bool
    public let keyBindings: [KeyChord: String]
    public var plugins: [String: [String: JSONValue]] = [:]
    public var notifications = NotificationPolicy()
    /// Shows frames and tags on panes while a self-identified agent acts on them.
    public var showAgentActivity = true
    public var agentColors: [String: String] = [:]
    public var agentColorRGB: [String: UInt32] { agentColors.compactMapValues { UInt32($0.dropFirst(), radix: 16) } }

    public static let defaults = AppConfiguration(
        browser: Browser(searchURL: "https://www.google.com/search?q={query}"),
        theme: .system,
        terminal: Terminal(shell: "/bin/zsh", workingDirectory: "~", inheritWorkingDirectory: true, savedOutputLines: 10_000, fontFamily: "SF Mono", fontSize: 13, shellIntegration: .auto,
                           fontThicken: false, minimumContrast: 1, cursorStyle: .block, cursorBlink: .auto,
                           paddingX: 2, paddingY: 2, lightTheme: TerminalTheme(.builtinLight), darkTheme: TerminalTheme(.builtinDark)),
        restoreWorkspace: true,
        keyBindings: Dictionary(uniqueKeysWithValues: CommandRegistry.commands.filter { !$0.key.isEmpty }.map { command in
            var modifiers: Set<KeyChord.Modifier> = [.cmd]
            if command.shift { modifiers.insert(.shift) }
            if command.alt { modifiers.insert(.alt) }
            if command.control { modifiers.insert(.ctrl) }
            return (KeyChord(modifiers: modifiers, key: command.key), command.id)
        }).merging([
            KeyChord(modifiers: [.ctrl, .alt], key: "h"): "focus.left",
            KeyChord(modifiers: [.ctrl, .alt], key: "j"): "focus.down",
            KeyChord(modifiers: [.ctrl, .alt], key: "k"): "focus.up",
            KeyChord(modifiers: [.ctrl, .alt], key: "l"): "focus.right",
        ], uniquingKeysWith: { _, new in new })
    )

    public static func parse(_ source: String) throws -> AppConfiguration {
        let raw = try TOMLDecoder().decode(Raw.self, from: source)
        let table = try TOMLTable(source: source)
        var agentColors: [String: String] = [:]
        if table.keys.contains("agents") {
            let agents = try table.table(forKey: "agents")
            if agents.keys.contains("colors") { agentColors = try AgentAccentColors.parse(agents.table(forKey: "colors")) }
        }
        let defaults = Self.defaults
        let unfocusedPaneDim = raw.appearance?.unfocusedPaneDim?.value ?? defaults.unfocusedPaneDim
        guard unfocusedPaneDim.isFinite, (0...1).contains(unfocusedPaneDim) else {
            throw ConfigurationError.invalid("appearance.unfocused_pane_dim must be finite and between 0 and 1")
        }
        let terminal = Terminal(
            shell: raw.terminal?.shell ?? defaults.terminal.shell,
            workingDirectory: raw.terminal?.workingDirectory ?? defaults.terminal.workingDirectory,
            inheritWorkingDirectory: raw.terminal?.inheritWorkingDirectory ?? defaults.terminal.inheritWorkingDirectory,
            savedOutputLines: raw.terminal?.savedOutputLines ?? defaults.terminal.savedOutputLines,
            fontFamily: raw.terminal?.fontFamily ?? defaults.terminal.fontFamily,
            fontSize: raw.terminal?.fontSize?.value ?? defaults.terminal.fontSize,
            shellIntegration: raw.terminal?.shellIntegration ?? defaults.terminal.shellIntegration,
            fontThicken: raw.terminal?.fontThicken ?? defaults.terminal.fontThicken,
            minimumContrast: raw.terminal?.minimumContrast?.value ?? defaults.terminal.minimumContrast,
            cursorStyle: raw.terminal?.cursorStyle ?? defaults.terminal.cursorStyle,
            cursorBlink: raw.terminal?.cursorBlink ?? defaults.terminal.cursorBlink,
            paddingX: raw.terminal?.paddingX ?? defaults.terminal.paddingX,
            paddingY: raw.terminal?.paddingY ?? defaults.terminal.paddingY,
            lightTheme: raw.terminal?.lightTheme ?? defaults.terminal.lightTheme,
            darkTheme: raw.terminal?.darkTheme ?? defaults.terminal.darkTheme)
        guard (0...SavedTerminalOutput.maximumLines).contains(terminal.savedOutputLines) else {
            throw ConfigurationError.invalid("terminal.saved_output_lines must be an integer between 0 and 100000")
        }
        guard terminal.minimumContrast.isFinite, (1...21).contains(terminal.minimumContrast) else {
            throw ConfigurationError.invalid("terminal.minimum_contrast must be finite and between 1 and 21")
        }
        for (name, value) in [("padding_x", terminal.paddingX), ("padding_y", terminal.paddingY)] {
            guard (0...64).contains(value) else {
                throw ConfigurationError.invalid("terminal.\(name) must be an integer between 0 and 64 points")
            }
        }
        guard terminal.fontSize.isFinite, (1...256).contains(terminal.fontSize) else {
            throw ConfigurationError.invalid("terminal.font_size must be finite and between 1 and 256 points")
        }
        for (name, value) in [("terminal.shell", terminal.shell), ("terminal.font_family", terminal.fontFamily)] {
            guard !value.trimmingCharacters(in: .whitespaces).isEmpty,
                  !value.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || $0.value == 0 }) else {
                throw ConfigurationError.invalid("\(name) must be a nonempty single-line string")
            }
        }
        guard (terminal.workingDirectory.hasPrefix("/") || terminal.workingDirectory == "~" || terminal.workingDirectory.hasPrefix("~/")),
              !terminal.workingDirectory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConfigurationError.invalid("terminal.working_directory must be an absolute path or start with ~/, without control characters")
        }
        guard terminal.shell.hasPrefix("/") else { throw ConfigurationError.invalid("terminal.shell must be an absolute executable path") }
        // The pinned engine reparses commands for automatic integration using a
        // non-POSIX argument iterator. These characters cannot roundtrip through
        // both parsers safely; explicit integration-off uses literal shell quoting.
        if terminal.shellIntegration == .auto, terminal.shell.unicodeScalars.contains(where: { $0 == "$" || $0 == "`" || $0 == "\\" }) {
            throw ConfigurationError.invalid("Automatic integration does not support dollar signs, backticks, or backslashes in shell paths; set terminal.shell_integration to 'off'")
        }
        var bindings = defaults.keyBindings
        var seen = Set<KeyChord>()
        for (source, command) in raw.keybind ?? [:] {
            let chord = try KeyChord.parse(source)
            guard seen.insert(chord).inserted else { throw ConfigurationError.invalid("Duplicate keybinding: \(chord)") }
            if command == "unbound" { bindings.removeValue(forKey: chord) }
            else {
                guard CommandRegistry.commands.contains(where: { $0.id == command }) || PluginCommand.isNamespacedID(command) else {
                    throw ConfigurationError.invalid("Unknown command for \(chord): \(command)")
                }
                bindings[chord] = command
            }
        }
        let plugins = try raw.plugins.map(parsePluginSettings) ?? [:]
        guard plugins.count <= 64, try JSONEncoder().encode(plugins).count <= 65_536,
              plugins.keys.allSatisfy({ (try? PluginSettingsPatch.validateNamespace($0)) != nil }) else {
            throw ConfigurationError.invalid("Invalid plugin settings namespace or settings exceed 64 KiB / 64 plugins")
        }
        return AppConfiguration(browser: try Browser.parse(raw.browser?.searchURL ?? defaults.browser.searchURL), theme: raw.appearance?.theme ?? defaults.theme, unfocusedPaneDim: unfocusedPaneDim, terminal: terminal,
                                restoreWorkspace: raw.layout?.restoreWorkspace ?? defaults.restoreWorkspace, keyBindings: bindings, plugins: plugins, notifications: raw.notifications ?? NotificationPolicy(),
                                showAgentActivity: raw.agents?.showActivity ?? defaults.showAgentActivity,
                                agentColors: agentColors)
    }

    public static func load(from url: URL) throws -> AppConfiguration {
        do { return try parse(String(contentsOf: url, encoding: .utf8)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .defaults }
    }

    public func validateShellExecutable() throws {
        var attributes = stat()
        guard stat(terminal.shell, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: terminal.shell) else {
            throw ConfigurationError.invalid("terminal.shell must name a regular executable file: \(terminal.shell)")
        }
    }

    public func changedKeys(from previous: AppConfiguration) -> [String] {
        var keys: [String] = []
        let notificationValues: [(String, Bool)] = [
            ("automatic", notifications.automatic != previous.notifications.automatic),
            ("minimum_seconds", notifications.minimumSeconds != previous.notifications.minimumSeconds),
            ("tools", notifications.tools != previous.notifications.tools),
            ("banners", notifications.banners != previous.notifications.banners),
            ("sound", notifications.sound != previous.notifications.sound),
            ("command_details", notifications.commandDetails != previous.notifications.commandDetails)]
        keys += notificationValues.filter(\.1).map { "notifications." + $0.0 }
        if browser != previous.browser { keys.append("browser.search_url") }
        if theme != previous.theme { keys.append("appearance.theme") }
        if unfocusedPaneDim != previous.unfocusedPaneDim { keys.append("appearance.unfocused_pane_dim") }
        if keyBindings != previous.keyBindings { keys.append("keybind") }
        if plugins != previous.plugins { keys.append("plugins") }
        if restoreWorkspace != previous.restoreWorkspace { keys.append("layout.restore_workspace") }
        if showAgentActivity != previous.showAgentActivity { keys.append("agents.show_activity") }
        if agentColors != previous.agentColors { keys.append("agents.colors") }
        if terminal.savedOutputLines != previous.terminal.savedOutputLines { keys.append("terminal.saved_output_lines") }
        if terminal.fontFamily != previous.terminal.fontFamily { keys.append("terminal.font_family") }
        if terminal.fontSize != previous.terminal.fontSize { keys.append("terminal.font_size") }
        if terminal.fontThicken != previous.terminal.fontThicken { keys.append("terminal.font_thicken") }
        if terminal.minimumContrast != previous.terminal.minimumContrast { keys.append("terminal.minimum_contrast") }
        if terminal.cursorStyle != previous.terminal.cursorStyle { keys.append("terminal.cursor_style") }
        if terminal.cursorBlink != previous.terminal.cursorBlink { keys.append("terminal.cursor_blink") }
        if terminal.paddingX != previous.terminal.paddingX { keys.append("terminal.padding_x") }
        if terminal.paddingY != previous.terminal.paddingY { keys.append("terminal.padding_y") }
        if terminal.lightTheme != previous.terminal.lightTheme { keys.append("terminal.light_theme") }
        if terminal.darkTheme != previous.terminal.darkTheme { keys.append("terminal.dark_theme") }
        if terminal.workingDirectory != previous.terminal.workingDirectory { keys.append("terminal.working_directory") }
        if terminal.inheritWorkingDirectory != previous.terminal.inheritWorkingDirectory { keys.append("terminal.inherit_working_directory") }
        if terminal.shell != previous.terminal.shell { keys.append("terminal.shell") }
        if terminal.shellIntegration != previous.terminal.shellIntegration { keys.append("terminal.shell_integration") }
        return keys
    }

    public func restartRequired(from previous: AppConfiguration) -> [String] {
        changedKeys(from: previous).filter {
            ["terminal.shell", "terminal.shell_integration", "terminal.padding_x", "terminal.padding_y"].contains($0)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        enum Keys: String, CodingKey { case appearance, terminal, layout, keybind, browser, plugins, notifications, agents }
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(["theme": JSONValue.string(theme.rawValue), "unfocused_pane_dim": .number(unfocusedPaneDim)], forKey: .appearance)
        try container.encode(terminal, forKey: .terminal)
        try container.encode(browser, forKey: .browser)
        try container.encode(notifications, forKey: .notifications)
        try container.encode(plugins, forKey: .plugins)
        try container.encode(["restore_workspace": restoreWorkspace], forKey: .layout)
        try container.encode(["show_activity": JSONValue.bool(showAgentActivity),
                              "colors": .object(agentColors.mapValues(JSONValue.string))], forKey: .agents)
        try container.encode(Dictionary(uniqueKeysWithValues: keyBindings.map { ($0.key.description, $0.value) }), forKey: .keybind)
    }

    private struct Raw: Decodable {
        let browser: BrowserValues?
        let appearance: Appearance?
        let terminal: TerminalValues?
        let layout: LayoutValues?
        let keybind: [String: String]?
        let plugins: TOMLTable?
        let notifications: NotificationPolicy?
        let agents: AgentValues?
        enum Keys: String, CodingKey, CaseIterable { case appearance, terminal, layout, keybind, browser, plugins, notifications, agents }
        init(from decoder: any Decoder) throws {
            let c = try checkedContainer(decoder, Keys.self)
            browser = try c.decodeIfPresent(BrowserValues.self, forKey: .browser)
            appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance)
            terminal = try c.decodeIfPresent(TerminalValues.self, forKey: .terminal)
            layout = try c.decodeIfPresent(LayoutValues.self, forKey: .layout)
            keybind = try c.decodeIfPresent([String: String].self, forKey: .keybind)
            plugins = try c.decodeIfPresent(TOMLTable.self, forKey: .plugins)
            notifications = try c.decodeIfPresent(NotificationPolicy.self, forKey: .notifications)
            agents = try c.decodeIfPresent(AgentValues.self, forKey: .agents)
        }
    }
    private struct AgentValues: Decodable {
        let showActivity: Bool?
        enum Keys: String, CodingKey, CaseIterable { case showActivity = "show_activity", colors }
        init(from decoder: any Decoder) throws {
            let c = try checkedContainer(decoder, Keys.self)
            showActivity = try c.decodeIfPresent(Bool.self, forKey: .showActivity)
        }
    }
    private struct BrowserValues: Decodable {
        let searchURL: String?
        enum Keys: String, CodingKey, CaseIterable { case searchURL = "search_url" }
        init(from decoder: any Decoder) throws {
            searchURL = try checkedContainer(decoder, Keys.self).decodeIfPresent(String.self, forKey: .searchURL)
        }
    }
    private struct Appearance: Decodable {
        let theme: Theme?
        let unfocusedPaneDim: Number?
        enum Keys: String, CodingKey, CaseIterable { case theme, unfocusedPaneDim = "unfocused_pane_dim" }
        init(from decoder: any Decoder) throws {
            let c = try checkedContainer(decoder, Keys.self)
            theme = try c.decodeIfPresent(Theme.self, forKey: .theme)
            unfocusedPaneDim = try c.decodeIfPresent(Number.self, forKey: .unfocusedPaneDim)
        }
    }
    private struct LayoutValues: Decodable {
        let restoreWorkspace: Bool?
        enum Keys: String, CodingKey, CaseIterable { case restoreWorkspace = "restore_workspace" }
        init(from decoder: any Decoder) throws {
            restoreWorkspace = try checkedContainer(decoder, Keys.self).decodeIfPresent(Bool.self, forKey: .restoreWorkspace)
        }
    }
    private struct TerminalValues: Decodable {
        let shell: String?
        let workingDirectory: String?
        let inheritWorkingDirectory: Bool?
        let savedOutputLines: Int?
        let fontFamily: String?
        let fontSize: Number?
        let shellIntegration: ShellIntegration?
        let fontThicken: Bool?
        let minimumContrast: Number?
        let cursorStyle: CursorStyle?
        let cursorBlink: CursorBlink?
        let paddingX: Int?
        let paddingY: Int?
        let lightTheme: TerminalTheme?
        let darkTheme: TerminalTheme?
        enum Keys: String, CodingKey, CaseIterable {
            case workingDirectory = "working_directory", inheritWorkingDirectory = "inherit_working_directory"
            case savedOutputLines = "saved_output_lines"
            case shell, fontFamily = "font_family", fontSize = "font_size", shellIntegration = "shell_integration"
            case fontThicken = "font_thicken", minimumContrast = "minimum_contrast"
            case cursorStyle = "cursor_style", cursorBlink = "cursor_blink"
            case paddingX = "padding_x", paddingY = "padding_y", lightTheme = "light_theme", darkTheme = "dark_theme"
        }
        init(from decoder: any Decoder) throws {
            let c = try checkedContainer(decoder, Keys.self)
            shell = try c.decodeIfPresent(String.self, forKey: .shell)
            workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
            inheritWorkingDirectory = try c.decodeIfPresent(Bool.self, forKey: .inheritWorkingDirectory)
            savedOutputLines = try c.decodeIfPresent(Int.self, forKey: .savedOutputLines)
            fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily)
            fontSize = try c.decodeIfPresent(Number.self, forKey: .fontSize)
            shellIntegration = try c.decodeIfPresent(ShellIntegration.self, forKey: .shellIntegration)
            fontThicken = try c.decodeIfPresent(Bool.self, forKey: .fontThicken)
            minimumContrast = try c.decodeIfPresent(Number.self, forKey: .minimumContrast)
            cursorStyle = try c.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle)
            cursorBlink = try c.decodeIfPresent(CursorBlink.self, forKey: .cursorBlink)
            paddingX = try c.decodeIfPresent(Int.self, forKey: .paddingX)
            paddingY = try c.decodeIfPresent(Int.self, forKey: .paddingY)
            lightTheme = try c.decodeIfPresent(TerminalTheme.self, forKey: .lightTheme)
            darkTheme = try c.decodeIfPresent(TerminalTheme.self, forKey: .darkTheme)
        }
    }
    private struct Number: Decodable {
        let value: Double
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            // TOMLDecoder intentionally converts offset timestamps to Double.
            // Rendering values accept numeric TOML values, not Unix timestamps.
            guard (try? c.decode(OffsetDateTime.self)) == nil else {
                throw ConfigurationError.invalid("\(decoder.codingPath.map(\.stringValue).joined(separator: ".")) must be a number, not a timestamp")
            }
            if let integer = try? c.decode(Int.self) { value = Double(integer) }
            else { value = try c.decode(Double.self) }
        }
    }
}

private func checkedContainer<Key: CodingKey & CaseIterable>(_ decoder: any Decoder, _ keys: Key.Type) throws -> KeyedDecodingContainer<Key> {
    let all = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
    let allowed = Set(Key.allCases.map(\.stringValue))
    if let unknown = all.sorted().first(where: { !allowed.contains($0) }) {
        throw ConfigurationError.invalid("Unknown configuration key: \((decoder.codingPath.map(\.stringValue) + [unknown]).joined(separator: "."))")
    }
    return try decoder.container(keyedBy: keys)
}

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
