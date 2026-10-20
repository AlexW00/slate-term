import AppKit
import CryptoKit
import SlateTermCore
import SlateTermSettings

@MainActor
final class ApplicationSettings {
    let base: URL
    let configURL: URL
    /// Shared configuration is read-only; configURL always names this app's writable file.
    let parentConfigURL: URL?
    private(set) var parentConfigurationError: String?
    let paletteDirectory: URL
    let engineURL: URL
    private let shellDirectory: URL
    private let bashInit: URL
    private let fishInit: URL
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
    let bundledPaletteDirectory = RuntimeBundle.bundle.resourceURL!.appendingPathComponent("ghostty/themes")
    private var bundledColors: [String: TerminalColors] = [:]
    /// Home folder whose agent skill folders receive links. Integration runs never use the real home.
    let agentHome: URL
    private(set) var error: String?
    private(set) var workspaceError: String?
    private(set) var savingSuspended = false
    private(set) var restoredState = WorkspaceRestoration()

    init(environment: [String: String], integration: Bool) throws {
        useIsolatedShell = integration && environment["SLATE_TERM_TEST_REAL_SHELL"] != "1"
        if integration, environment["SLATE_TERM_STATE_DIR"] == nil {
            throw TerminalError.initialization("Integration mode requires an isolated state directory")
        }
        switch ApplicationLaunchContext.current {
        case .standard:
            base = environment["SLATE_TERM_STATE_DIR"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SlateTerm")
            configURL = environment["SLATE_TERM_CONFIG_FILE"].map { URL(fileURLWithPath: $0) }
                ?? (integration ? base.appendingPathComponent("config/config.toml")
                    : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/slate-term/config.toml"))
            parentConfigURL = nil
        case .layoutApp(let descriptor):
            base = descriptor.base
            parentConfigURL = descriptor.parentConfigURL
            configURL = descriptor.base.appendingPathComponent("config/overrides.toml")
        }
        paletteDirectory = (parentConfigURL ?? configURL).deletingLastPathComponent().appendingPathComponent("palettes")
        agentHome = integration ? URL(fileURLWithPath: environment["SLATE_TERM_AGENT_HOME"] ?? base.appendingPathComponent("agent-home").path)
            : FileManager.default.homeDirectoryForCurrentUser
        store = try WorkspaceStore(directory: base.appendingPathComponent("state"),
            inheritedDescriptor: parentConfigURL == nil ? nil : environment["SLATE_LAYOUT_STATE_FD"].flatMap(Int32.init))
        welcome = WelcomeStore(url: base.appendingPathComponent("state/welcome.json"))
        if parentConfigURL != nil, welcome.acknowledged == false {
            try welcome.setAcknowledged(true)
        }
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
        bashInit = shellDirectory.deletingLastPathComponent().appendingPathComponent("shell-bash/init.bash")
        fishInit = shellDirectory.deletingLastPathComponent().appendingPathComponent("shell-fish/init.fish")
        for (url, text) in [(bashInit, SlateTermSettings.ShellIntegration.bashHooks), (fishInit, SlateTermSettings.ShellIntegration.fishHooks)] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        var configuration = AppConfiguration.defaults
        var palettes = try configuration.terminal.resolvePalettes(directory: paletteDirectory)
        do {
            let candidate: AppConfiguration
            if let parentConfigURL {
                let parentPalettes = paletteDirectory
                let loaded = try LayoutAppConfiguration.load(parentURL: parentConfigURL, overridesURL: configURL) { parent in
                    try parent.validateShellExecutable()
                    _ = try parent.terminal.resolvePalettes(directory: parentPalettes)
                }
                candidate = loaded.configuration
                parentConfigurationError = loaded.parentError
                self.error = loaded.parentError
            } else {
                candidate = try AppConfiguration.load(from: configURL)
            }
            try candidate.validateShellExecutable()
            palettes = try candidate.terminal.resolvePalettes(directory: paletteDirectory)
            configuration = candidate
        } catch { self.error = String(describing: error) }
        current = configuration
        appliedPalettes = palettes
        launchConfiguration = configuration
        try engineConfiguration(configuration, palettes: palettes).write(to: engineURL, atomically: true, encoding: .utf8)
    }

    var hasSavedWorkspace: Bool { FileManager.default.fileExists(atPath: store.url.path) }

    /// Nil keeps the catalog untouched until restore reports the invalid snapshot.
    func restorablePluginTypes() -> Set<String>? {
        guard current.restoreWorkspace else { return [] }
        do {
            guard let snapshot = try store.loadSnapshot() else { return [] }
            return Set(snapshot.workspace.panes.compactMap { pane in
                if case .registered(let id) = pane.type { return id }
                return nil
            })
        } catch { return nil }
    }

    func restore(or initial: Workspace, registeredTypes: Set<String> = []) -> Workspace {
        guard current.restoreWorkspace else { return initial }
        do {
            guard let snapshot = try store.loadSnapshot() else { return initial }
            let restored = snapshot.workspace
            for pane in restored.panes {
                if case .registered(let type) = pane.type, !registeredTypes.contains(type) {
                    throw WorkspaceError.invalidSnapshot("Pane type is not registered: \(type)")
                }
            }
            restoredState = snapshot.restoration
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
    func save(_ workspace: Workspace, restoration: WorkspaceRestoration) -> WorkspacePersistence {
        guard current.restoreWorkspace else { return .disabled }
        guard !savingSuspended else { return .suspended }
        do { try store.save(workspace, restoration: restoration); workspaceError = nil; return .saved }
        catch { workspaceError = "Could not save \(store.url.path): \(error)"; return .failed }
    }

    func setSuppressCloseWarning(_ suppress: Bool) throws {
        guard suppressCloseWarning != suppress || preferenceError != nil else { return }
        try closeWarningStore.save(suppress)
        suppressCloseWarning = suppress
        preferenceError = nil
    }

    func setSuppressTypeWarning(_ suppress: Bool) throws {
        guard suppressTypeWarning != suppress || typeWarningError != nil else { return }
        try typeWarningStore.save(suppress)
        suppressTypeWarning = suppress
        typeWarningError = nil
    }

    func shellEnvironment() -> [String: String] {
        guard !useIsolatedShell, current.terminal.shellIntegration == .auto,
              let kind = ShellKind(executablePath: current.terminal.shell) else { return [:] }
        switch kind {
        case .zsh: break
        case .bash:
            // Runs at the first prompt; see ShellIntegration.bashBootstrap.
            return ["PROMPT_COMMAND": SlateTermSettings.ShellIntegration.bashBootstrap, "SLATE_TERM_BASH_INIT": bashInit.path]
        case .fish: return [:]  // Loaded by --init-command; see engineConfiguration.
        }
        let original = ProcessInfo.processInfo.environment["ZDOTDIR"]
        // Surface environment overrides are applied after engine injection.
        // Redirect its saved dot-directory; replacing ZDOTDIR would bypass the
        // engine's own bootstrap and silently remove OSC 133 and PATH integration.
        return ["GHOSTTY_ZSH_ZDOTDIR": shellDirectory.path, "SLATE_TERM_USER_ZDOTDIR": original ?? "",
                "SLATE_TERM_USER_ZDOTDIR_SET": original == nil ? "0" : "1"]
    }

    /// fish loads Slate's hooks after config.fish. The engine runs the command through a
    /// POSIX shell, so the path goes in single quotes inside double quotes; paths that
    /// would need more escaping get no integration rather than a fragile command line.
    private func fishInitArguments(_ configuration: AppConfiguration) -> String {
        guard configuration.terminal.shellIntegration == .auto,
              ShellKind(executablePath: configuration.terminal.shell) == .fish,
              !fishInit.path.contains(where: { "'\"$`\\".contains($0) }) else { return "" }
        return " -C \"source '\(fishInit.path)'\""
    }

    /// Candidate text always belongs to the writable local file, never the parent.
    func loadEffectiveConfiguration(overridesSource: String? = nil) throws -> AppConfiguration {
        guard let parentConfigURL else {
            return try overridesSource.map(AppConfiguration.parse) ?? AppConfiguration.load(from: configURL)
        }
        let loaded = try LayoutAppConfiguration.load(parentURL: parentConfigURL, overridesURL: configURL,
            overridesSource: overridesSource) { parent in
                try parent.validateShellExecutable()
                _ = try parent.terminal.resolvePalettes(directory: paletteDirectory)
            }
        parentConfigurationError = loaded.parentError
        return loaded.configuration
    }

    /// Tokens include the shared source so edits conflict when either layer changes.
    func configurationSourceIdentity(_ source: String) -> String {
        guard let parentConfigURL else { return source }
        let parent: Data
        do { parent = try Data(contentsOf: parentConfigURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { parent = Data() }
        catch { parent = Data("unreadable:\(error)".utf8) }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        return "layout-app-settings-v1:" + digest(Data(source.utf8)) + ":" + digest(parent)
    }

    func updatingConfigurationSource(source: String, values: [String: String]) throws -> String {
        guard parentConfigURL != nil else { return try AppConfiguration.updating(source: source, values: values) }
        return try LayoutAppConfiguration.updating(source: source, values: values) {
            try loadEffectiveConfiguration(overridesSource: $0)
        }
    }

    func updatingPluginConfigurationSource(source: String, pluginID: String, operations: [JSONValue]) throws -> String {
        guard parentConfigURL != nil else { return try PluginSettingsPatch.updating(source: source, pluginID: pluginID, operations: operations) }
        return try LayoutAppConfiguration.updatingPluginSettings(source: source, pluginID: pluginID, operations: operations) {
            try loadEffectiveConfiguration(overridesSource: $0)
        }
    }

    func overriddenSettingKeys() throws -> [String] {
        guard parentConfigURL != nil else { return [] }
        do { return try LayoutAppConfiguration.overriddenSettingKeys(source: String(contentsOf: configURL, encoding: .utf8)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    func validate() throws -> AppConfiguration {
        let candidate = try loadEffectiveConfiguration()
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
            let next = try prepared ?? prepare(loadEffectiveConfiguration())
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
            error = parentConfigurationError
            return .object(["changed": .array(changed.map(JSONValue.string)),
                            "restartRequired": .array(current.restartRequired(from: launchConfiguration).map(JSONValue.string))])
        } catch {
            self.error = String(describing: error)
            throw RPCFailure(code: -32020, message: "Configuration rejected; previous settings retained: \(error)")
        }
    }

    func status() throws -> JSONValue {
        .object(["path": .string(configURL.path), "current": try .encoding(current),
                 "parentPath": parentConfigURL.map { .string($0.path) } ?? .null,
                 "parentError": parentConfigurationError.map(JSONValue.string) ?? .null,
                 "overriddenKeys": .array(((try? overriddenSettingKeys()) ?? []).map(JSONValue.string)),
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
        let command = useIsolatedShell ? "/bin/sh --noprofile --norc" : shell + fishInitArguments(configuration)
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
