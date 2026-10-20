import AppKit
import Combine
import SwiftUI
import SlateTermCore
import SlateTermSettings

@MainActor
final class SettingsModel: ObservableObject {
    struct Plugin: Identifiable, Equatable {
        let id: String
        enum Indicator {
            case disabled, idle, busy, ready, failed
            var symbol: String {
                switch self {
                case .disabled: "pause.circle.fill"
                case .idle: "circle.fill"
                case .busy: "clock.fill"
                case .ready: "checkmark.circle.fill"
                case .failed: "exclamationmark.circle.fill"
                }
            }
            var color: Color {
                switch self {
                case .disabled, .idle: .secondary
                case .busy: .orange
                case .ready: .green
                case .failed: .red
                }
            }
        }
        let title: String
        let enabled: Bool
        let indicator: Indicator
        let status: String
    }
    @Published var selection: SettingsSection? = .general
    @Published var theme = "system"
    @Published var unfocusedPaneDim = 0.08
    @Published var shell = ""
    @Published var workingDirectory = "~"
    @Published var inheritWorkingDirectory = true
    @Published var savedOutputLines = "10000"
    @Published var fontFamily = ""
    @Published var fontSize = ""
    @Published var fontThicken = false
    @Published var minimumContrast = ""
    @Published var cursorStyle = AppConfiguration.CursorStyle.block
    @Published var cursorBlink = AppConfiguration.CursorBlink.auto
    @Published var paddingX = ""
    @Published var paddingY = ""
    @Published var lightTheme = AppConfiguration.BundledTerminalTheme.builtinLight.rawValue
    @Published var darkTheme = AppConfiguration.BundledTerminalTheme.builtinDark.rawValue
    @Published var customPalettes: [PaletteLibrary.Entry] = []
    @Published var integration = "auto"
    @Published var restore = true
    @Published var searchURL = ""
    @Published var browserSites: [String] = []
    @Published var selectedBrowserSite = ""
    @Published var loadingBrowserSites = false
    var browserSitesRefreshID = UUID()
    @Published var clearingBrowserData = false
    @Published var browserDataMessage: String?
    @Published var browserDataError: String?
    var refreshBrowserSites: (() -> Void)?
    var clearBrowserData: (() -> Void)?
    var clearBrowserSiteData: (() -> Void)?
    var canClearBrowserSite: Bool {
        !loadingBrowserSites && browserSites.contains(selectedBrowserSite)
    }

    func selectBrowserSite(_ site: String) {
        selectedBrowserSite = site
        browserDataMessage = nil
        browserDataError = nil
    }

    func updateBrowserSites(_ sites: [String]) {
        browserSites = sites
        if !sites.contains(selectedBrowserSite) {
            selectedBrowserSite = sites.first ?? ""
        }
    }
    @Published var notifyAutomatic = true
    @Published var notifyMinimumSeconds = "30"
    @Published var notifyTools = true
    @Published var notifyBanners = NotificationPolicy.Banner.otherPanes
    @Published var notifySound = false
    @Published var notifyCommandDetails = false
    @Published var showAgentActivity = true
    @Published var agentColors: [String: String] = [:]
    @Published var notificationAuthorization = "Checking…"
    var authorizeNotifications: (() -> Void)?
    var notificationAuthorizationLabel: String {
        switch notificationAuthorization {
        case "authorized": "Allowed"
        case "denied": "Not allowed"
        case "notDetermined": "Not requested"
        case "unavailable": "Unavailable"
        default: "Checking…"
        }
    }
    @Published var shortcuts: [String: String] = [:]
    @Published var plugins: [Plugin] = []
    @Published var agentSkills: [AgentSkills.Entry] = []
    @Published var commands: [WorkspaceCommand] = CommandRegistry.commands
    @Published var error: String?
    @Published var layouts: SavedLayoutsModel?
    @Published var layoutsError: String?
    @Published var layoutAppName: String?
    @Published var sourceLayoutName: String?
    @Published var runtimeVersion: String?
    @Published var parentManaged = false
    @Published var overriddenKeys: Set<String> = []
    @Published var inheritedShortcuts: [String: String] = [:]
    @Published var layoutAppUpdateStatus: String?
    @Published var pluginSyncStatus: String?
    @Published var layoutApps: [JSONValue] = []
    var resetOverrides: (([String], String) throws -> Void)?
    var refreshLayoutApp: ((String, String) -> Void)?
    @Published private var baseline: [String: String] = [:]
    private var source = ""
    let configURL: URL
    let paletteDirectory: URL
    var save: ((String, [String: String]) throws -> Void)?
    var registerPlugin: (() -> Void)?
    var setPluginEnabled: ((String, Bool) -> Void)?
    var removePlugin: ((String) -> Void)?
    var deletePluginData: ((String) -> Void)?
    var changeAgentSkill: ((String, Bool) -> Void)?
    var revealAgentSkill: (() -> Void)?
    var refreshAgentSkills: (() -> Void)?

    init(configURL: URL, paletteDirectory: URL? = nil) {
        self.configURL = configURL
        self.paletteDirectory = paletteDirectory ?? configURL.deletingLastPathComponent().appendingPathComponent("palettes")
    }

    func resetOverride(_ keys: [String]) {
        guard parentManaged, !isDirty else { return }
        do { try resetOverrides?(keys, source); error = nil }
        catch { self.error = String(describing: error) }
    }

    func shortcutOverrideKeys(for command: String) -> [String] {
        let chords = Set(shortcuts.filter { $0.value == command }.keys)
            .union(inheritedShortcuts.filter { $0.value == command }.keys)
        return chords.map { "keybind." + $0 }.filter(overriddenKeys.contains).sorted()
    }

    var values: [String: String] {
        var values = ["appearance.theme": AppConfiguration.quotedString(theme),
                      "appearance.unfocused_pane_dim": String(unfocusedPaneDim),
                      "terminal.working_directory": AppConfiguration.quotedString(workingDirectory),
                      "terminal.inherit_working_directory": inheritWorkingDirectory ? "true" : "false",
                      "terminal.saved_output_lines": savedOutputLines,
                      "terminal.shell": AppConfiguration.quotedString(shell),
                      "terminal.font_family": AppConfiguration.quotedString(fontFamily),
                      "terminal.font_size": fontSize,
                      "terminal.font_thicken": fontThicken ? "true" : "false",
                      "terminal.minimum_contrast": minimumContrast,
                      "terminal.cursor_style": AppConfiguration.quotedString(cursorStyle.rawValue),
                      "terminal.cursor_blink": AppConfiguration.quotedString(cursorBlink.rawValue),
                      "terminal.padding_x": paddingX,
                      "terminal.padding_y": paddingY,
                      "terminal.light_theme": AppConfiguration.quotedString(lightTheme),
                      "terminal.dark_theme": AppConfiguration.quotedString(darkTheme),
                      "terminal.shell_integration": AppConfiguration.quotedString(integration),
                      "layout.restore_workspace": restore ? "true" : "false",
                      "browser.search_url": AppConfiguration.quotedString(searchURL),
                      "notifications.automatic": notifyAutomatic ? "true" : "false",
                      "notifications.minimum_seconds": notifyMinimumSeconds,
                      "notifications.tools": notifyTools ? "true" : "false",
                      "notifications.banners": AppConfiguration.quotedString(notifyBanners.rawValue),
                      "notifications.sound": notifySound ? "true" : "false",
                      "notifications.command_details": notifyCommandDetails ? "true" : "false",
                      "agents.show_activity": showAgentActivity ? "true" : "false",
                      "agents.colors": AgentAccentColors.literal(agentColors)]
        for (chord, command) in shortcuts { values["keybind." + chord] = AppConfiguration.quotedString(command) }
        return values
    }
    var isDirty: Bool { values != baseline }

    func load(_ configuration: AppConfiguration, source: String, error: String?, force: Bool = false) {
        guard force || !isDirty || baseline.isEmpty else { return }
        let preserveError = !force && self.source == source && !baseline.isEmpty && error == nil
        theme = configuration.theme.rawValue
        unfocusedPaneDim = configuration.unfocusedPaneDim
        shell = configuration.terminal.shell
        workingDirectory = configuration.terminal.workingDirectory
        inheritWorkingDirectory = configuration.terminal.inheritWorkingDirectory
        savedOutputLines = String(configuration.terminal.savedOutputLines)
        fontFamily = configuration.terminal.fontFamily
        fontSize = String(configuration.terminal.fontSize)
        fontThicken = configuration.terminal.fontThicken
        minimumContrast = String(configuration.terminal.minimumContrast)
        cursorStyle = configuration.terminal.cursorStyle
        cursorBlink = configuration.terminal.cursorBlink
        paddingX = String(configuration.terminal.paddingX)
        paddingY = String(configuration.terminal.paddingY)
        lightTheme = configuration.terminal.lightTheme.rawValue
        darkTheme = configuration.terminal.darkTheme.rawValue
        integration = configuration.terminal.shellIntegration.rawValue
        restore = configuration.restoreWorkspace
        searchURL = configuration.browser.searchURL
        notifyAutomatic = configuration.notifications.automatic
        notifyMinimumSeconds = String(configuration.notifications.minimumSeconds)
        notifyTools = configuration.notifications.tools
        notifyBanners = configuration.notifications.banners
        notifySound = configuration.notifications.sound
        notifyCommandDetails = configuration.notifications.commandDetails
        showAgentActivity = configuration.showAgentActivity
        agentColors = configuration.agentColors
        shortcuts = Dictionary(uniqueKeysWithValues: configuration.keyBindings.map { ($0.key.description, $0.value) })
        self.source = source
        if !preserveError { self.error = error }
        baseline = values
        do { customPalettes = try paletteLibrary.entries() }
        catch { self.error = String(describing: error) }
    }

    private var paletteLibrary: PaletteLibrary {
        PaletteLibrary(directory: paletteDirectory)
    }

    func importPalette(from url: URL) throws -> String {
        guard !parentManaged else { throw ConfigurationError.invalid("Import shared palettes in Slate Terminal") }
        let entry = try paletteLibrary.importPalette(from: url)
        customPalettes = try paletteLibrary.entries()
        return entry.name
    }

    func shortcut(for command: String) -> String? {
        shortcuts.keys.filter { shortcuts[$0] == command }.sorted().first
    }

    func resetShortcut(for command: String) {
        let defaultKey = AppConfiguration.defaults.keyBindings
            .filter { $0.value == command }.map { $0.key.description }.sorted().first
        assignShortcut(defaultKey, to: command)
    }

    func assignShortcut(_ shortcut: String?, to command: String) {
        do {
            let canonical = try shortcut.map { try KeyChord.parse($0).description }
            if let canonical, let owner = shortcuts[canonical], owner != command {
                let title = commands.first { $0.id == owner }?.title ?? owner
                throw ConfigurationError.invalid("That shortcut is already assigned to \(title). Remove it there first to reassign it.")
            }
            shortcuts = shortcuts.filter { $0.value != command }
            if let canonical { shortcuts[canonical] = command }
            error = nil
        } catch { self.error = String(describing: error) }
    }

    func apply() {
        do {
            var changes = values.filter { baseline[$0.key] != $0.value }
            for key in baseline.keys where key.hasPrefix("keybind.") && values[key] == nil {
                changes[key] = AppConfiguration.quotedString("unbound")
            }
            try save?(source, changes)
            error = nil
        } catch { self.error = String(describing: error) }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var shouldClose: (() -> Bool)?
    private var confirmingClose = false

    init(model: SettingsModel, reload: @escaping () -> Void) {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 1000, height: 560)
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model, reload: reload))
        super.init(window: window)
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !confirmingClose else { return false }
        confirmingClose = true
        defer { confirmingClose = false }
        return shouldClose?() ?? true
    }

    func beginRecordingShortcut(action: String, shortcut: String?) -> Bool {
        func find(in view: NSView) -> ShortcutButton? {
            if let button = view as? ShortcutButton, button.actionName == action, button.shortcut == shortcut { return button }
            for child in view.subviews { if let button = find(in: child) { return button } }
            return nil
        }
        guard let content = window?.contentView, let button = find(in: content) else { return false }
        button.performClick(nil)
        return button.isRecording
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case layoutApp = "Layout app", general = "General", appearance = "Appearance", terminal = "Terminal", browser = "Browser", notifications = "Notifications", layouts = "Layouts", shortcuts = "Keyboard Shortcuts", plugins = "Plugins", agents = "AI Agents"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .layoutApp: "app.badge"
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .terminal: "terminal"
        case .browser: "globe"
        case .notifications: "bell.badge"
        case .layouts: "rectangle.split.2x2"
        case .shortcuts: "keyboard"
        case .plugins: "puzzlepiece.extension"
        case .agents: "sparkles"
        }
    }
    var color: Color {
        switch self {
        case .layoutApp: .teal
        case .general: .gray
        case .appearance: .indigo
        case .terminal: .black
        case .browser: .blue
        case .notifications: .red
        case .layouts: .teal
        case .shortcuts: .purple
        case .plugins: .orange
        case .agents: .pink
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var generatedAppsContentHeight: CGFloat = 116
    let reload: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases.filter { $0 != .layoutApp || model.parentManaged }, selection: $model.selection) { section in
                Label {
                    Text(section.rawValue)
                        .fontWeight(model.selection == section ? .semibold : .regular)
                } icon: {
                    Image(systemName: section.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 25, height: 25)
                        .background(section.color.gradient, in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(.vertical, 4)
                .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                Text((model.selection ?? .general).rawValue)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
                if model.selection == .layouts, let layouts = model.layouts {
                    if !model.layoutApps.isEmpty { generatedApps }
                    SavedLayoutsView(model: layouts)
                } else if model.selection == .plugins && model.plugins.isEmpty {
                    emptyPlugins
                } else {
                    Form {
                        switch model.selection ?? .general {
                        case .layoutApp: layoutApp
                        case .general: general
                        case .appearance: appearance
                        case .terminal: terminal
                        case .browser: browser
                        case .notifications: notifications
                        case .layouts: Text(model.layoutsError ?? "Layouts are unavailable.").textSelection(.enabled)
                        case .shortcuts: keyboard
                        case .plugins: plugins
                        case .agents: agents
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.automatic)
                }
                if model.selection == .agents && !model.parentManaged {
                    Divider().padding(.horizontal, 24)
                    HStack {
                        Spacer()
                        Button("Open Skill Folder") { model.revealAgentSkill?() }
                        Spacer()
                    }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 20)
                }
                if let error = model.error {
                    Text(model.selection == .terminal && error.hasPrefix("terminal.")
                         ? "Check the highlighted setting before applying." : error)
                        .font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                if (model.selection != .layouts || model.parentManaged) && model.selection != .layoutApp {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        if model.parentManaged && [.plugins, .layouts].contains(model.selection ?? .general) {
                            Text("Plugins and layout apps are managed in Slate Terminal.")
                                .font(.callout).foregroundStyle(.secondary)
                            if let status = model.pluginSyncStatus {
                                Text(status).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        if model.selection != .layouts && model.selection != .layoutApp {
                            HStack {
                                Button("Show Config File") {
                                    NSWorkspace.shared.selectFile(model.configURL.path, inFileViewerRootedAtPath: model.configURL.deletingLastPathComponent().path)
                                }
                                Spacer()
                                Button("Revert", action: reload).disabled(!model.isDirty && model.error == nil)
                                Button("Apply") { model.apply() }.disabled(!model.isDirty)
                                    .keyboardShortcut("s", modifiers: .command)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var layoutApp: some View {
        Section {
            LabeledContent("Name", value: model.layoutAppName ?? "Layout app")
            LabeledContent("Source layout", value: model.sourceLayoutName ?? "Unavailable")
            LabeledContent("Runtime version", value: model.runtimeVersion ?? "Unknown")
            if let status = model.layoutAppUpdateStatus {
                Text(status).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Settings and plugins come from Slate Terminal. Settings changed here apply only to this app; Reset uses Slate Terminal’s value again. \(model.layoutAppName ?? "This app") keeps its own browser logins and plugin data.")
        }
    }

    private var generatedApps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generated Apps").font(.headline)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(model.layoutApps.enumerated()), id: \.offset) { _, value in
                        if let app = value.object, let id = app["layoutAppID"]?.string, let revision = app["revision"]?.string {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app["name"]?.string ?? "Layout app").lineLimit(1)
                                    Text(generatedAppStatus(app)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Refresh App") { model.refreshLayoutApp?(id, revision) }
                                    .disabled(model.parentManaged || app["available"] != .bool(true) || app["running"] == .bool(true))
                            }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { generatedAppsContentHeight = $0 }
            }.frame(height: min(generatedAppsContentHeight, 116))
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func generatedAppStatus(_ app: [String: JSONValue]) -> String {
        guard app["available"] == .bool(true) else { return "Unavailable" }
        let version = app["runtimeVersion"]?.string ?? "Unknown version"
        return version + (app["running"] == .bool(true) ? " · Running" : " · Not running") + (app["updateReady"] == .bool(true) ? " · Update ready" : "")
    }

    private var general: some View {
        Section {
            Toggle("Restore workspace on launch", isOn: $model.restore)
                .layoutOverrideReset(model: model, key: "layout.restore_workspace")
                .help("Restore open panels and their saved view state. Closing a panel removes it; shared plugin data is retained separately.")
        } footer: {
            Text("Restore tabs and split panes with new shell sessions.")
        }
    }

    private var notifications: some View {
        Group {
            Section {
                Toggle("Notify when long-running commands finish", isOn: $model.notifyAutomatic)
                    .layoutOverrideReset(model: model, key: "notifications.automatic")
                TextField("Minimum duration (seconds)", text: $model.notifyMinimumSeconds)
                    .layoutOverrideReset(model: model, key: "notifications.minimum_seconds")
                Toggle("Allow notifications from tools and plugins", isOn: $model.notifyTools)
                    .layoutOverrideReset(model: model, key: "notifications.tools")
            } footer: {
                Text("Command completion requires shell integration. Notifications from the focused pane are suppressed.")
            }
            Section {
                Picker("Desktop banners", selection: $model.notifyBanners) {
                    Text("From other panes").tag(NotificationPolicy.Banner.otherPanes)
                    Text("Only while using another app").tag(NotificationPolicy.Banner.otherApps)
                    Text("Off").tag(NotificationPolicy.Banner.off)
                }.layoutOverrideReset(model: model, key: "notifications.banners")
                Toggle("Play notification sounds", isOn: $model.notifySound)
                    .layoutOverrideReset(model: model, key: "notifications.sound")
                Toggle("Include command text in completion notifications", isOn: $model.notifyCommandDetails)
                    .layoutOverrideReset(model: model, key: "notifications.command_details")
            } footer: {
                Text("Command text can contain sensitive information and may appear on your lock screen. Unread indicators work without desktop permission.")
            }
            Section {
                LabeledContent("macOS permission", value: model.notificationAuthorizationLabel)
                if model.notificationAuthorization == "notDetermined" {
                    Button("Allow Desktop Notifications…") { model.authorizeNotifications?() }
                }
                Button("Open macOS Notification Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                }
            } footer: {
                Text("Permission changes apply immediately. Other changes require Apply. macOS Focus and notification preferences control final delivery.")
            }
        }
    }

    private var appearance: some View {
        Group {
            Section {
                Picker("Mode", selection: $model.theme) {
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                    Text("Auto").tag("system")
                }
                .pickerStyle(.segmented)
                .layoutOverrideReset(model: model, key: "appearance.theme")
            } header: { Text("Appearance") } footer: {
                Text("Auto follows your Mac’s appearance. Applies to the app and terminal panes.")
            }
            Section {
                HStack {
                    Slider(value: Binding(get: { model.unfocusedPaneDim },
                                          set: { model.unfocusedPaneDim = ($0 * 100).rounded() / 100 }), in: 0...1) {
                        Text("Unfocused pane dimming")
                    }
                        .accessibilityValue(Text(model.unfocusedPaneDim, format: .percent.precision(.fractionLength(0))))
                    Text(model.unfocusedPaneDim, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .layoutOverrideReset(model: model, key: "appearance.unfocused_pane_dim")
            } header: { Text("Pane dimming") } footer: {
                Text("Dims unselected panes in every window. 0% turns dimming off.")
            }
            Section {
                PalettePicker(title: "Light palette", selection: $model.lightTheme, customPalettes: model.customPalettes,
                              importAllowed: !model.parentManaged, importPalette: model.importPalette, reportError: { model.error = $0 })
                    .layoutOverrideReset(model: model, key: "terminal.light_theme")
                PalettePicker(title: "Dark palette", selection: $model.darkTheme, customPalettes: model.customPalettes,
                              importAllowed: !model.parentManaged, importPalette: model.importPalette, reportError: { model.error = $0 })
                    .layoutOverrideReset(model: model, key: "terminal.dark_theme")
            } header: { Text("Terminal colors") } footer: {
                Text(model.parentManaged ? "Custom palettes come from Slate Terminal. Choose Apply to use your selection in open terminals." : "Select Custom Palette… imports a color-only Ghostty palette into the config’s palettes folder. Choose Apply to use your selection in open terminals.")
            }
        }
    }

    private var terminal: some View {
        Group {
            Section {
                Toggle("New splits use the current directory", isOn: $model.inheritWorkingDirectory)
                    .layoutOverrideReset(model: model, key: "terminal.inherit_working_directory")
                if !model.inheritWorkingDirectory || model.overriddenKeys.contains("terminal.working_directory") {
                    terminalField("Default directory", text: $model.workingDirectory, key: "working_directory")
                }
            } header: { Text("Working directory") } footer: {
                if model.inheritWorkingDirectory {
                    Text("New splits start in the current terminal’s directory. Changes apply to new terminals.")
                } else {
                    Text("The default applies to new windows, tabs, and splits. Use ~ for home or an absolute path. Changes apply to new terminals.")
                }
            }
            Section {
                terminalField("Lines to keep", text: $model.savedOutputLines, key: "saved_output_lines")
            } header: { Text("Saved output") } footer: {
                Text("Keep up to 100,000 lines for reference after relaunch. Enter 0 to disable saving output. Terminals always start a fresh shell.")
            }
            Section {
                terminalField("Font family", text: $model.fontFamily, key: "font_family")
                terminalField("Size (points)", text: $model.fontSize, key: "font_size")
                Toggle("Thicken text", isOn: $model.fontThicken)
                    .layoutOverrideReset(model: model, key: "terminal.font_thicken")
                terminalField("Minimum contrast", text: $model.minimumContrast, key: "minimum_contrast")
            } header: { Text("Text") } footer: {
                Text("Contrast ranges from 1 (original colors) to 21. Higher values can turn low-contrast text black or white.")
            }
            Section {
                Picker("Shape", selection: $model.cursorStyle) {
                    Text("Block").tag(AppConfiguration.CursorStyle.block)
                    Text("Bar").tag(AppConfiguration.CursorStyle.bar)
                    Text("Underline").tag(AppConfiguration.CursorStyle.underline)
                    Text("Hollow block").tag(AppConfiguration.CursorStyle.blockHollow)
                }.layoutOverrideReset(model: model, key: "terminal.cursor_style")
                Picker("Blink", selection: $model.cursorBlink) {
                    Text("Automatic").tag(AppConfiguration.CursorBlink.auto)
                    Text("On").tag(AppConfiguration.CursorBlink.on)
                    Text("Off").tag(AppConfiguration.CursorBlink.off)
                }.layoutOverrideReset(model: model, key: "terminal.cursor_blink")
            } header: { Text("Cursor") } footer: {
                Text("Sets the default cursor. Shell integration and terminal programs can override it.")
            }
            Section {
                terminalField("Horizontal (points)", text: $model.paddingX, key: "padding_x")
                terminalField("Vertical (points)", text: $model.paddingY, key: "padding_y")
            } header: { Text("Padding") } footer: {
                Text("0–64 points on each side. Padding changes apply to new terminals.")
            }
            Section {
                terminalField("Shell", text: $model.shell, key: "shell")
                Picker("Shell integration", selection: $model.integration) {
                    Text("Automatic").tag("auto")
                    Text("Off").tag("off")
                }.layoutOverrideReset(model: model, key: "terminal.shell_integration")
            } header: { Text("Shell") } footer: {
                Text("Use an absolute executable path, such as /bin/zsh. zsh, bash and fish get automatic integration. Shell changes apply to new terminals.")
            }
        }
    }

    private func terminalField(_ title: String, text: Binding<String>, key: String) -> some View {
        let fieldError = model.error.flatMap {
            $0.hasPrefix("terminal." + key + " ") ? $0.replacingOccurrences(of: "terminal." + key, with: title) : nil
        }
        return VStack(alignment: .leading, spacing: 6) {
            TextField(title, text: text)
                .foregroundStyle(fieldError == nil ? Color.primary : Color.red)
                .accessibilityHint(fieldError ?? "")
            if let fieldError {
                Label(fieldError, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.layoutOverrideReset(model: model, key: "terminal." + key)
    }

    @ViewBuilder private var browser: some View {
        Section {
            TextField("Search URL", text: $model.searchURL)
                .layoutOverrideReset(model: model, key: "browser.search_url")
        } header: { Text("Search engine") } footer: {
            Text("Use {query} where the search text belongs. For example: https://www.google.com/search?q={query}")
        }
        Section {
            LabeledContent("Shared Browser profile") {
                Button("Clear All Browser Data…", role: .destructive) { model.clearBrowserData?() }
                    .disabled(model.clearingBrowserData)
            }
        } header: { Text("Website data") } footer: {
            Text("Remove cookies, caches and saved website storage for all sites. Private Browser panes and plugins are separate.")
        }
        Section {
            if model.loadingBrowserSites && model.browserSites.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Loading website data…") }
            } else if model.browserSites.isEmpty {
                Text("No stored website data.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.browserSites, id: \.self) { site in
                            Button { model.selectBrowserSite(site) } label: {
                                HStack {
                                    Text(site).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Image(systemName: model.selectedBrowserSite == site ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(model.selectedBrowserSite == site ? Color.accentColor : Color.secondary)
                                }
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityValue(model.selectedBrowserSite == site ? "Selected" : "")
                        }
                    }
                }
                .frame(height: min(CGFloat(model.browserSites.count) * 32, 160))
                .accessibilityLabel("Sites with stored data")
            }
            HStack {
                Button("Refresh Sites") { model.refreshBrowserSites?() }
                    .disabled(model.loadingBrowserSites)
                Spacer()
                Button("Clear Site Data…", role: .destructive) { model.clearBrowserSiteData?() }
                    .disabled(!model.canClearBrowserSite)
            }
            .disabled(model.clearingBrowserData)
            if model.clearingBrowserData {
                HStack { ProgressView().controlSize(.small); Text("Clearing website data…") }
            }
            if let message = model.browserDataMessage { Text(message).foregroundStyle(.secondary) }
            if let error = model.browserDataError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        } header: { Text("Clear a specific site") } footer: {
            Text("Stored sites in the shared Browser profile, including sites with no open panes. Private Browser data is separate. Clearing a site also removes data for subdomains grouped with it; open pages may save data again.")
        }
        .disabled(model.clearingBrowserData)
        .onAppear { model.refreshBrowserSites?() }
    }

    private var keyboard: some View {
        Section {
            ForEach(model.commands.filter { !["pane.type", "pane.focus", "tab.focus"].contains($0.id) }, id: \.id) { command in
                LabeledContent {
                    HStack(spacing: 8) {
                        ShortcutRecorder(shortcut: model.shortcut(for: command.id), action: command.title) { replacement in
                            model.assignShortcut(replacement, to: command.id)
                        }
                        .frame(width: 140, height: 24)
                        if model.parentManaged {
                            let keys = model.shortcutOverrideKeys(for: command.id)
                            if !keys.isEmpty {
                                Button("Reset") { model.resetOverride(keys) }.disabled(model.isDirty)
                                    .accessibilityLabel("Reset shortcut for \(command.title)")
                            }
                        } else {
                            Button { model.resetShortcut(for: command.id) } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                                .frame(width: 28, height: 24)
                                .help("Reset to default shortcut")
                                .accessibilityLabel("Reset shortcut for \(command.title)")
                        }
                    }
                } label: {
                    Text(command.title)
                }
            }
        } footer: {
            Text(model.parentManaged ? "Click a shortcut and press a new key combination. Escape cancels; Delete clears it. Reset uses Slate Terminal’s shortcut." : "Click a shortcut and press a new key combination. Escape cancels; Delete clears it. Reset restores the default shortcut.")
        }
    }

    private var emptyPlugins: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 44)).foregroundStyle(.secondary)
                    VStack(spacing: 8) {
                        Text("No Plugins").font(.title2.weight(.semibold))
                        Text(model.parentManaged ? "Plugins installed in Slate Terminal appear here." : "Install a plugin ZIP to add commands or panel types to Slate Terminal.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Install Plugin…") { model.registerPlugin?() }.disabled(model.parentManaged)
                    if !model.parentManaged { pluginRegistrationHint }
                }
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
        }
    }

    private var pluginRegistrationHint: some View {
        VStack(spacing: 6) {
            Text("You or an agent can also install plugin ZIPs from the command line:")
            Text("slate-term plugins register --package /path/to/plugin.zip")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        }
        .font(.callout).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var plugins: some View {
        Group {
            Section {
                ForEach(model.plugins) { plugin in
                    HStack(spacing: 12) {
                        Toggle("Enable \(plugin.title)", isOn: Binding(
                            get: { plugin.enabled },
                            set: { model.setPluginEnabled?(plugin.id, $0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .disabled(model.parentManaged)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.title)
                            Text(plugin.id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Image(systemName: plugin.indicator.symbol)
                            .foregroundStyle(plugin.indicator.color)
                            .help(plugin.status)
                            .accessibilityLabel("\(plugin.title): \(plugin.status)")
                        Menu {
                            Button("Delete Slate-managed Plugin Data…", role: .destructive) { model.deletePluginData?(plugin.id) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Data actions for \(plugin.title)")
                        .accessibilityLabel("Data actions for \(plugin.title)")
                        Button { model.removePlugin?(plugin.id) } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(model.parentManaged)
                        .help("Remove \(plugin.title). Saved plugin data and preferences are retained.")
                        .accessibilityLabel("Remove \(plugin.title)")
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Install Plugin…") { model.registerPlugin?() }.disabled(model.parentManaged)
                    Spacer()
                }
            } footer: {
                if !model.parentManaged { pluginRegistrationHint }
            }
        }
    }

    private var agents: some View {
        Group {
            Section {
                Toggle("Show agent activity on panes", isOn: $model.showAgentActivity)
                    .layoutOverrideReset(model: model, key: "agents.show_activity")
            } footer: {
                Text("Highlight panes and elements while a coding agent works on them through the Slate Terminal CLI. Only agents that identify themselves are shown.")
            }
            AgentColorSettings(colors: $model.agentColors)
            Section {
                ForEach(model.agentSkills, id: \.target.id) { entry in
                    LabeledContent {
                        if model.parentManaged {
                            Text("Managed by Slate Terminal").foregroundStyle(.secondary)
                        } else {
                          switch entry.status {
                        case .installed:
                            Button("Remove") { model.changeAgentSkill?(entry.target.id, false) }
                        case .notInstalled:
                            Button("Install") { model.changeAgentSkill?(entry.target.id, true) }
                        case .conflict:
                            Text("Another skill uses this name").foregroundStyle(.secondary)
                          }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.target.name)
                            if entry.status == .installed && !model.parentManaged {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Installed")
                            }
                        }
                        Text(model.parentManaged || entry.detected ? entry.target.detail : "\(entry.target.detail) · not set up")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Slate Terminal skill")
                    Text(model.parentManaged ? "Skills are managed by Slate Terminal." : "Install this skill so your coding agent knows how to use Slate Terminal, control panes, and build plugins.")
                        .font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // The skills folders are the source of truth and can change outside the app.
        // Re-read them when this section appears and whenever the app or window regains focus.
        .onAppear { model.refreshAgentSkills?() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshAgentSkills?() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in model.refreshAgentSkills?() }
    }

}

private struct LayoutOverrideReset: ViewModifier {
    @ObservedObject var model: SettingsModel
    let key: String

    @ViewBuilder func body(content: Content) -> some View {
        if model.parentManaged && model.overriddenKeys.contains(key) {
            HStack(spacing: 12) {
                content.frame(maxWidth: .infinity)
                Button("Reset") { model.resetOverride([key]) }
                    .disabled(model.isDirty)
                    .accessibilityLabel("Reset " + key)
                    .accessibilityIdentifier("settings.reset." + key)
            }
        } else { content }
    }
}

private extension View {
    func layoutOverrideReset(model: SettingsModel, key: String) -> some View {
        modifier(LayoutOverrideReset(model: model, key: key))
    }
}

private struct AgentColorSettings: View {
    @Binding var colors: [String: String]
    @State private var newAgent = ""
    @State private var error: String?

    private var names: [String] { Set(PresenceColor.known.keys).union(colors.keys).sorted() }

    var body: some View {
        Section {
            ForEach(names, id: \.self) { name in
                HStack {
                    ColorPicker(name, selection: binding(for: name), supportsOpacity: false)
                        .accessibilityIdentifier("settings.agentColor." + name)
                    if PresenceColor.known[name] != nil {
                        Button("Reset") { colors.removeValue(forKey: name) }
                            .disabled(colors[name] == nil)
                            .accessibilityLabel("Reset \(name) color")
                    } else {
                        Button("Remove", systemImage: "minus.circle") { colors.removeValue(forKey: name) }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("Remove \(name) color")
                    }
                }
            }
            HStack {
                TextField("Custom agent name", text: $newAgent)
                    .accessibilityIdentifier("settings.agentColor.name")
                Button("Add") { addAgent() }
                    .disabled(newAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || colors.count >= 64)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: { Text("Agent accent colors") } footer: {
            Text("Match the name your agent uses, such as codex or my-agent. Names with a : suffix share their agent’s color.")
        }
    }

    private func binding(for name: String) -> Binding<Color> {
        Binding(get: {
            let rgb = colors[name].flatMap { UInt32($0.dropFirst(), radix: 16) } ?? PresenceColor.rgb(for: name)
            return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                         green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
        }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            func component(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 255).rounded()) }
            colors[name] = String(format: "#%02X%02X%02X", component(rgb.redComponent), component(rgb.greenComponent), component(rgb.blueComponent))
        })
    }

    private func addAgent() {
        let name = newAgent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !names.contains(name) else { error = "This agent is already listed."; return }
        do {
            var updated = colors
            updated[name] = String(format: "#%06X", PresenceColor.rgb(for: name))
            colors = try AgentAccentColors.validate(updated)
            newAgent = ""
            error = nil
        } catch { self.error = String(describing: error) }
    }
}

private struct PalettePicker: View {
    let title: String
    @Binding var selection: String
    let customPalettes: [PaletteLibrary.Entry]
    var importAllowed = true
    let importPalette: (URL) throws -> String
    let reportError: (String) -> Void
    @State private var choosing = false

    var body: some View {
        Picker(title, selection: Binding(
            get: { selection },
            set: { value in
                if value == "/import" { chooseFile() }
                else { selection = value }
            }
        )) {
            ForEach(AppConfiguration.BundledTerminalTheme.allCases.sorted { $0.rawValue < $1.rawValue }, id: \.self) { theme in
                Text(theme.rawValue).tag(theme.rawValue)
            }
            if !customPalettes.isEmpty {
                Divider()
                ForEach(customPalettes) { palette in
                    Text(palette.name).tag(palette.name)
                }
            }
            if AppConfiguration.BundledTerminalTheme(rawValue: selection) == nil,
               !customPalettes.contains(where: { $0.name == selection }) {
                Text("\(selection) (unavailable)").tag(selection)
            }
            if importAllowed {
                Divider()
                Text("Select Custom Palette…").tag("/import")
            }
        }
        .disabled(choosing)
    }

    private func chooseFile() {
        guard importAllowed, !choosing else { return }
        choosing = true
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Import a color-only Ghostty palette into your config’s palettes folder."
        panel.prompt = "Import Palette"
        panel.begin { response in
            choosing = false
            guard response == .OK, let url = panel.url else { return }
            do { selection = try importPalette(url) }
            catch { reportError(String(describing: error)) }
        }
    }
}

@MainActor
private final class SettingsWindow: NSWindow {
    override func resignKey() {
        (firstResponder as? ShortcutButton)?.cancelRecording()
        super.resignKey()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let recorder = firstResponder as? ShortcutButton, recorder.isRecording {
            recorder.record(event)
            return true
        }
        // Settings is not a workspace: Command-W closes this window rather
        // than reaching the pane.close menu item (disabled here).
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let recorder = firstResponder as? ShortcutButton, recorder.isRecording {
            recorder.record(event)
            return
        }
        super.sendEvent(event)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: String?
    let action: String
    let onChange: (String?) -> Void

    func makeNSView(context: Context) -> ShortcutButton { ShortcutButton() }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.actionName = action
        button.shortcut = shortcut
        button.onChange = onChange
        button.setAccessibilityLabel("Shortcut for \(action)")
        button.updateTitle()
    }
}

@MainActor
private final class ShortcutButton: NSButton {
    var actionName = ""
    var shortcut: String?
    var onChange: ((String?) -> Void)?
    private(set) var isRecording = false

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        toolTip = "Click, then press a shortcut. Escape cancels; Delete removes it."
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true
        updateTitle()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        updateTitle()
        return super.resignFirstResponder()
    }

    func cancelRecording() {
        isRecording = false
        updateTitle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelRecording() }
    }

    func updateTitle() {
        if isRecording { title = "Press keys…"; return }
        guard let shortcut, let chord = try? KeyChord.parse(shortcut) else { title = "Record"; return }
        let symbols: [(KeyChord.Modifier, String)] = [(.ctrl, "⌃"), (.alt, "⌥"), (.shift, "⇧"), (.cmd, "⌘")]
        let keys = ["left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "escape": "⎋", "tab": "⇥", "space": "Space", "plus": "+"]
        title = symbols.filter { chord.modifiers.contains($0.0) }.map { $0.1 }.joined() + (keys[chord.key] ?? chord.key.uppercased())
    }

    func record(_ event: NSEvent) {
        guard event.type == .keyDown else { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 && modifiers.isEmpty {
            isRecording = false
            updateTitle()
            return
        }
        if event.keyCode == 51 && modifiers.isEmpty {
            isRecording = false
            onChange?(nil)
            updateTitle()
            return
        }
        let modifierNames: [(NSEvent.ModifierFlags, String)] = [(.command, "cmd"), (.shift, "shift"), (.option, "alt"), (.control, "ctrl")]
        guard var key = event.characters(byApplyingModifiers: [])?.lowercased(), !key.isEmpty else { return }
        if key == "+" { key = "plus" }
        let value = (modifierNames.filter { modifiers.contains($0.0) }.map { $0.1 } + [key]).joined(separator: "+")
        guard let parsed = try? KeyChord.parse(value) else { NSSound.beep(); return }
        isRecording = false
        onChange?(parsed.description)
        updateTitle()
    }
}
