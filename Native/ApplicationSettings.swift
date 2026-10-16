import AppKit
import SlateTermCore
import SlateTermSettings

/// Workspace snapshot status only; not a transaction result for shells, WebKit or other files.
enum WorkspacePersistence: String, CaseIterable {
    case saved, disabled, suspended, failed, notRequired
}

@MainActor
final class ApplicationSettings {
    let base: URL
    let configURL: URL
    let paletteDirectory: URL
    let engineURL: URL
    private let shellDirectory: URL
    let welcome: WelcomeStore
    private let store: WorkspaceStore
    private let closeWarningStore: PrivateJSONStore
    private let typeWarningStore: PrivateJSONStore
    private(set) var suppressTypeWarning = false
    private(set) var typeWarningError: String?
    private(set) var suppressCloseWarning = false
    private(set) var preferenceError: String?
    private let useIsolatedShell: Bool
    private let launchConfiguration: AppConfiguration
    private(set) var current: AppConfiguration
    /// The palettes the terminal engine was last configured with; appearance.get reads these.
    private(set) var appliedPalettes: ResolvedTerminalPalettes
    let bundledPaletteDirectory = Bundle.main.resourceURL!.appendingPathComponent("ghostty/themes")
    private var bundledColors: [String: TerminalColors] = [:]
    /// Home folder whose agent skill folders receive links. Integration runs never use the real home.
    let agentHome: URL
    private(set) var error: String?
    private(set) var workspaceError: String?
    private(set) var savingSuspended = false

    init(environment: [String: String], integration: Bool) throws {
        useIsolatedShell = integration && environment["SLATE_TERM_TEST_REAL_SHELL"] != "1"
        if integration, environment["SLATE_TERM_STATE_DIR"] == nil {
            throw TerminalError.initialization("Integration mode requires an isolated state directory")
        }
        base = environment["SLATE_TERM_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SlateTerm")
        configURL = environment["SLATE_TERM_CONFIG_FILE"].map { URL(fileURLWithPath: $0) }
            ?? (integration ? base.appendingPathComponent("config/config.toml")
                : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/slate-term/config.toml"))
        paletteDirectory = configURL.deletingLastPathComponent().appendingPathComponent("palettes")
        agentHome = integration ? URL(fileURLWithPath: environment["SLATE_TERM_AGENT_HOME"] ?? base.appendingPathComponent("agent-home").path)
            : FileManager.default.homeDirectoryForCurrentUser
        store = try WorkspaceStore(directory: base.appendingPathComponent("state"))
        welcome = WelcomeStore(url: base.appendingPathComponent("state/welcome.json"))
        closeWarningStore = try PrivateJSONStore(url: base.appendingPathComponent("state/suppress-close-warning.json"), maximumBytes: 128)
        do { suppressCloseWarning = try closeWarningStore.load(Bool.self) ?? false }
        catch { preferenceError = "Could not read the close-warning preference; warnings remain enabled. \(error)" }
        typeWarningStore = try PrivateJSONStore(url: base.appendingPathComponent("state/suppress-type-warning.json"), maximumBytes: 128)
        do { suppressTypeWarning = try typeWarningStore.load(Bool.self) ?? false }
        catch { typeWarningError = "Could not read the pane-type warning preference; warnings remain enabled. \(error)" }
        engineURL = store.url.deletingLastPathComponent().appendingPathComponent("terminal.conf")
        shellDirectory = store.url.deletingLastPathComponent().appendingPathComponent("shell-zsh")
        try FileManager.default.createDirectory(at: shellDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bootstrap = shellDirectory.appendingPathComponent(".zshenv")
        try SlateTermSettings.ShellIntegration.zshBootstrap.write(to: bootstrap, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bootstrap.path)
        var configuration = AppConfiguration.defaults
        var palettes = try configuration.terminal.resolvePalettes(directory: paletteDirectory)
        do {
            let candidate = try AppConfiguration.load(from: configURL)
            try candidate.validateShellExecutable()
            palettes = try candidate.terminal.resolvePalettes(directory: paletteDirectory)
            configuration = candidate
        } catch { self.error = String(describing: error) }
        current = configuration
        appliedPalettes = palettes
        launchConfiguration = configuration
        try engineConfiguration(configuration, palettes: palettes).write(to: engineURL, atomically: true, encoding: .utf8)
    }

    func restore(or initial: Workspace, registeredTypes: Set<String> = []) -> Workspace {
        guard current.restoreWorkspace else { return initial }
        do {
            guard let restored = try store.load() else { return initial }
            for pane in restored.panes {
                if case .registered(let type) = pane.type, !registeredTypes.contains(type) {
                    throw WorkspaceError.invalidSnapshot("Pane type is not registered: \(type)")
                }
            }
            return restored
        }
        catch {
            workspaceError = "Restoration failed; the original file is preserved. Repair or move \(store.url.path) and restart. \(error)"
            savingSuspended = true
            return initial
        }
    }

    /// Autosave is best effort; failures are visible in the app menu and config.get.
    /// A bad startup snapshot is never silently replaced by the recovery workspace.
    @discardableResult
    func save(_ workspace: Workspace) -> WorkspacePersistence {
        guard current.restoreWorkspace else { return .disabled }
        guard !savingSuspended else { return .suspended }
        do { try store.save(workspace); workspaceError = nil; return .saved }
        catch { workspaceError = "Could not save \(store.url.path): \(error)"; return .failed }
    }

    func setSuppressCloseWarning(_ suppress: Bool) throws {
        try closeWarningStore.save(suppress)
        suppressCloseWarning = suppress
        preferenceError = nil
    }

    func setSuppressTypeWarning(_ suppress: Bool) throws {
        try typeWarningStore.save(suppress)
        suppressTypeWarning = suppress
        typeWarningError = nil
    }

    func shellEnvironment() -> [String: String] {
        guard !useIsolatedShell, current.terminal.shellIntegration == .auto,
              URL(fileURLWithPath: current.terminal.shell).lastPathComponent == "zsh" else { return [:] }
        let original = ProcessInfo.processInfo.environment["ZDOTDIR"]
        // Surface environment overrides are applied after engine injection.
        // Redirect its saved dot-directory; replacing ZDOTDIR would bypass the
        // engine's own bootstrap and silently remove OSC 133 and PATH integration.
        return ["GHOSTTY_ZSH_ZDOTDIR": shellDirectory.path, "SLATE_TERM_USER_ZDOTDIR": original ?? "",
                "SLATE_TERM_USER_ZDOTDIR_SET": original == nil ? "0" : "1"]
    }

    func validate() throws -> AppConfiguration {
        let candidate = try AppConfiguration.load(from: configURL)
        try candidate.validateShellExecutable()
        _ = try candidate.terminal.resolvePalettes(directory: paletteDirectory)
        return candidate
    }

    struct PreparedConfiguration {
        let configuration: AppConfiguration
        let palettes: ResolvedTerminalPalettes
        let engineSource: String
    }

    func prepare(_ configuration: AppConfiguration) throws -> PreparedConfiguration {
        try configuration.validateShellExecutable()
        let palettes = try configuration.terminal.resolvePalettes(directory: paletteDirectory)
        return try PreparedConfiguration(configuration: configuration, palettes: palettes, engineSource: engineConfiguration(configuration, palettes: palettes))
    }

    func terminalColors(dark: Bool) throws -> TerminalColors {
        let theme = dark ? current.terminal.darkTheme : current.terminal.lightTheme
        if theme.bundled != nil, let colors = bundledColors[theme.rawValue] { return colors }
        let colors = try appliedPalettes.colors(dark: dark, bundledDirectory: bundledPaletteDirectory)
        // Bundled resources are immutable for this app process. Custom colors remain
        // the validated snapshot from the last successful reload.
        if theme.bundled != nil { bundledColors[theme.rawValue] = colors }
        return colors
    }

    func reload(prepared: PreparedConfiguration? = nil, apply: (URL, Bool) throws -> Void) throws -> JSONValue {
        do {
            let next = try prepared ?? prepare(AppConfiguration.load(from: configURL))
            let changed = next.configuration.changedKeys(from: current)
            let previousSource = try String(contentsOf: engineURL, encoding: .utf8)
            let engineChanged = previousSource != next.engineSource
            if engineChanged { try next.engineSource.write(to: engineURL, atomically: true, encoding: .utf8) }
            do { try apply(engineURL, engineChanged) }
            catch {
                if engineChanged { try previousSource.write(to: engineURL, atomically: true, encoding: .utf8) }
                throw error
            }
            current = next.configuration
            appliedPalettes = next.palettes
            error = nil
            return .object(["changed": .array(changed.map(JSONValue.string)),
                            "restartRequired": .array(current.restartRequired(from: launchConfiguration).map(JSONValue.string))])
        } catch {
            self.error = String(describing: error)
            throw RPCFailure(code: -32020, message: "Configuration rejected; previous settings retained: \(error)")
        }
    }

    func status() throws -> JSONValue {
        .object(["path": .string(configURL.path), "current": try .encoding(current),
                 "welcome": try .encoding(welcome.snapshot),
                 "welcomeError": welcome.diagnostic.map(JSONValue.string) ?? .null,
                 "closeWarning": .object(["suppressed": .bool(suppressCloseWarning), "error": preferenceError.map(JSONValue.string) ?? .null]),
                 "typeWarning": .object(["suppressed": .bool(suppressTypeWarning), "error": typeWarningError.map(JSONValue.string) ?? .null]),
                 "error": error.map(JSONValue.string) ?? .null,
                 "restartRequired": .array(current.restartRequired(from: launchConfiguration).map(JSONValue.string)),
                 "workspace": .object(["path": .string(store.url.path), "savingSuspended": .bool(savingSuspended),
                                       "error": workspaceError.map(JSONValue.string) ?? .null])])
    }

    private func engineConfiguration(_ configuration: AppConfiguration, palettes: ResolvedTerminalPalettes) throws -> String {
        let shell: String
        if configuration.terminal.shellIntegration == .off {
            shell = "'" + configuration.terminal.shell.replacingOccurrences(of: "'", with: "'\\''") + "' -l"
        } else {
            // Ghostty's detection iterator understands double, not single quotes.
            shell = "\"" + configuration.terminal.shell.replacingOccurrences(of: "\"", with: "\\\"") + "\" -l"
        }
        // SurfaceOptions.command forces wait-after-command. Configure the command
        // here instead, retaining normal shell-exit semantics and test isolation.
        let command = useIsolatedShell ? "/bin/sh --noprofile --norc" : shell
        return """
        command = shell:\(command)
        wait-after-command = false
        shell-integration = \(configuration.terminal.shellIntegration == .off || useIsolatedShell ? "none" : "detect")
        \(try configuration.terminal.renderingConfiguration(palettes: palettes,
            directory: engineURL.deletingLastPathComponent().appendingPathComponent("palettes"),
            bundledDirectory: bundledPaletteDirectory))

        """
    }
}
