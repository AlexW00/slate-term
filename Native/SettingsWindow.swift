import AppKit
import Combine
import SwiftUI
import SlateTermCore
import SlateTermSettings

@MainActor
final class SettingsModel: ObservableObject {
    struct Plugin: Identifiable {
        let id: String
        let title: String
        let status: String
    }
    @Published var selection: SettingsSection? = .general
    @Published var theme = "system"
    @Published var shell = ""
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
    @Published var shortcuts: [String: String] = [:]
    @Published var plugins: [Plugin] = []
    @Published var agentSkills: [AgentSkills.Entry] = []
    @Published var commands: [WorkspaceCommand] = CommandRegistry.commands
    @Published var error: String?
    @Published private var baseline: [String: String] = [:]
    private var source = ""
    let configURL: URL
    var save: ((String, [String: String]) throws -> Void)?
    var registerPlugin: (() -> Void)?
    var changeAgentSkill: ((String, Bool) -> Void)?
    var revealAgentSkill: (() -> Void)?
    var refreshAgentSkills: (() -> Void)?

    init(configURL: URL) { self.configURL = configURL }

    var values: [String: String] {
        var values = ["appearance.theme": AppConfiguration.quotedString(theme),
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
                      "browser.search_url": AppConfiguration.quotedString(searchURL)]
        for (chord, command) in shortcuts { values["keybind." + chord] = AppConfiguration.quotedString(command) }
        return values
    }
    var isDirty: Bool { values != baseline }

    func load(_ configuration: AppConfiguration, source: String, error: String?, force: Bool = false) {
        guard force || !isDirty || baseline.isEmpty else { return }
        let preserveError = !force && self.source == source && !baseline.isEmpty && error == nil
        theme = configuration.theme.rawValue
        shell = configuration.terminal.shell
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
        shortcuts = Dictionary(uniqueKeysWithValues: configuration.keyBindings.map { ($0.key.description, $0.value) })
        self.source = source
        if !preserveError { self.error = error }
        baseline = values
        do { customPalettes = try paletteLibrary.entries() }
        catch { self.error = String(describing: error) }
    }

    private var paletteLibrary: PaletteLibrary {
        PaletteLibrary(directory: configURL.deletingLastPathComponent().appendingPathComponent("palettes"))
    }

    func importPalette(from url: URL) throws -> String {
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
final class SettingsWindowController: NSWindowController {
    init(model: SettingsModel, reload: @escaping () -> Void) {
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 740, height: 520)
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model, reload: reload))
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { nil }

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
    case general = "General", appearance = "Appearance", terminal = "Terminal", browser = "Browser", shortcuts = "Keyboard Shortcuts", plugins = "Plugins", agents = "AI Agents"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .terminal: "terminal"
        case .browser: "globe"
        case .shortcuts: "keyboard"
        case .plugins: "puzzlepiece.extension"
        case .agents: "sparkles"
        }
    }
    var color: Color {
        switch self {
        case .general: .gray
        case .appearance: .indigo
        case .terminal: .black
        case .browser: .blue
        case .shortcuts: .purple
        case .plugins: .orange
        case .agents: .pink
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let reload: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $model.selection) { section in
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
                if model.selection == .plugins && model.plugins.isEmpty {
                    emptyPlugins
                } else {
                    Form {
                        switch model.selection ?? .general {
                        case .general: general
                        case .appearance: appearance
                        case .terminal: terminal
                        case .browser: browser
                        case .shortcuts: keyboard
                        case .plugins: plugins
                        case .agents: agents
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.automatic)
                }
                if let error = model.error {
                    Text(model.selection == .terminal && error.hasPrefix("terminal.")
                         ? "Check the highlighted setting before applying." : error)
                        .font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                Divider()
                HStack {
                    Button("Show Config File") {
                        NSWorkspace.shared.selectFile(model.configURL.path, inFileViewerRootedAtPath: model.configURL.deletingLastPathComponent().path)
                    }
                    Spacer()
                    Button("Revert", action: reload).disabled(!model.isDirty && model.error == nil)
                    Button("Apply") { model.apply() }.disabled(!model.isDirty)
                        .keyboardShortcut("s", modifiers: .command)
                }.padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var general: some View {
        Section {
            Toggle("Restore workspace on launch", isOn: $model.restore)
        } footer: {
            Text("Restore tabs and split panes with new shell sessions.")
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
            } header: { Text("Appearance") } footer: {
                Text("Auto follows your Mac’s appearance. Applies to the app and terminal panes.")
            }
            Section {
                PalettePicker(title: "Light palette", selection: $model.lightTheme, customPalettes: model.customPalettes,
                              importPalette: model.importPalette, reportError: { model.error = $0 })
                PalettePicker(title: "Dark palette", selection: $model.darkTheme, customPalettes: model.customPalettes,
                              importPalette: model.importPalette, reportError: { model.error = $0 })
            } header: { Text("Terminal colors") } footer: {
                Text("Select Custom Palette… imports a color-only Ghostty palette into the config’s palettes folder. Choose Apply to use your selection in open terminals.")
            }
        }
    }

    private var terminal: some View {
        Group {
            Section {
                terminalField("Font family", text: $model.fontFamily, key: "font_family")
                terminalField("Size (points)", text: $model.fontSize, key: "font_size")
                Toggle("Thicken text", isOn: $model.fontThicken)
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
                }
                Picker("Blink", selection: $model.cursorBlink) {
                    Text("Automatic").tag(AppConfiguration.CursorBlink.auto)
                    Text("On").tag(AppConfiguration.CursorBlink.on)
                    Text("Off").tag(AppConfiguration.CursorBlink.off)
                }
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
                }
            } header: { Text("Shell") } footer: {
                Text("Use an absolute executable path, such as /bin/zsh. Shell changes apply to new terminals.")
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
        }
    }

    private var browser: some View {
        Section {
            TextField("Search URL", text: $model.searchURL)
        } header: { Text("Search engine") } footer: {
            Text("Use {query} where the search text belongs. For example: https://www.google.com/search?q={query}")
        }
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
                        Button { model.resetShortcut(for: command.id) } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                            .frame(width: 28, height: 24)
                            .help("Reset to default shortcut")
                            .accessibilityLabel("Reset shortcut for \(command.title)")
                    }
                } label: {
                    Text(command.title)
                }
            }
        } footer: {
            Text("Click a shortcut and press a new key combination. Escape cancels; Delete clears it. Reset restores the default shortcut.")
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
                        Text("Register a plugin to add commands or panel types to Slate Terminal.")
                            .foregroundStyle(.secondary)
                    }
                    Button("Register Plugin…") { model.registerPlugin?() }
                    pluginRegistrationHint
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
            Text("You or an agent can also register plugins from the command line:")
            Text("slate-term plugins register --manifest /path/to/plugin.json")
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
                    LabeledContent {
                        Text(plugin.status).foregroundStyle(.secondary)
                    } label: {
                        Text(plugin.title)
                        Text(plugin.id).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Register Plugin…") { model.registerPlugin?() }
                    Spacer()
                }
            } footer: {
                pluginRegistrationHint
            }
        }
    }

    private var agents: some View {
        Group {
            Section {
                ForEach(model.agentSkills, id: \.target.id) { entry in
                    LabeledContent {
                        switch entry.status {
                        case .installed:
                            Button("Remove") { model.changeAgentSkill?(entry.target.id, false) }
                        case .notInstalled:
                            Button("Install") { model.changeAgentSkill?(entry.target.id, true) }
                        case .conflict:
                            Text("Another skill uses this name").foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.target.name)
                            if entry.status == .installed {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Installed")
                            }
                        }
                        Text(entry.detected ? entry.target.detail : "\(entry.target.detail) · not set up")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Slate Terminal skill")
                    Text("Teaches coding agents to automate Slate Terminal and build plugins. Most agents read the shared folder; Claude Code needs its own.")
                        .font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Open Skill Folder") { model.revealAgentSkill?() }
                    Spacer()
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

private struct PalettePicker: View {
    let title: String
    @Binding var selection: String
    let customPalettes: [PaletteLibrary.Entry]
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
            Divider()
            Text("Select Custom Palette…").tag("/import")
        }
        .disabled(choosing)
    }

    private func chooseFile() {
        guard !choosing else { return }
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
        guard let shortcut, let chord = try? KeyChord.parse(shortcut) else { title = "Record Shortcut…"; return }
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
