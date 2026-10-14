import AppKit
import UniformTypeIdentifiers
import SlateTermCore
import SlateTermIPC
import SlateTermSettings

@MainActor
final class WorkspaceHost: NSObject, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    // Internal access is limited to the typed WorkspaceHost API adapters in this module.
    var workspace = Workspace()
    let instanceID: String
    let events: EventControl
    lazy var revisions = WorkspaceRevisions(epoch: instanceID, workspace: workspace)
    private var publishedWorkspace: Workspace?
    var shellSessions: [PaneID: ShellSession] = [:]
    private var pluginCatalog: PluginCatalog
    private let pluginInstances: PluginInstances
    private let pluginCommands = PluginCommands()
    private var headerActionRevisions: [String: UUID] = [:]
    private let runtime: GhosttyRuntime
    private var server: UnixServer?
    var windows: [TabID: WorkspaceWindow] = [:]
    var leaves: [PaneID: NSViewController] = [:]
    var containers: [PaneID: PaneContainer] = [:]
    private let processTitles = TerminalProcessTitles()
    private var titleTimer: DispatchSourceTimer?
    private var processNames: [PaneID: String] = [:]
    private var shellNames: [PaneID: String] = [:]
    var terminals: [PaneID: TerminalView] = [:]
    private lazy var terminalControl = TerminalControl { [weak self] pane in
        guard let self, let view = self.terminals[pane], let session = self.shellSessions[pane] else { return nil }
        return TerminalControl.Target(paneID: pane, sessionID: session.instanceID, runKey: session.runKey, view: view, report: session.report)
    }
    var rendered: [TabID: Layout] = [:]
    var renderedZoom: [TabID: PaneID] = [:]
    private var reconciling = false
    private let integration: Bool
    private var integrationKeyboardMonitor: Any?
    private var dispatchingTestKey = false
    let settings: ApplicationSettings
    var configurationRevisionSource: String?
    var configurationSourceRevision = UUID().uuidString
    var appliedConfigurationRevision = UUID().uuidString
    private var configurationWatcher: ConfigurationWatcher?
    private var appearanceObservation: NSKeyValueObservation?
    private var settingsWindow: SettingsWindowController?
    private var commandPicker: CommandPicker?
    private var pickerTarget: [String: JSONValue] = [:]
    private var pickerReturnPane: PaneID?
    private var testPasteboard: NSPasteboard?
    private var commandPasteboard: NSPasteboard {
        if !integration { return .general }
        if let testPasteboard { return testPasteboard }
        let board = NSPasteboard.withUniqueName()
        testPasteboard = board
        return board
    }
    private var settingsModel: SettingsModel?
    private var statusMenuItem: NSMenuItem?
    private var workspaceShortcuts: NSMenu?
    private var testConfirmationHandler: ((NSAlert) -> Void)?
    private var paneTypeMenu: NSMenu?
    private var tabGroupObservations: [ObjectIdentifier: (group: NSWindowTabGroup, token: NSKeyValueObservation)] = [:]
    private var tabGroupSyncScheduled = false

    init(startingWith workspace: Workspace = Workspace()) throws {
        let environment = ProcessInfo.processInfo.environment
        let integration = environment["SLATE_TERM_INTEGRATION"] == "1"
        self.integration = integration
        let epoch = UUID()
        instanceID = epoch.uuidString
        events = try EventControl(epoch: epoch)
        let settings = try ApplicationSettings(environment: environment, integration: integration)
        self.settings = settings
        let catalog = try PluginCatalog(directory: settings.base.appendingPathComponent("state"))
        pluginCatalog = catalog
        pluginInstances = PluginInstances(directory: settings.base.appendingPathComponent("state/plugin-data"))
        self.workspace = settings.restore(or: workspace, registeredTypes: Set(catalog.registrations.filter(\.hasPanel).map(\.id)))
        // An app launched from another Slate pane must not pass that app's routing,
        // command settings or shell credentials to its new surfaces. Ghostty inherits
        // the process environment before applying explicit per-surface overrides.
        let inheritedIdentity = Set(["SLATE_TERM_CLI", "SLATE_TERM_SOCKET", "SLATE_TERM_INSTANCE_ID", "SLATE_TERM_PANE_ID", "SLATE_TERM_TAB_ID",
                                     "SLATE_TERM_SESSION_ID", "SLATE_TERM_CONTEXT_TOKEN", "SLATE_TERM_RUN_KEY", "SLATE_TERM_SHELL_PID", "SLATE_TERM_INVOCATION_ID"])
        for key in environment.keys where inheritedIdentity.contains(key) || key.hasPrefix("SLATE_TERM_PLUGIN_") || key.hasPrefix("SLATE_TERM_COMMAND_") {
            unsetenv(key)
        }
        runtime = try GhosttyRuntime(configurationURL: settings.engineURL)
        super.init()
        _ = revisions // Seed before the first mutation, including native/legacy paths.
        pluginCommands.onChange = { [weak self] in self?.refreshSettings(); self?.refreshCommandPicker(); self?.refreshHeaderActions() }
        pluginInstances.onEvent = { [weak self] instance, name, value in
            guard let self else { return }
            self.refreshSettings()
            var payload: [String: JSONValue] = ["instanceId": .string(instance.id), "type": .string(instance.registration.id)]
            if name == "storageChanged" {
                payload["key"] = value.object?["key"]
                self.events.publishHost("host.plugin.storage.changed", payload: .object(payload), targetInstanceId: instance.id)
            } else if name == "stateChanged" {
                payload["state"] = value.object?["state"]
                self.events.publishHost("host.plugin.state.changed", payload: .object(payload), tab: instance.tab)
            }
        }
    }

    func start() throws {
        if integration {
            // Owned integration windows must not execute the user's typing.
            integrationKeyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
                MainActor.assumeIsolated { self?.dispatchingTestKey == true ? event : nil }
            }
        }
        let environment = ProcessInfo.processInfo.environment
        server = try UnixServer(directory: settings.base.appendingPathComponent("control")) { [weak self] method, params in
            guard let self else { throw SocketError.disconnected }
            return try await self.callAsync(method, params: params)
        }
        pluginInstances.connect(socketPath: server!.path, appInstanceID: instanceID)
        buildMenus()
        applyAppearance()
        var initial = workspace
        // Closing the last window saves a valid empty workspace. A fresh launch
        // still needs a terminal, while retaining the saved identity counters.
        if initial.tabs.isEmpty { try initial.newTab() }
        try reconcile(initial)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refreshTerminalTitles() } }
        timer.resume()
        titleTimer = timer
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateTerminalAppearance() }
        }
        configurationWatcher = try ConfigurationWatcher(url: settings.configURL) { [weak self] in
            do { _ = try self?.reloadConfiguration() }
            catch { NSLog("Configuration reload rejected; see Configuration & Workspace Status") }
        }
        // Re-read after arming observation so edits during terminal startup are
        // not lost between the initial settings read and watcher attachment.
        do { _ = try reloadConfiguration() }
        catch { NSLog("Configuration reload rejected; see Configuration & Workspace Status") }
        if integration, let file = environment["SLATE_TERM_SOCKET_FILE"], let path = server?.path {
            try path.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }

    func close() {
        if !windows.isEmpty {
            do { try synchronizeNativeGroups() }
            catch { NSLog("Final native tab synchronization failed: %@", String(describing: error)) }
        }
        persistWorkspace()
        if let integrationKeyboardMonitor { NSEvent.removeMonitor(integrationKeyboardMonitor) }
        integrationKeyboardMonitor = nil
        testPasteboard?.releaseGlobally()
        testPasteboard = nil
        titleTimer?.cancel(); titleTimer = nil
        configurationWatcher?.close()
        configurationWatcher = nil
        appearanceObservation = nil
        tabGroupObservations.removeAll()
        reconciling = true
        server?.close()
        server = nil
        events.close()
        terminalControl.close()
        terminals.values.forEach { $0.close() }
        leaves.values.compactMap { $0 as? BrowserPane }.forEach { $0.close() }
        leaves.values.compactMap { $0 as? PluginPane }.forEach { $0.close() }
        pluginInstances.close()
        pluginCommands.close()
        terminals.removeAll()
        shellSessions.removeAll()
        leaves.removeAll()
        containers.removeAll()
        windows.values.forEach { $0.close() }
        windows.removeAll()
        settingsWindow?.close()
        commandPicker?.dismiss(restoreFocus: false)
        commandPicker = nil
        runtime.close()
    }

    func setApplicationFocused(_ focused: Bool) { runtime.setFocused(focused) }

    func showWorkspaceWindow() {
        if let tab = workspace.keyTabID, let window = windows[tab] {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            runUserCommand("window.new", params: [:])
        }
    }

    private func reloadConfiguration(prepared: ApplicationSettings.PreparedConfiguration? = nil) throws -> JSONValue {
        defer { buildMenus(); refreshSettings() }
        let previous = settings.current
        let result = try settings.reload(prepared: prepared) { try runtime.reload(from: $0) }
        if !settings.current.changedKeys(from: previous).isEmpty {
            appliedConfigurationRevision = UUID().uuidString
            events.publishHost("host.settings.changed", payload: .object(["appliedRevision": .string(appliedConfigurationRevision)]))
            for instance in pluginInstances.all where previous.plugins[instance.registration.id] != settings.current.plugins[instance.registration.id] {
                events.publishHost("host.plugin.settings.changed", payload: .object(["pluginId": .string(instance.registration.id)]), targetInstanceId: instance.id)
            }
        }
        applyAppearance()
        for browser in leaves.values.compactMap({ $0 as? BrowserPane }) { browser.browserConfiguration = settings.current.browser }
        persistWorkspace()
        return result
    }

    private func applyAppearance() {
        switch settings.current.theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        updateTerminalAppearance()
    }

    private func updateTerminalAppearance() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        runtime.setColorScheme(dark: dark, terminals: Array(terminals.values))
    }

    private func persistWorkspace() {
        publishWorkspaceChanges()
        settings.save(workspace)
        updateStatusMenu()
        if let paneTypeMenu { menuNeedsUpdate(paneTypeMenu) }
        refreshCommandPicker()
        if publishedWorkspace != workspace {
            publishedWorkspace = workspace
            events.publishHost("host.workspace.changed", payload: .object([
                "keyTabId": workspace.keyTabID.map { .string($0.description) } ?? .null
            ]))
        }
    }

    func updateStatusMenu() {
        statusMenuItem?.title = settings.error != nil || settings.workspaceError != nil || settings.preferenceError != nil || settings.typeWarningError != nil
            ? "Configuration or Workspace Error…" : "Configuration & Workspace Status…"
    }

    @objc private func showSettingsStatus() {
        let alert = NSAlert()
        alert.messageText = "Configuration & Workspace Status"
        alert.informativeText = [settings.configURL.path, settings.error, settings.workspaceError, settings.preferenceError, settings.typeWarningError,
                                "Shell and padding changes take effect in new terminals; existing shells are not restarted."]
            .compactMap { $0 }.joined(separator: "\n\n")
        alert.runModal()
    }

    func confirmTermination() -> Bool {
        !terminals.values.contains(where: \.needsConfirmClose) || confirm("Quit and terminate running processes?")
    }

    var availableCommands: [WorkspaceCommand] {
        CommandRegistry.commands + pluginCatalog.registrations.flatMap(\.workspaceCommands)
    }
    private var unavailableCommands: [String] {
        let known = Set(availableCommands.map(\.id))
        return Set(settings.current.keyBindings.values).subtracting(known).sorted()
    }
    private var activeKeyBindings: [KeyChord: String] {
        let known = Set(availableCommands.map(\.id))
        return settings.current.keyBindings.filter { known.contains($0.value) }
    }

    /// Freeze routing and settings before yielding, including for menu/keyboard invocations.
    private func preparePluginCommand(_ id: String, params: [String: JSONValue], resolveWorkspace: Bool = true) throws -> () async throws -> JSONValue {
        try synchronizeNativeGroups()
        guard let registration = pluginCatalog.registrations.first(where: { registration in registration.commands.contains { $0.namespacedID(plugin: registration.id) == id } }) else {
            throw RPCFailure(code: -32601, message: "Unknown plugin command: \(id)")
        }
        let command = registration.commands.first { $0.namespacedID(plugin: registration.id) == id }!
        guard let socketPath = server?.path else { throw RPCFailure(code: -32022, message: "Application is closing") }
        let pane: PaneID?
        let tab: TabID?
        if resolveWorkspace && (params["pane"] != nil || params["tab"] != nil || workspace.keyTabID != nil) {
            pane = try targetPaneID(params)
            tab = workspace.tabs.first { $0.layout.paneIDs.contains(pane!) }!.id
            if params["tab"] != nil, try targetTab(params).id != tab {
                throw RPCFailure(code: -32602, message: "Pane does not belong to the requested tab")
            }
        } else { pane = nil; tab = nil }
        var invocation = params
        invocation["pane"] = pane.map { .string($0.description) }
        invocation["tab"] = tab.map { .string($0.description) }
        let connection = PluginControlConnection(socketPath: socketPath, appInstanceID: instanceID,
            cliPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/slate-term").path)
        let preferences = settings.current.plugins[registration.id] ?? [:]
        return { [weak self, invocation] in
            guard let self, self.server?.path == socketPath,
                  self.pluginCatalog.registrations.contains(registration) else {
                throw RPCFailure(code: -32022, message: "Plugin registration or application closed")
            }
            return try await self.pluginCommands.execute(plugin: registration, command: command, connection: connection,
                tab: tab, pane: pane, params: invocation, settings: preferences)
        }
    }

    private func callAsync(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        var params = params
        if let reference = params.removeValue(forKey: "contextPane") {
            guard params["pane"] == nil, params["tab"] == nil else { throw RPCFailure(code: -32602, message: "Context anchor cannot be combined with a target") }
            let pane = try targetPaneID(["pane": reference])
            params["tab"] = .string(workspace.tabs.first { $0.layout.paneIDs.contains(pane) }!.id.description)
        }
        try validateAPIGuards(params, method: method)
        if method == "command.run", let id = params["id"]?.string, id.hasPrefix("plugin.") {
            let operation = try preparePluginCommand(id, params: params)
            return try await operation()
        }
        if method.hasPrefix("terminal.") {
            let pane = try terminalPane(params)
            var input = withoutAPIGuards(params)
            if input["sessionId"] == nil { input["sessionId"] = params["expectedAnchorSessionId"] }
            return try await terminalControl.call(String(method.dropFirst("terminal.".count)), pane: pane, params: input)
        }
        if method.hasPrefix("events.") {
            try synchronizeNativeGroups()
            params = withoutAPIGuards(params)
            switch method {
            case "events.head":
                guard params.isEmpty else { throw RPCFailure(code: -32602, message: "events.head takes no parameters") }
                return events.head
            case "events.poll": return try await events.poll(params)
            case "events.emit": return try events.emit(params, source: .client, knownInstances: Set(pluginInstances.all.map(\.id)))
            default: throw RPCFailure(code: -32601, message: "Unknown event method: \(method)")
            }
        }
        if method == "plugins.restart" {
            guard let type = params["id"]?.string else { throw RPCFailure(code: -32602, message: "Plugin id is required") }
            let instances = pluginInstances.all.filter { $0.registration.id == type }
            guard !instances.isEmpty else { throw RPCFailure(code: -32602, message: "Plugin has no active instances") }
            await withTaskGroup(of: Void.self) { group in
                for instance in instances { group.addTask { await instance.restart() } }
            }
            return .array(instances.map(\.info))
        }
        if method == "debug.pluginEval", integration {
            guard let pane = leaves[try targetPaneID(params)] as? PluginPane, let source = params["script"]?.string else { throw RPCFailure(code: -32602, message: "Plugin pane and script are required") }
            return try await pane.evaluateForTesting(source)
        }
        guard method.hasPrefix("browser.") else { return try call(method, params: params) }
        let pane = try targetPaneID(params)
        guard let browser = leaves[pane] as? BrowserPane else { throw RPCFailure(code: -32602, message: "Target pane is not a browser") }
        params["pane"] = .string(pane.description)
        params["tab"] = .string(try targetTab(params).id.description)
        let captured = params
        let precondition: @MainActor () throws -> Void = { [weak self, weak browser] in
            guard let self, let browser, self.leaves[pane] === browser else { throw RPCFailure(code: -32022, message: "Browser pane was replaced") }
            try self.validateAPIGuards(captured, method: method)
        }
        params = withoutAPIGuards(params)
        switch method {
        case "browser.get": return browser.info
        case "browser.snapshot", "browser.click", "browser.fill", "browser.select", "browser.scroll", "browser.wait":
            return try await browser.automate(BrowserAction(kind: String(method.dropFirst("browser.".count)), params: params), beforeSubmission: precondition)
        case "browser.navigate":
            guard let url = params["url"]?.string else { throw RPCFailure(code: -32602, message: "url is required") }
            return try await browser.navigate(url, beforeSubmission: precondition)
        case "browser.eval":
            guard let script = params["script"]?.string else { throw RPCFailure(code: -32602, message: "script is required") }
            return try await browser.evaluate(script, beforeSubmission: precondition)
        case "browser.screenshot":
            guard let path = params["path"]?.string else { throw RPCFailure(code: -32602, message: "path is required") }
            return try await browser.screenshot(to: path, beforeSubmission: precondition)
        default: throw RPCFailure(code: -32601, message: "Unknown browser method: \(method)")
        }
    }

    private func call(_ method: String, params: [String: JSONValue]) throws -> JSONValue {
        try synchronizeNativeGroups()
        try validateAPIGuards(params, method: method)
        switch method {
        case "api.describe": return try describeAPI()
        case "workspace.snapshot": return try workspaceSnapshot(params)
        case "context.inspect": return try inspectContext(params)
        case "pane.inspect": return try inspectPane(targetPaneID(params))
        case "config.patch": return try patchConfiguration(params)
        case "palette.list": return try listPalettes()
        case "palette.import": return try importPalette(params)
        case "version": return .object(["cliVersion": .string("0.1.0-dev"), "appVersion": .string("0.1.0-dev"), "protocolVersion": .integer(1)])
        case "tabs.list": return try .encoding(workspace.tabs)
        case "panes.list": return try .encoding(workspace.panes)
        case "plugins.list": return try .encoding(pluginCatalog.registrations)
        case "plugins.status":
            return .array((pluginInstances.all.map(\.info) + pluginCommands.all).filter { params["id"]?.string == nil || $0.object?["type"] == params["id"] })
        case "plugins.logs":
            if let id = params["instanceId"]?.string, let logs = pluginCommands.logs(instanceID: id) { return .object(["text": .string(logs)]) }
            guard let instance = pluginInstances.all.first(where: { $0.id == params["instanceId"]?.string }) else { throw RPCFailure(code: -32602, message: "An active instanceId is required") }
            return .object(["text": .string(instance.logs)])
        case "plugins.register":
            guard let manifest = params["manifest"] else { throw RPCFailure(code: -32602, message: "manifest is required") }
            let registration = try PluginRegistration.parse(JSONEncoder().encode(manifest))
            guard !workspace.panes.contains(where: { $0.type == .registered(registration.id) }) else { throw RPCFailure(code: -32010, message: "Close or change this type's panes before replacing its registration") }
            if case .directory(let path, _) = registration.source {
                let encodedPath = URLComponents(url: registration.entryURL!, resolvingAgainstBaseURL: false)!.percentEncodedPath
                _ = try PluginAssets(root: URL(fileURLWithPath: path)).file(forPercentEncodedPath: encodedPath)
            }
            try pluginCatalog.register(registration, replace: params["replace"] == .bool(true))
            headerActionRevisions[registration.id] = UUID()
            pluginInstances.remove(type: registration.id)
            pluginCommands.remove(plugin: registration.id)
            buildMenus()
            refreshSettings()
            events.publishHost("host.plugins.changed", payload: .object(["type": .string(registration.id), "registered": .bool(true)]))
            return try .encoding(registration)
        case "plugins.unregister":
            guard let id = params["id"]?.string, pluginCatalog.registrations.contains(where: { $0.id == id }) else { throw RPCFailure(code: -32602, message: "A registered plugin id is required") }
            let using = workspace.panes.filter { $0.type == .registered(id) }.map(\.id)
            guard using.isEmpty || params["force"] == .bool(true) else { throw RPCFailure(code: -32010, message: "Plugin is in use; pass --force to close its panes") }
            var next = workspace
            for pane in using { try next.close(pane) }
            // Persist before irreversible teardown. This reconciliation only
            // removes existing views, so it needs no new fallible resources.
            try pluginCatalog.remove(id)
            headerActionRevisions.removeValue(forKey: id)
            if !using.isEmpty { try reconcile(next) }
            pluginInstances.remove(type: id)
            pluginCommands.remove(plugin: id)
            buildMenus()
            refreshSettings()
            events.publishHost("host.plugins.changed", payload: .object(["type": .string(id), "registered": .bool(false)]))
            return .object([:])
        case "context.get": return try context(params)
        case "shell.runInput":
            let pane = try targetPaneID(params)
            guard let session = shellSessions[pane], let token = params["token"]?.string,
                  case .integer(let pid) = params["pid"], case .bool(let empty) = params["emptyBuffer"] else {
                throw RPCFailure(code: -32602, message: "Shell run input requires a token, pid and buffer state")
            }
            try session.authenticate(token: token, pid: pid)
            return .string(try terminalControl.claimInput(pane: pane, sessionID: session.instanceID, emptyBuffer: empty))
        case "shell.update":
            let pane = try targetPaneID(params)
            guard terminals[pane] != nil, var session = shellSessions[pane], let token = params["token"]?.string else {
                throw RPCFailure(code: -32040, message: "Shell session is unavailable")
            }
            let report = try JSONDecoder().decode(ShellReport.self, from: JSONEncoder().encode(JSONValue.object(params)))
            try session.accept(report, token: token)
            shellSessions[pane] = session
            terminalControl.observe(pane: pane, sessionID: session.instanceID, report: report)
            processTitles.bind(pane: pane, pid: pid_t(report.pid))
            refreshTerminalTitles()
            publishTerminalContext(pane, reason: "shell")
            return .object(["sequence": .integer(report.sequence)])
        case "workspace.get": return try JSONDecoder().decode(JSONValue.self, from: workspace.encoded())
        case "layout.get": return try .encoding(targetTab(params).layout)
        case "command.list": return try .encoding(availableCommands)
        case "config.get":
            var status = try settings.status().object!
            status["unavailableCommands"] = .array(unavailableCommands.map(JSONValue.string))
            status.merge(configurationRevisionInfo()) { _, new in new }
            return .object(status)
        case "config.validate": return .object(["valid": .bool(true), "configuration": try .encoding(settings.validate())])
        case "config.reload": return try reloadConfiguration()
        case "command.run":
            guard let id = params["id"]?.string else { throw RPCFailure(code: -32602, message: "Command id is required") }
            if let result = try runSettingsCommand(id, params: params) { return result }
            if id == "config.reload" { return try reloadConfiguration() }
            if id == "settings.open" { showSettings(); return .object([:]) }
            if id == "command.picker" { try toggleCommandPicker(params); return .object([:]) }
            if id == "pane.copyID" {
                let pane = try targetPaneID(params)
                let board = commandPasteboard
                board.clearContents()
                guard board.setString(pane.description, forType: .string) else { throw RPCFailure(code: -32000, message: "Could not copy pane ID") }
                return .object(["paneId": .string(pane.description)])
            }
            if id.hasPrefix("browser.") {
                guard let browser = leaves[try targetPaneID(params)] as? BrowserPane else {
                    throw RPCFailure(code: -32602, message: "Target pane is not a browser")
                }
                try browser.performCommand(id)
                return .object([:])
            }
            if id == "pane.type", !(["terminal", "browser"] + pluginCatalog.registrations.filter(\.hasPanel).map(\.id)).contains(params["type"]?.string ?? "") {
                throw RPCFailure(code: -32602, message: "Unknown pane type")
            }
            var next = workspace
            let result = try CommandRegistry.execute(id, params: params, workspace: &next)
            let remaining = Set(next.panes.filter { pane in workspace.panes.contains(where: { $0 == pane }) }.map(\.id))
            if params["force"] != .bool(true), terminals.contains(where: { !remaining.contains($0.key) && $0.value.needsConfirmClose }) {
                throw RPCFailure(code: -32010, message: "The terminal may have a running process; pass --force to terminate it")
            }
            try reconcile(next)
            return result
        case "panes.send":
            guard let text = params["text"]?.string else { throw RPCFailure(code: -32602, message: "text is required") }
            try targetTerminal(params).send(text)
            return .object([:])
        case "panes.capture": return try .encoding(TerminalOutput(targetTerminal(params).capture()))
        case "debug.inspect" where integration: return inspect()
        case "debug.commandClipboard" where integration: return commandPasteboard.string(forType: .string).map(JSONValue.string) ?? .null
        case "debug.menuTree" where integration:
            func entries(_ menu: NSMenu) -> JSONValue {
                .array(menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { item in
                    .object(["title": .string(item.title), "key": .string(item.keyEquivalent),
                             "modifiers": .integer(Int(item.keyEquivalentModifierMask.rawValue)),
                             "command": (item.representedObject as? String).map(JSONValue.string) ?? .null,
                             "children": item.submenu.map(entries) ?? .array([])])
                })
            }
            return NSApp.mainMenu.map(entries) ?? .array([])
        case "debug.closeConfirmation" where integration:
            let answer = params["answer"]?.string ?? "cancel"
            testConfirmationHandler = { alert in
                alert.suppressionButton?.state = params["suppress"] == .bool(true) ? .on : .off
                if let path = params["screenshot"]?.string {
                    try? Self.captureWindow(alert.window.windowNumber, path: path)
                }
                alert.buttons[answer == "terminate" ? 1 : 0].performClick(nil)
            }
            defer { testConfirmationHandler = nil }
            if params["quit"] == .bool(true) { return .bool(confirmTermination()) }
            runUserCommand(params["id"]?.string ?? "pane.close", params: params)
            return .object([:])
        case "debug.resetCloseWarnings" where integration:
            resetCloseWarnings()
            return .object([:])
        case "debug.menuPreview" where integration:
            guard let path = params["path"]?.string, let window = windows[try targetTab(params).id] else {
                throw RPCFailure(code: -32602, message: "path and a workspace window are required")
            }
            let container = params["pane"] == nil ? nil : containers[try targetPaneID(params)]
            let menu: NSMenu
            if let container { menu = params["move"] == .bool(true) ? (container.moveMenu?() ?? NSMenu()) : container.makeTypeMenu() }
            else if let mainMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == params["menu"]?.string })?.submenu { menu = mainMenu }
            else { throw RPCFailure(code: -32602, message: "menu or pane is required") }
            let preview: NSMenu
            if let child = params["submenu"]?.string, let submenu = menu.items.first(where: { $0.title == child })?.submenu { preview = submenu }
            else { preview = menu }
            menuNeedsUpdate(preview)
            let popupMenu = preview.copy() as! NSMenu
            var captureError: (any Error)?
            var captured = false
            let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
                MainActor.assumeIsolated {
                    defer { popupMenu.cancelTracking() }
                    do {
                        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                        guard let popup = windows.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }),
                              let number = popup[kCGWindowNumber as String] as? Int else {
                            throw RPCFailure(code: -32000, message: "Owned menu window not found")
                        }
                        try Self.captureWindow(number, path: path)
                        captured = true
                    } catch { captureError = error }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            defer { timer.invalidate() }
            if let container {
                if params["move"] == .bool(true) { container.presentMoveMenu(popupMenu) }
                else { container.presentTypeMenu(popupMenu) }
            }
            else { popupMenu.popUp(positioning: nil, at: NSPoint(x: 40, y: max(40, (window.contentView?.bounds.height ?? 200) - 40)), in: window.contentView) }
            if let captureError { throw captureError }
            guard captured else { throw RPCFailure(code: -32000, message: "Menu closed before capture") }
            return .object([:])
        case "debug.paneHeader" where integration:
            let pane = try targetPaneID(params)
            guard let header = containers[pane] else { throw RPCFailure(code: -32004, message: "Pane header not found") }
            if let title = params["rename"]?.string { try header.editTitleForTesting(title, finish: "commit") }
            if params["beginRename"] == .bool(true) || params["draft"] != nil || params["finish"] != nil {
                try header.editTitleForTesting(params["draft"]?.string, finish: params["finish"]?.string)
            }
            if params["close"] == .bool(true) { header.performClose() }
            var info = header.info.object!
            if let action = params["clickAction"]?.string { try header.clickHeaderActionForTesting(action); info = header.info.object! }
            return .object(info)
        case "debug.paneMove" where integration:
            let sourceID = try targetPaneID(params)
            guard let source = containers[sourceID]?.dragHandle,
                  let targetValue = params["target"]?.string,
                  let target = containers[try PaneID(parsing: targetValue)] else {
                throw RPCFailure(code: -32602, message: "Source pane and target pane are required")
            }
            if params["cancel"] == .bool(true) {
                source.onDragEnd?()
                return .object(["preview": .bool(containers.values.contains { $0.dropView.previewFrame != nil })])
            }
            if params["menu"] == .bool(true), let direction = params["direction"]?.string {
                let menu = makeMoveMenu(for: sourceID)
                let choice = menu.items.compactMap(\.submenu).flatMap(\.items).first {
                    guard let values = $0.representedObject as? [String: String] else { return false }
                    return values["target"] == targetValue && values["direction"] == direction
                }
                guard let choice, choice.isEnabled else { return .object(["accepted": .bool(false)]) }
                NSApp.sendAction(choice.action!, to: choice.target, from: choice)
                return .object(["accepted": .bool(true)])
            }
            func coordinate(_ value: JSONValue?) -> Double? {
                switch value {
                case .number(let number): return number.isFinite ? number : nil
                case .integer(let number): return Double(number)
                default: return nil
                }
            }
            guard let x = coordinate(params["x"]), let y = coordinate(params["y"]) else {
                throw RPCFailure(code: -32602, message: "Normalized x and y are required")
            }
            let drop = target.dropView
            let direction = drop.updatePreview(source: source, at: NSPoint(x: x * drop.bounds.width, y: y * drop.bounds.height))
            var accepted = false
            if params["drop"] == .bool(true) {
                if let direction { accepted = drop.onMove?(source, direction) ?? false }
                source.onDragEnd?()
            }
            return .object(["accepted": .bool(accepted), "direction": direction.map { .string($0.rawValue) } ?? .null,
                            "preview": .bool(containers.values.contains { $0.dropView.previewFrame != nil }),
                            "previewPanes": .array(containers.compactMap { id, container in
                                container.dropView.previewFrame == nil ? nil : .string(id.description)
                            }),
                            "canDrag": .bool(source.canDrag?() == true)])
        case "debug.paneTypeMenu" where integration:
            let menu: NSMenu
            if params["pane"] != nil, let container = containers[try targetPaneID(params)] { menu = container.makeTypeMenu() }
            else if let mainMenu = paneTypeMenu { menu = mainMenu }
            else { throw RPCFailure(code: -32000, message: "Pane menu missing") }
            menuNeedsUpdate(menu)
            testConfirmationHandler = { alert in
                alert.suppressionButton?.state = params["suppress"] == .bool(true) ? .on : .off
                if let path = params["screenshot"]?.string { try? Self.captureWindow(alert.window.windowNumber, path: path) }
                alert.buttons[params["answer"]?.string == "switch" ? 1 : 0].performClick(nil)
            }
            defer { testConfirmationHandler = nil }
            if let type = params["select"]?.string {
                guard let index = menu.items.firstIndex(where: { ($0.representedObject as? String) == type }), menu.items[index].isEnabled else { throw RPCFailure(code: -32602, message: "Pane type is unavailable") }
                menu.performActionForItem(at: index)
            }
            return .array(menu.items.compactMap { item in
                guard let type = item.representedObject as? String else { return nil }
                return .object(["type": .string(type), "enabled": .bool(item.isEnabled), "checked": .bool(item.state == .on)])
            })
        case "debug.browserAddress" where integration:
            guard let browser = leaves[try targetPaneID(params)] as? BrowserPane else { throw RPCFailure(code: -32602, message: "Target is not a browser") }
            browser.focusAddress()
            return browser.focusInfo
        case "debug.reopen" where integration:
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
            return .object([:])
        case "debug.activate" where integration:
            let window = windows[try targetTab(params).id]
            if window?.isMiniaturized == true { window?.deminiaturize(nil) }
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return .object([:])
        case "debug.detach" where integration:
            windows[try targetTab(params).id]?.moveTabToNewWindow(nil)
            return .object([:])
        case "debug.reorder" where integration:
            guard let window = windows[try targetTab(params).id], let group = window.tabGroup,
                  case .integer(let index) = params["index"], group.windows.indices.contains(index) else {
                throw RPCFailure(code: -32602, message: "A tab and valid index are required")
            }
            let selected = group.selectedWindow
            group.insertWindow(window, at: index)
            return .object(["selectionPreserved": .bool(group.selectedWindow === selected)])
        case "debug.divider" where integration:
            guard case .number(let fraction) = params["fraction"], fraction > 0, fraction < 1,
                  let split = windows[try targetTab(params).id]?.contentViewController as? NSSplitViewController else {
                throw RPCFailure(code: -32602, message: "A split and fraction are required")
            }
            let length = (split.splitView.isVertical ? split.splitView.bounds.width : split.splitView.bounds.height) - split.splitView.dividerThickness
            split.splitView.setPosition(length * fraction, ofDividerAt: 0)
            return .object([:])
        case "debug.settings" where integration:
            showSettings()
            guard let model = settingsModel else { throw RPCFailure(code: -32000, message: "Settings unavailable") }
            if let section = params["section"]?.string { model.selection = SettingsSection(rawValue: section) }
            if let value = params["fontSize"]?.string { model.fontSize = value }
            if let value = params["searchURL"]?.string { model.searchURL = value }
            if let value = params["theme"]?.string { model.theme = value }
            if case .bool(let value) = params["fontThicken"] { model.fontThicken = value }
            if let value = params["minimumContrast"]?.string { model.minimumContrast = value }
            if let value = params["cursorStyle"]?.string, let style = AppConfiguration.CursorStyle(rawValue: value) { model.cursorStyle = style }
            if let value = params["cursorBlink"]?.string, let blink = AppConfiguration.CursorBlink(rawValue: value) { model.cursorBlink = blink }
            if let value = params["paddingX"]?.string { model.paddingX = value }
            if let value = params["paddingY"]?.string { model.paddingY = value }
            if let value = params["lightTheme"]?.string { model.lightTheme = value }
            if let value = params["darkTheme"]?.string { model.darkTheme = value }
            if let path = params["importPalette"]?.string {
                let name = try model.importPalette(from: URL(fileURLWithPath: path))
                if params["paletteMode"]?.string == "light" { model.lightTheme = name }
                else { model.darkTheme = name }
            }
            if let action = params["resetAction"]?.string { model.resetShortcut(for: action) }
            if let action = params["recordAction"]?.string {
                guard settingsWindow?.beginRecordingShortcut(action: action, shortcut: params["recordPrevious"]?.string) == true else {
                    throw RPCFailure(code: -32000, message: "Shortcut recorder is not visible")
                }
            }
            if case .integer(let width) = params["width"], case .integer(let height) = params["height"] {
                settingsWindow?.window?.setContentSize(NSSize(width: width, height: height))
            }
            if params["apply"] == .bool(true) { model.apply() }
            if params["revert"] == .bool(true) { refreshSettings(force: true) }
            return .object(["dirty": .bool(model.isDirty), "error": model.error.map(JSONValue.string) ?? .null,
                            "fontSize": .string(model.fontSize), "searchURL": .string(model.searchURL),
                            "values": .object(model.values.mapValues(JSONValue.string)),
                            "palettes": .array(AppConfiguration.BundledTerminalTheme.allCases.map { .string($0.rawValue) }),
                            "customPalettes": .array(model.customPalettes.map { .string($0.name) }),
                            "shortcuts": .object(model.shortcuts.mapValues(JSONValue.string)),
                            "hasToolbar": .bool(settingsWindow?.window?.toolbar != nil),
                            "pluginStatuses": .array(model.plugins.map { .string($0.status) }),
                            "commands": .array(model.commands.map { .string($0.id) }),
                            "pluginsMenu": .bool(NSApp.mainMenu?.items.contains { $0.title == "Plugins" } ?? false)])
        case "debug.commandPicker" where integration:
            if case .integer(let width) = params["sourceWidth"], case .integer(let height) = params["sourceHeight"] {
                guard (80...1200).contains(width), (80...800).contains(height), let window = commandPicker?.contextWindow else { throw RPCFailure(code: -32602, message: "An owned picker source and bounded size are required") }
                window.setContentSize(NSSize(width: CGFloat(width), height: CGFloat(height)))
            }
            if params["show"] == .bool(true), commandPicker?.isVisible != true { try toggleCommandPicker(params) }
            if let query = params["query"]?.string { commandPicker?.setQueryForTesting(query) }
            if case .integer(let row) = params["clickRow"] { try commandPicker?.clickRowForTesting(row, clickCount: params["doubleClick"] == .bool(true) ? 2 : 1) }
            if params["dismiss"] == .bool(true) { commandPicker?.dismiss(restoreFocus: true) }
            return commandPicker?.info ?? .object(["visible": .bool(false)])
        case "debug.key" where integration:
            let chord = try KeyChord.parse(params["chord"]?.string ?? "cmd+d")
            let key = chord.modifiers.contains(.shift) ? (["1": "!", "=": "+"][chord.key] ?? chord.nativeKey.uppercased()) : chord.nativeKey
            let scalar = chord.nativeKey.unicodeScalars.first!.value
            let controlLetter = chord.modifiers.contains(.ctrl) && !chord.modifiers.contains(.cmd) && (97...122).contains(scalar)
            let text = controlLetter ? String(UnicodeScalar(scalar & 0x1f)!) : key
            let menuOnly = params["menu"] == .bool(true)
            let window = menuOnly ? nil : (params["picker"] == .bool(true) ? commandPicker?.window : (params["settings"] == .bool(true) ? settingsWindow?.window : windows[try targetTab(params).id]))
            guard let code = ["d": UInt16(2), "j": UInt16(38), "h": 4, "k": 40, "l": 37, "1": 18, "2": 19, "=": 24, "left": 123, "right": 124, "up": 126, "down": 125, "e": 14, "r": 15, "return": 36, "t": 17, "n": 45, "w": 13, "[": 33, "]": 30, ",": 43, "q": 12, "s": 1, "escape": 53, "delete": 51][chord.key],
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: chord.nativeModifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window?.windowNumber ?? 0, context: nil, characters: text,
                                               charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else {
                throw RPCFailure(code: -32602, message: "A supported test chord and window are required")
            }
            if params["dispatch"] == .bool(true) {
                dispatchingTestKey = true
                defer { dispatchingTestKey = false }
                NSApp.sendEvent(event)
            }
            else {
                let handled = params["workspaceOnly"] == .bool(true)
                    ? (window as? WorkspaceWindow)?.keybindingHandler?(event)
                    : (menuOnly ? NSApp.mainMenu?.performKeyEquivalent(with: event) : window?.performKeyEquivalent(with: event))
                if handled != true { throw RPCFailure(code: -32000, message: "Key was not handled") }
            }
            return .object([:])
        case "debug.screenshot" where integration:
            if params["pickerContext"] == .bool(true) {
                guard let path = params["path"]?.string, let picker = commandPicker, picker.isVisible,
                      let backdrop = picker.contextWindow, backdrop.isVisible, !backdrop.isMiniaturized,
                      let panel = picker.window, backdrop.frame.contains(panel.frame),
                      let screen = backdrop.screen, screen.visibleFrame.contains(backdrop.frame) else {
                    throw RPCFailure(code: -32602, message: "Picker context capture requires an owned, fully visible backdrop window")
                }
                NSApp.activate(ignoringOtherApps: true)
                backdrop.orderFront(nil)
                panel.makeKeyAndOrderFront(nil)
                // Capture the actual on-screen composite over our owned backdrop.
                // Window-only captures of native glass can differ from the visible
                // material (notably a gray surface instead of the light backdrop).
                let frame = params["pickerCrop"] == .bool(true) ? panel.frame : backdrop.frame
                let top = NSScreen.screens.first!.frame.maxY - frame.maxY
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-R\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))", path]
                try process.run(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw RPCFailure(code: -32000, message: "Picker context capture failed") }
                return .object([:])
            }
            guard let path = params["path"]?.string, let window = params["picker"] == .bool(true) ? commandPicker?.window : (params["settings"] == .bool(true) ? settingsWindow?.window : windows[workspace.keyTabID ?? TabID(1)]) else {
                throw RPCFailure(code: -32602, message: "path and key window are required")
            }
            try Self.captureWindow(window.windowNumber, path: path)
            return .object([:])
        default: throw RPCFailure(code: -32601, message: "Unknown method: \(method)")
        }
    }

    private func callFromPlugin(_ method: String, params: [String: JSONValue], pane: PaneID, view: PluginPane) async throws -> JSONValue {
        guard leaves[pane] === view, let tab = workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane) }) else { throw RPCFailure(code: -32022, message: "Plugin instance was replaced") }
        guard apiMethods(plugin: true).contains(method) else { throw RPCFailure(code: -32601, message: "Method is not exposed to plugins: \(method)") }
        if method == "command.run" {
            guard let id = params["id"]?.string, CommandContract.forCommand(id).pluginAccessible else {
                throw RPCFailure(code: APIError.forbidden, message: "This administrative command is not exposed to plugin pages")
            }
        }
        var scoped = params
        if scoped["pane"] == nil && scoped["tab"] == nil {
            scoped["pane"] = .string(pane.description)
            scoped["tab"] = .string(tab.id.description)
        }
        if scoped["scope"] == nil { scoped["scope"] = .string(view.instance.registration.scope.rawValue) }
        try synchronizeNativeGroups()
        if ["pane.title", "settings.get", "storage.get", "storage.set", "storage.delete"].contains(method) {
            guard params["pane"] == nil || params["pane"] == .string(pane.description),
                  params["tab"] == nil || params["tab"] == .string(tab.id.description) else {
                throw RPCFailure(code: -32602, message: "This operation is bound to the calling plugin view/namespace")
            }
        }
        try validateAPIGuards(scoped, method: method)
        let payload = withoutAPIGuards(params)
        switch method {
        case "context.get": return try context(scoped)
        case "api.describe": return try describeAPI(plugin: true)
        case "workspace.snapshot": return try workspaceSnapshot(scoped)
        case "context.inspect": return try inspectContext(scoped, caller: pane, view: view)
        case "pane.inspect": return try call(method, params: scoped)
        case "events.head":
            guard payload.isEmpty else { throw RPCFailure(code: -32602, message: "events.head takes no parameters") }
            return events.head
        case "events.poll":
            // Logical pane/tab instances follow their owning tab's active-terminal
            // context. Global instances observe every tab; callers may narrow filters.
            return try await events.poll(payload, boundTab: view.instance.tab, recipientInstanceId: view.instance.id)
        case "events.emit":
            return try events.emit(payload, source: .plugin(type: view.instance.registration.id, instanceId: view.instance.id),
                sourceTab: tab.id, sourcePane: pane, knownInstances: Set(pluginInstances.all.map(\.id)))
        case "terminal.send", "terminal.key", "terminal.capture", "terminal.run", "terminal.wait":
            return try await callAsync(method, params: scoped)
        case "command.run": return try await callAsync(method, params: scoped)
        case "command.list": return try .encoding(availableCommands.filter { $0.contract.pluginAccessible })
        case "workspace.get", "layout.get", "panes.list", "tabs.list": return try call(method, params: scoped)
        case "settings.get": return .object(settings.current.plugins[view.instance.registration.id] ?? [:])
        case "pane.title":
            guard let title = params["title"], title == .null || title.string != nil else { throw RPCFailure(code: -32602, message: "title must be a string or null") }
            try view.setPaneTitle(title.string)
            return .null
        case "storage.get":
            if let value = params["key"], value.string == nil { throw RPCFailure(code: -32602, message: "Storage key must be a string") }
            return view.instance.storageGet(params["key"]?.string)
        case "storage.set", "storage.delete":
            guard let key = params["key"]?.string, method == "storage.delete" || params["value"] != nil else { throw RPCFailure(code: -32602, message: "Storage key and value are required") }
            try view.instance.storageSet(key, value: method == "storage.delete" ? nil : params["value"])
            return .null
        default: throw RPCFailure(code: -32601, message: "Method is not exposed to plugins: \(method)")
        }
    }

    private func publishTerminalContext(_ pane: PaneID, reason: String) {
        guard terminals[pane] != nil, let tab = workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane) }) else { return }
        events.publishHost("host.context.changed", payload: .object([
            "reason": .string(reason),
            "sessionId": shellSessions[pane].map { .string($0.instanceID) } ?? .null,
            "sequence": .integer(shellSessions[pane]?.report?.sequence ?? 0)
        ]), tab: tab.id, pane: pane)
    }

    private func context(_ params: [String: JSONValue]) throws -> JSONValue {
        if let value = params["scope"], value.string == nil { throw RPCFailure(code: -32602, message: "scope must be a string") }
        let scope = params["scope"]?.string ?? "tab"
        guard ["pane", "tab", "global"].contains(scope) else { throw RPCFailure(code: -32602, message: "scope must be pane, tab, or global") }
        let tab: Tab
        if scope != "global", params["pane"] != nil {
            let pane = try targetPaneID(params)
            tab = workspace.tabs.first { $0.layout.paneIDs.contains(pane) }!
        } else { tab = try targetTab(scope == "global" ? [:] : params) }
        let reference = scope == "pane" ? try targetPaneID(params) : tab.focusedPane
        let terminalID = scope == "pane" && terminals[reference] != nil ? reference : tab.activeTerminal
        var terminal: JSONValue = .null
        if let id = terminalID, let view = terminals[id] {
            let report = shellSessions[id]?.report
            let metadata = view.context
            let directory = report?.workingDirectory ?? metadata.workingDirectory
            let exitCode = report?.exitCode ?? metadata.lastCommand?.exitCode
            terminal = .object(["paneId": .string(id.description), "sessionId": shellSessions[id].map { .string($0.instanceID) } ?? .null,
                                "pid": report.map { .integer($0.pid) } ?? .null, "title": metadata.title.map(JSONValue.string) ?? .null,
                                "workingDirectory": directory.map(JSONValue.string) ?? .null,
                                "state": .string(report?.state.rawValue ?? "unknown"), "isAtPrompt": report.map { .bool($0.state == .prompt) } ?? .null,
                                "command": report?.command.map(JSONValue.string) ?? .null, "exitCode": exitCode.map(JSONValue.integer) ?? .null,
                                "sequence": .integer(report?.sequence ?? 0)])
        }
        return .object(["instanceId": .string(instanceID), "scope": .string(scope), "tabId": .string(tab.id.description),
                        "focusedPaneId": .string(tab.focusedPane.description), "activeTerminalPaneId": tab.activeTerminal.map { .string($0.description) } ?? .null,
                        "terminal": terminal])
    }

    func targetTab(_ params: [String: JSONValue]) throws -> Tab {
        func text(_ key: String) throws -> String? {
            guard let value = params[key] else { return nil }
            guard let text = value.string else { throw RPCFailure(code: -32602, message: "\(key) must be a string") }
            return text
        }
        return try workspace.resolvedTab(pane: text("pane").map { try PaneID(parsing: $0) }, tab: text("tab").map { try TabID(parsing: $0) })
    }

    func targetPaneID(_ params: [String: JSONValue]) throws -> PaneID {
        let id: PaneID
        if let value = params["pane"] {
            guard let string = value.string else { throw RPCFailure(code: -32602, message: "pane must be a string") }
            id = try PaneID(parsing: string)
        } else { id = try targetTab(params).focusedPane }
        guard workspace.panes.contains(where: { $0.id == id }) else { throw WorkspaceError.paneNotFound(id) }
        return id
    }

    private func terminalPane(_ params: [String: JSONValue]) throws -> PaneID {
        // An explicitly addressed terminal wins over focus/history. A plugin or
        // browser pane instead anchors the lookup of its contextual terminal.
        if params["pane"] != nil {
            let pane = try targetPaneID(params)
            if terminals[pane] != nil { return pane }
        }
        guard let id = try context(params).object?["terminal"]?.object?["paneId"]?.string else {
            throw RPCFailure(code: -32004, message: "There is no active terminal in this context")
        }
        return try PaneID(parsing: id)
    }

    private func targetTerminal(_ params: [String: JSONValue]) throws -> TerminalView {
        let id = try targetPaneID(params)
        guard let terminal = terminals[id] else { throw RPCFailure(code: -32602, message: "Pane \(id) is not a terminal") }
        if let session = params["sessionId"] {
            guard let sessionID = session.string else { throw RPCFailure(code: -32602, message: "sessionId must be a string") }
            guard shellSessions[id]?.instanceID == sessionID else { throw RPCFailure(code: -32022, message: "Terminal session was replaced; read context again") }
        }
        return terminal
    }

    /// Prepare new surfaces before committing the value model; failures leave the old tree intact.
    private func reconcile(_ next: Workspace) throws {
        leaves.values.compactMap { $0 as? BrowserPane }.forEach { $0.rememberFocus() }
        for pane in next.panes {
            if case .registered(let type) = pane.type, !pluginCatalog.registrations.contains(where: { $0.id == type && $0.hasPanel }) { throw RPCFailure(code: -32602, message: "Pane type is not registered: \(type)") }
        }
        let replacements = Set(next.panes.filter { pane in workspace.panes.contains(where: { $0.id == pane.id && $0.type != pane.type }) }.map(\.id))
        var created: [PaneID: TerminalView] = [:]
        var sessions: [PaneID: ShellSession] = [:]
        var createdPlugins: [PaneID: PluginPane] = [:]
        do {
            for pane in next.panes where (leaves[pane.id] == nil || replacements.contains(pane.id)) && pane.type == .terminal {
                let tab = next.tabs.first { $0.layout.paneIDs.contains(pane.id) }!
                // Ghostty's shell path hook must restore our CLI directory, not
                // Contents/MacOS (whose same-named binary launches the GUI).
                let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path
                let token = UUID().uuidString
                let session = ShellSession(token: token)
                var environment = [
                    "SLATE_TERM_CONTEXT_TOKEN": token,
                    "SLATE_TERM_RUN_KEY": session.runKey,
                    "SLATE_TERM_CLI": helpers + "/slate-term",
                    "SLATE_TERM_SHELL_PID": "",
                    "SLATE_TERM_SOCKET": server!.path,
                    "SLATE_TERM_PANE_ID": pane.id.description,
                    "SLATE_TERM_TAB_ID": tab.id.description,
                    "SLATE_TERM_INSTANCE_ID": instanceID,
                    "SLATE_TERM_SESSION_ID": session.instanceID,
                    "GHOSTTY_BIN_DIR": helpers,
                    "PATH": helpers + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"),
                ]
                environment.merge(settings.shellEnvironment()) { _, value in value }
                if integration {
                    environment["HISTFILE"] = "/dev/null"
                    if ProcessInfo.processInfo.environment["SLATE_TERM_TEST_REAL_SHELL"] != "1" {
                        environment["ENV"] = "/dev/null"
                        environment["BASH_ENV"] = "/dev/null"
                    }
                }
                created[pane.id] = try TerminalView(runtime: runtime, environment: environment)
                sessions[pane.id] = session
            }
            for pane in next.panes where leaves[pane.id] == nil || replacements.contains(pane.id) {
                guard case .registered(let type) = pane.type, let registration = pluginCatalog.registrations.first(where: { $0.id == type && $0.hasPanel }) else { continue }
                let tab = next.tabs.first { $0.layout.paneIDs.contains(pane.id) }!
                let instance = try pluginInstances.acquire(registration, pane: pane.id, tab: tab.id)
                let controller = PluginPane(instance: instance, paneID: pane.id)
                controller.onFocus = { [weak self] in self?.focused(pane.id) }
                controller.onRelease = { [weak self, weak instance] in
                    if let instance { self?.pluginInstances.release(instance, pane: pane.id) }
                }
                controller.onCall = { [weak self, weak controller] method, params in
                    guard let self, let controller else { throw SocketError.disconnected }
                    return try await self.callFromPlugin(method, params: params, pane: pane.id, view: controller)
                }
                createdPlugins[pane.id] = controller
            }
        } catch {
            created.values.forEach { $0.close() }
            createdPlugins.values.forEach { $0.close() }
            pluginInstances.prune(workspace: workspace)
            throw error
        }
        reconciling = true
        defer { reconciling = false; persistWorkspace() }
        let changedTabs = next.tabs.filter { rendered[$0.id] != $0.layout || renderedZoom[$0.id] != $0.zoomedPane || !replacements.isDisjoint(with: $0.layout.paneIDs) }.map(\.id)
        for id in replacements {
            terminalControl.remove(pane: id)
            let container = containers.removeValue(forKey: id)
            container?.view.removeFromSuperview(); container?.removeFromParent()
            leaves[id]?.view.removeFromSuperview()
            leaves[id]?.removeFromParent()
            (leaves[id] as? BrowserPane)?.close()
            (leaves[id] as? PluginPane)?.close()
            terminals.removeValue(forKey: id)?.close()
            leaves.removeValue(forKey: id)
        }
        for id in changedTabs { rendered.removeValue(forKey: id) }
        workspace = next
        for (id, terminal) in created {
            terminal.onFocus = { [weak self] in self?.focused(id) }
            terminal.onCloseRequest = { [weak self, weak terminal] processAlive in
                guard let self, let terminal, self.terminals[id] === terminal else { return }
                self.runUserCommand("pane.close", params: ["pane": .string(id.description), "force": .bool(!processAlive)])
            }
            terminals[id] = terminal
            shellNames[id] = integration && ProcessInfo.processInfo.environment["SLATE_TERM_TEST_REAL_SHELL"] != "1" ? "sh" : URL(fileURLWithPath: settings.current.terminal.shell).lastPathComponent
            terminal.onContextChange = { [weak self] _ in
                self?.updatePaneTitle(id)
                self?.publishTerminalContext(id, reason: "engine")
            }
            shellSessions[id] = sessions[id]
            let controller = NSViewController()
            controller.view = terminal
            leaves[id] = controller
        }
        for (id, controller) in createdPlugins {
            controller.onTitleChange = { [weak self] in self?.updatePaneTitle(id) }
            leaves[id] = controller
        }
        for pane in next.panes where leaves[pane.id] == nil && pane.type == .browser {
            let browser = BrowserPane()
            browser.browserConfiguration = settings.current.browser
            browser.onFocus = { [weak self] in self?.focused(pane.id) }
            browser.onTitleChange = { [weak self] in self?.updatePaneTitle(pane.id) }
            leaves[pane.id] = browser
        }
        let retainedPanes = Set(next.panes.map(\.id))
        for id in Array(leaves.keys) where !retainedPanes.contains(id) {
            terminalControl.remove(pane: id)
            let container = containers.removeValue(forKey: id)
            container?.view.removeFromSuperview(); container?.removeFromParent()
            leaves[id]?.view.removeFromSuperview()
            leaves[id]?.removeFromParent()
            terminals.removeValue(forKey: id)?.close()
            (leaves[id] as? BrowserPane)?.close()
            (leaves[id] as? PluginPane)?.close()
            leaves.removeValue(forKey: id)
        }
        shellSessions = shellSessions.filter { terminals[$0.key] != nil }
        shellNames = shellNames.filter { terminals[$0.key] != nil }
        processNames = processNames.filter { terminals[$0.key] != nil }
        for pane in next.panes {
            if containers[pane.id] == nil {
                let typeID: String
                switch pane.type {
                case .terminal: typeID = "terminal"
                case .browser: typeID = "browser"
                case .registered(let id): typeID = id
                }
                let type = availablePaneTypes.first { $0.id == typeID }!.name
                let container = PaneContainer(content: leaves[pane.id]!, type: type, typeID: typeID)
                container.onClose = { [weak self] in self?.runUserCommand("pane.close", params: ["pane": .string(pane.id.description)]) }
                container.onRename = { [weak self] title in
                    guard let self else { return }
                    do { try self.setManualPaneTitle(title, for: pane.id) }
                    catch { self.present(error) }
                }
                container.dragHandle.canDrag = { [weak self] in
                    guard let tab = self?.workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane.id) }) else { return false }
                    return tab.zoomedPane == nil && tab.layout.paneIDs.count > 1
                }
                container.dragHandle.onDragEnd = { [weak self] in self?.clearPaneMovePreviews() }
                container.moveMenu = { [weak self] in self?.makeMoveMenu(for: pane.id) ?? NSMenu() }
                container.dropView.canMove = { [weak self] source, direction in
                    self?.proposedMove(source: source, target: pane.id, direction: direction) != nil
                }
                container.dropView.onClearPreviews = { [weak self] in self?.clearPaneMovePreviews() }
                container.dropView.onPreview = { [weak self] source, direction in
                    self?.previewPaneMove(source: source, target: pane.id, direction: direction)
                }
                container.dropView.onMove = { [weak self] source, direction in
                    self?.movePane(source: source, target: pane.id, direction: direction) ?? false
                }
                container.typeChoices = { [weak self] in self?.availablePaneTypes ?? [] }
                container.onChangeType = { [weak self] type in self?.changePaneType(pane.id, to: type) }
                container.onFocus = { [weak self] in
                    guard let self, let window = self.containers[pane.id]?.view.window else { return }
                    self.focused(pane.id)
                    self.focusResponder(pane.id, in: window)
                }
                containers[pane.id] = container
            }
            updatePaneTitle(pane.id)
        }
        refreshHeaderActions()
        let retainedTabs = Set(next.tabs.map(\.id))
        for id in Array(windows.keys) where !retainedTabs.contains(id) {
            windows.removeValue(forKey: id)?.close()
            rendered.removeValue(forKey: id)
            renderedZoom.removeValue(forKey: id)
        }
        for tab in next.tabs {
            let window: WorkspaceWindow
            if let existing = windows[tab.id] { window = existing }
            else {
                window = WorkspaceWindow(contentRect: NSRect(x: 160, y: 160, width: 1000, height: 650),
                                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
                window.title = "Slate Terminal — \(tab.id)"
                window.isReleasedWhenClosed = false
                window.tabbingMode = .preferred
                window.tabbingIdentifier = "slate-term"
                window.delegate = self
                window.keybindingHandler = { [weak self] event in
                    guard let self else { return false }
                    if self.workspaceShortcuts?.performKeyEquivalent(with: event) == true { return true }
                    let bindings = self.activeKeyBindings.sorted { $0.key.description < $1.key.description }
                    guard let binding = bindings.first(where: { $0.key.matches(event) }) else { return false }
                    if binding.value.hasPrefix("browser."), self.focusedBrowser == nil { return false }
                    self.runUserCommand(binding.value, params: [:])
                    return true
                }
                windows[tab.id] = window
            }
            if rendered[tab.id] != tab.layout {
                let frame = window.frame
                for id in tab.layout.paneIDs {
                    containers[id]?.view.removeFromSuperview()
                    containers[id]?.removeFromParent()
                }
                window.contentViewController = nil
                window.contentViewController = controller(for: tab.zoomedPane.map(Layout.pane) ?? tab.layout, tab: tab.id, path: [])
                // AppKit adopts a replacement controller's initial fitting size.
                // A pane split changes the interior, not the user's window frame.
                window.setFrame(frame, display: true)
                window.contentView?.layoutSubtreeIfNeeded()
                rendered[tab.id] = tab.layout
                renderedZoom[tab.id] = tab.zoomedPane
            }
        }
        for group in next.groups {
            guard let first = group.tabs.first.flatMap({ windows[$0] }) else { continue }
            var previous = first
            for id in group.tabs.dropFirst() {
                guard let window = windows[id] else { continue }
                if !(first.tabGroup?.windows ?? [first]).contains(window) {
                    previous.addTabbedWindow(window, ordered: .above)
                }
                previous = window
            }
            first.orderFront(nil)
        }
        if commandPicker?.isVisible != true, let tab = next.tabs.first(where: { $0.id == next.keyTabID }), let window = windows[tab.id] {
            window.makeKeyAndOrderFront(nil)
            focusResponder(tab.focusedPane, in: window)
        }
        for id in changedTabs {
            windows[id]?.contentView?.layoutSubtreeIfNeeded()
            (windows[id]?.contentViewController as? WorkspaceSplitController)?.applyInitialFractions()
        }
        // Rebuilding a background tab can remove its first responder too.
        if commandPicker?.isVisible != true {
            for tab in next.tabs {
                if let window = windows[tab.id] { focusResponder(tab.focusedPane, in: window) }
            }
        }
        synchronizeTerminalFocus(commandPicker?.isVisible == true ? nil : workspace.tabs.first { $0.id == workspace.keyTabID }?.focusedPane)
        observeNativeTabGroups()
        createdPlugins.values.forEach { $0.activate() }
        pluginInstances.prune(workspace: workspace)
    }

    private func controller(for layout: Layout, tab: TabID, path: [Branch]) -> NSViewController {
        switch layout {
        case .pane(let id): return containers[id]!
        case .split(let axis, let fraction, let first, let second):
            let split = WorkspaceSplitController(fraction: fraction)
            split.splitView.isVertical = axis == .horizontal
            for child in [controller(for: first, tab: tab, path: path + [.first]), controller(for: second, tab: tab, path: path + [.second])] {
                let item = NSSplitViewItem(viewController: child)
                item.minimumThickness = 80
                // Pane geometry belongs to the split model, not the intrinsic
                // hugging size of a web pane's address bar or status text.
                item.holdingPriority = NSLayoutConstraint.Priority(rawValue: 251)
                split.addSplitViewItem(item)
            }
            split.onResize = { [weak self] fraction in
                guard let self, !self.reconciling else { return }
                do {
                    try self.workspace.resize(tab: tab, path: path, fraction: fraction)
                    self.rendered[tab] = self.workspace.tabs.first { $0.id == tab }?.layout
                    self.persistWorkspace()
                } catch { NSLog("Divider update rejected: %@", String(describing: error)) }
            }
            return split
        }
    }

    private func proposedMove(source: PaneDragHandle, target: PaneID, direction: Direction) -> Workspace? {
        guard let pane = containers.first(where: { $0.value.dragHandle === source })?.key,
              pane != target, let tab = workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane) }),
              tab.zoomedPane == nil, tab.layout.paneIDs.contains(target) else { return nil }
        var next = workspace
        do {
            try next.move(pane, beside: target, direction: direction)
            guard let layout = next.tabs.first(where: { $0.id == tab.id })?.layout,
                  let frames = paneMoveFrames(layout: layout, tab: tab.id),
                  [pane, target].allSatisfy({ id in
                      guard let frame = frames[id] else { return false }
                      return frame.width >= 80 && frame.height >= 80
                  }) else { return nil }
            return next
        } catch { return nil }
    }

    private func paneMoveFrames(layout: Layout, tab: TabID) -> [PaneID: NSRect]? {
        guard let window = windows[tab], let content = window.contentView,
              let split = window.contentViewController as? NSSplitViewController else { return nil }
        return PaneMoveGeometry.frames(for: layout, in: content.convert(content.bounds, to: nil), divider: split.splitView.dividerThickness)
    }

    private func clearPaneMovePreviews() { containers.values.forEach { $0.dropView.clearPreview() } }

    private func previewPaneMove(source: PaneDragHandle, target: PaneID, direction: Direction) {
        clearPaneMovePreviews()
        guard proposedMove(source: source, target: target, direction: direction) != nil else { return }
        containers[target]?.dropView.showPreview(direction: direction)
    }

    @discardableResult
    private func movePane(source: PaneDragHandle, target: PaneID, direction: Direction) -> Bool {
        guard let next = proposedMove(source: source, target: target, direction: direction) else { return false }
        do { try reconcile(next); return true }
        catch { present(error); return false }
    }

    private func makeMoveMenu(for pane: PaneID) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let tab = workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane) }),
              tab.zoomedPane == nil, tab.layout.paneIDs.count > 1 else {
            let item = menu.addItem(withTitle: "Move requires another visible pane in this tab", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return menu
        }
        for target in tab.layout.paneIDs where target != pane {
            let title = containers[target]?.info.object?["title"]?.string ?? target.description
            let item = menu.addItem(withTitle: "\(title) (\(target))", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            item.submenu = submenu
            for (direction, label) in [(Direction.left, "Move to Left"), (.right, "Move to Right"), (.up, "Move Above"), (.down, "Move Below")] {
                let choice = submenu.addItem(withTitle: label, action: #selector(movePaneFromMenu(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = ["pane": pane.description, "target": target.description, "direction": direction.rawValue]
                choice.isEnabled = containers[pane].flatMap { proposedMove(source: $0.dragHandle, target: target, direction: direction) } != nil
            }
        }
        return menu
    }

    @objc private func movePaneFromMenu(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String: String],
              let pane = try? PaneID(parsing: values["pane"] ?? ""),
              let target = try? PaneID(parsing: values["target"] ?? ""),
              let direction = Direction(rawValue: values["direction"] ?? ""),
              let source = containers[pane]?.dragHandle else { return }
        movePane(source: source, target: target, direction: direction)
    }

    private func refreshTerminalTitles() {
        processNames = processTitles.names(for: Set(terminals.keys))
        for pane in terminals.keys { updatePaneTitle(pane) }
    }

    private func updatePaneTitle(_ pane: PaneID) {
        let title: String
        if let manualTitle = workspace.panes.first(where: { $0.id == pane })?.manualTitle {
            title = manualTitle
        } else if let terminal = terminals[pane] {
            let report = shellSessions[pane]?.report
            let shell = shellNames[pane] ?? "Shell"
            let process = report?.state == .prompt ? shell : processNames[pane] ?? shell
            if report?.state == .running, let command = terminalControl.displayCommand(pane: pane) ?? report?.command, !command.isEmpty {
                // The telemetry helper briefly runs inside preexec; show the
                // reported command rather than flashing its implementation name.
                title = command == process || process == "slate-term" ? command : process + " — " + command
            } else if let custom = terminal.context.title, !custom.isEmpty, custom != process {
                title = process + " — " + custom
            } else { title = process }
        } else if let browser = leaves[pane] as? BrowserPane { title = browser.paneTitle }
        else if let plugin = leaves[pane] as? PluginPane { title = plugin.paneTitle }
        else { return }
        containers[pane]?.setTitle(title)
    }

    private func setManualPaneTitle(_ title: String, for pane: PaneID) throws {
        try workspace.setManualTitle(title, for: pane)
        updatePaneTitle(pane)
        persistWorkspace()
    }

    private func focused(_ pane: PaneID) {
        guard !reconciling else { return }
        do {
            try workspace.focus(pane)
            synchronizeTerminalFocus(pane)
            persistWorkspace()
        } catch { NSLog("Focus update rejected: %@", String(describing: error)) }
    }

    private func focusResponder(_ pane: PaneID, in window: NSWindow) {
        if let browser = leaves[pane] as? BrowserPane { browser.focus() }
        else if let plugin = leaves[pane] as? PluginPane { plugin.focus() }
        else { window.makeFirstResponder(leaves[pane]?.view) }
    }

    private func synchronizeTerminalFocus(_ pane: PaneID?) {
        for (id, terminal) in terminals { terminal.setFocused(id == pane) }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !reconciling, let window = notification.object as? NSWindow else { return }
        for browser in leaves.values.compactMap({ $0 as? BrowserPane }) where browser.view.window === window { browser.rememberFocus() }
        for terminal in terminals.values where terminal.window === window { terminal.setFocused(false) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !reconciling, let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        do {
            try workspace.focusTab(id)
            try synchronizeNativeGroups()
            if commandPicker?.isRestoringFocus == true, let original = pickerReturnPane,
               workspace.tabs.first(where: { $0.id == id })?.layout.paneIDs.contains(original) == true { try workspace.focus(original) }
            let pane = workspace.tabs.first { $0.id == id }?.focusedPane
            if commandPicker?.isRestoringFocus != true, let pane { focusResponder(pane, in: window) }
            synchronizeTerminalFocus(pane)
            persistWorkspace()
        } catch { NSLog("Native tab update rejected: %@", String(describing: error)) }
    }

    func synchronizeNativeGroups() throws {
        guard !reconciling else { return }
        let previous = workspace
        try workspace.adoptTabGroups(nativeTabGroups())
        if workspace != previous { persistWorkspace() }
        observeNativeTabGroups()
    }

    private func observeNativeTabGroups() {
        var groups: [ObjectIdentifier: NSWindowTabGroup] = [:]
        for window in windows.values {
            if let group = window.tabGroup { groups[ObjectIdentifier(group)] = group }
        }
        tabGroupObservations = tabGroupObservations.filter { groups[$0.key] != nil }
        for (id, group) in groups where tabGroupObservations[id] == nil {
            // AppKit documents windows as KVO compliant. Reordering the selected
            // tab does not necessarily cause a windowDidBecomeKey notification.
            let observation = group.observe(\.windows) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleNativeTabSync() }
            }
            // Keep identity alive until its observation is removed.
            tabGroupObservations[id] = (group, observation)
        }
    }

    private func scheduleNativeTabSync() {
        guard !reconciling, !tabGroupSyncScheduled else { return }
        tabGroupSyncScheduled = true
        // A move can transiently remove a window before inserting it. Import the
        // completed AppKit operation, not intermediate groups that consume IDs.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tabGroupSyncScheduled = false
            do { try self.synchronizeNativeGroups() }
            catch { NSLog("Native tab synchronization rejected: %@", String(describing: error)) }
        }
    }

    private func nativeTabGroups() -> [[TabID]] {
        var seen = Set<TabID>()
        var result: [[TabID]] = []
        for tab in workspace.tabs where !seen.contains(tab.id) {
            guard let window = windows[tab.id] else { continue }
            let members = (window.tabGroup?.windows ?? [window]).compactMap { native in
                windows.first { $0.value === native }?.key
            }
            seen.formUnion(members)
            result.append(members)
        }
        return result
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !reconciling, let id = windows.first(where: { $0.value === sender })?.key else { return true }
        runUserCommand("tab.close", params: ["tab": .string(id.description)])
        return false
    }

    private func buildMenus() {
        let menu = NSMenu()
        let appMenu = NSMenu(title: "Slate Terminal")
        let about = appMenu.addItem(withTitle: "About Slate Terminal", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp
        appMenu.addItem(.separator())
        addCommands(["settings.open"], to: appMenu)
        for item in appMenu.items where item.representedObject as? String == "settings.open" { item.title = "Settings…" }
        appMenu.addItem(.separator())
        let status = NSMenuItem(title: "Configuration & Workspace Status…", action: #selector(showSettingsStatus), keyEquivalent: "")
        status.target = self
        setBuiltInShortcut(status, key: ",", modifiers: [.command, .shift])
        appMenu.addItem(status)
        let resetWarnings = appMenu.addItem(withTitle: "Reset Close Warnings", action: #selector(resetCloseWarnings), keyEquivalent: "")
        resetWarnings.target = self
        setBuiltInShortcut(resetWarnings, key: ",", modifiers: [.command, .option])
        let resetTypeWarnings = appMenu.addItem(withTitle: "Reset Pane Type Warnings", action: #selector(resetPaneTypeWarnings), keyEquivalent: "")
        resetTypeWarnings.target = self
        statusMenuItem = status
        updateStatusMenu()
        appMenu.addItem(.separator())
        let ownsQuitKey = activeKeyBindings.keys.contains { $0.nativeKey == "q" && $0.nativeModifiers == [.command] }
        appMenu.addItem(withTitle: "Quit Slate Terminal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ownsQuitKey ? "" : "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let workspaceMenu = NSMenu(title: "Workspace")
        func addCommands(_ ids: [String], to menu: NSMenu) {
            for id in ids {
                guard let command = availableCommands.first(where: { $0.id == id }) else { continue }
                let bindings = activeKeyBindings.keys.sorted { $0.description < $1.description }.filter { activeKeyBindings[$0] == id }
                let alternatives: [KeyChord?] = bindings.isEmpty ? [nil] : bindings.map { Optional($0) }
                for (index, binding) in alternatives.enumerated() {
                    let item = NSMenuItem(title: command.title, action: #selector(runMenuCommand(_:)), keyEquivalent: binding?.nativeKey ?? "")
                    item.keyEquivalentModifierMask = binding?.nativeModifiers ?? []
                    item.representedObject = id
                    item.target = self
                    // Keep alternative configured shortcuts working through AppKit.
                    item.isHidden = index > 0
                    item.allowsKeyEquivalentWhenHidden = true
                    menu.addItem(item)
                }
            }
        }
        addCommands(["command.picker"], to: workspaceMenu)
        workspaceMenu.addItem(.separator())
        addCommands(["window.new"], to: workspaceMenu)
        workspaceMenu.addItem(.separator())
        for (title, commands) in [
            ("Tabs", ["tab.new", "tab.close", "tab.previous", "tab.next"]),
            ("Browser", ["browser.back", "browser.forward", "browser.focusAddress", "browser.reload"]),
            ("Split Pane", ["split.left", "split.right", "split.up", "split.down"]),
            ("Focus Pane", ["focus.left", "focus.right", "focus.up", "focus.down"]),
            ("Layout", ["pane.zoom", "layout.equalize"]),
            ("Appearance", ["appearance.auto", "appearance.light", "appearance.dark"]),
            ("Application Font Size", ["terminal.font.increase", "terminal.font.decrease", "terminal.font.reset"]),
        ] {
            let group = workspaceMenu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            addCommands(commands, to: submenu)
            if title == "Tabs" {
                submenu.addItem(.separator())
                let select = submenu.addItem(withTitle: "Select Tab", action: nil, keyEquivalent: "")
                let numberedTabs = NSMenu(title: "Select Tab")
                addCommands((1...9).map { "tab.select\($0)" }, to: numberedTabs)
                select.submenu = numberedTabs
            }
            group.submenu = submenu
        }
        workspaceMenu.addItem(.separator())
        addCommands(["pane.copyID", "pane.close"], to: workspaceMenu)
        workspaceMenu.addItem(.separator())
        addCommands(["config.reload"], to: workspaceMenu)
        let contributed = pluginCatalog.registrations.flatMap(\.workspaceCommands)
        if !contributed.isEmpty {
            workspaceMenu.addItem(.separator())
            let item = workspaceMenu.addItem(withTitle: "Plugin Commands", action: nil, keyEquivalent: "")
            let commands = NSMenu(title: "Plugin Commands")
            addCommands(contributed.map(\.id), to: commands)
            item.submenu = commands
        }
        let item = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        item.submenu = workspaceMenu
        menu.addItem(item)
        let types = NSMenu(title: "Pane")
        types.autoenablesItems = false
        types.delegate = self
        for (index, entry) in availablePaneTypes.enumerated() {
            let (name, type) = entry
            let item = NSMenuItem(title: name, action: #selector(changePaneType(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = type
            if index < 9 { setBuiltInShortcut(item, key: String(index + 1), modifiers: [.command, .control]) }
            types.addItem(item)
        }
        let paneItem = NSMenuItem(title: "Pane", action: nil, keyEquivalent: "")
        paneItem.submenu = types
        menu.addItem(paneItem)
        paneTypeMenu = types
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Copy", Selector(("copy:")), "c"), ("Paste", Selector(("paste:")), "v"), ("Select All", Selector(("selectAll:")), "a")] {
            editMenu.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.insertItem(editItem, at: 1)
        let windowMenu = NSMenu(title: "Window")
        addCommands(["tab.previous", "tab.next"], to: windowMenu)
        let detachTab = windowMenu.addItem(withTitle: "Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        setBuiltInShortcut(detachTab, key: "n", modifiers: [.command, .control])
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        workspaceShortcuts = workspaceMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
        refreshCommandPicker()
        refreshHeaderActions()
    }

    private func setBuiltInShortcut(_ item: NSMenuItem, key: String, modifiers: NSEvent.ModifierFlags = [.command]) {
        // A user's configured workspace binding takes precedence over fixed UI shortcuts.
        guard !activeKeyBindings.keys.contains(where: { $0.nativeKey == key && $0.nativeModifiers == modifiers }) else { return }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = modifiers
    }

    @objc private func resetPaneTypeWarnings() {
        do { _ = try runSettingsCommand("warnings.type.reset", params: [:]) }
        catch { present(error) }
    }

    @objc private func resetCloseWarnings() {
        do { _ = try runSettingsCommand("warnings.close.reset", params: [:]) }
        catch { present(error) }
    }

    private func toggleCommandPicker(_ params: [String: JSONValue]) throws {
        if commandPicker?.isVisible == true { commandPicker?.dismiss(restoreFocus: true); return }
        try synchronizeNativeGroups()
        pickerReturnPane = NSApp.keyWindow is WorkspaceWindow ? workspace.tabs.first(where: { $0.id == workspace.keyTabID })?.focusedPane : nil
        pickerTarget = [:]
        if params["pane"] != nil || params["tab"] != nil || workspace.keyTabID != nil {
            let pane = try targetPaneID(params)
            let tab = workspace.tabs.first { $0.layout.paneIDs.contains(pane) }!.id
            if params["tab"] != nil, try targetTab(params).id != tab { throw RPCFailure(code: -32602, message: "Pane does not belong to the requested tab") }
            pickerTarget = ["pane": .string(pane.description), "tab": .string(tab.description)]
        }
        if commandPicker == nil {
            let picker = CommandPicker()
            picker.onExecute = { [weak self] id in
                guard let self, self.pickerEntries.contains(where: { $0.item.id == id && $0.unavailable == nil }) else { NSSound.beep(); return }
                let independent = CommandContract.forCommand(id).workspaceIndependent
                // An empty captured context is intentional, not permission to
                // retarget a window created by another client while searching.
                let resolvedID = id == "tab.new" && self.pickerTarget.isEmpty ? "window.new" : id
                self.runUserCommand(resolvedID, params: independent ? [:] : self.pickerTarget,
                                    capturedWithoutWorkspace: self.pickerTarget.isEmpty)
            }
            commandPicker = picker
        }
        commandPicker?.show(commands: pickerEntries, relativeTo: NSApp.keyWindow ?? workspace.keyTabID.flatMap { windows[$0] })
    }

    private func refreshHeaderActions() {
        for registration in pluginCatalog.registrations where headerActionRevisions[registration.id] == nil {
            headerActionRevisions[registration.id] = UUID()
        }
        let running = Set(pluginCommands.all.filter { $0.object?["state"] == .string("running") }.compactMap { $0.object?["commandId"]?.string })
        for pane in workspace.panes {
            let type: String
            switch pane.type {
            case .terminal: type = "terminal"
            case .browser: type = "browser"
            case .registered(let id): type = id
            }
            let actions = pluginCatalog.registrations.flatMap { registration in
                registration.headerButtons.filter { $0.matches(paneType: type) }.map { button in
                    let command = "plugin.\(registration.id).\(button.command)"
                    return PaneHeaderAction(id: button.namespacedID(plugin: registration.id), title: "\(registration.title): \(button.title)",
                        symbol: button.symbol, enabled: !running.contains(command), revision: headerActionRevisions[registration.id]!, perform: { [weak self] in
                            guard let self, let tab = self.workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane.id) }),
                                  self.workspace.panes.contains(where: { $0.id == pane.id && $0.type == pane.type }),
                                  self.pluginCatalog.registrations.contains(where: { $0.id == registration.id && $0.headerButtons.contains(button) }) else { return }
                            self.runUserCommand(command, params: ["pane": .string(pane.id.description), "tab": .string(tab.id.description)])
                        })
                }
            }
            containers[pane.id]?.setHeaderActions(actions)
        }
    }

    private func refreshCommandPicker() {
        guard commandPicker?.isVisible == true else { return }
        commandPicker?.update(commands: pickerEntries)
    }

    private var pickerEntries: [PickerCommand] {
        let pane = workspace.panes.first { $0.id.description == pickerTarget["pane"]?.string }
        let tab = workspace.tabs.first { $0.id.description == pickerTarget["tab"]?.string }
        let missingTarget = pickerTarget["pane"] != nil && pane == nil || pickerTarget["tab"] != nil && tab == nil
        let running = Set(pluginCommands.all.filter { $0.object?["state"] == .string("running") }.compactMap { $0.object?["commandId"]?.string })
        let bindings = activeKeyBindings
        var shortcuts: [String: String] = [:]
        for key in bindings.keys.sorted(by: { $0.description < $1.description }) {
            if let id = bindings[key], shortcuts[id] == nil { shortcuts[id] = key.displayLabel }
        }
        let contributions = Dictionary(uniqueKeysWithValues: pluginCatalog.registrations.flatMap { registration in
            registration.commands.map { ($0.namespacedID(plugin: registration.id), (title: $0.title, plugin: registration.title)) }
        })
        return availableCommands.filter { $0.id != "command.picker" && !$0.contract.requiresArguments }.map { command in
            var title = command.title
            var detail = "Workspace"
            var symbol = "square.grid.2x2"
            var keywords = ""
            var unavailable: String?
            if command.id.hasPrefix("plugin.") {
                symbol = "puzzlepiece.extension"
                if let contribution = contributions[command.id] {
                    title = contribution.title
                    detail = "\(contribution.plugin) · Plugin"
                }
                if running.contains(command.id) { unavailable = "This command is already running" }
                else if missingTarget { unavailable = "The original workspace target was closed" }
            } else {
                switch command.id {
                case "settings.open": detail = "Application"; symbol = "gearshape"; keywords = "preferences configuration"
                case "config.reload": detail = "Application"; symbol = "arrow.clockwise"; keywords = "settings refresh"
                case "window.new": symbol = "macwindow.badge.plus"; keywords = "create"
                case "tab.new": symbol = "plus.square"; keywords = "create"
                case "tab.close", "pane.close": symbol = "xmark.square"; keywords = "remove close"
                case "pane.copyID": symbol = "doc.on.doc"; keywords = "clipboard panel identifier"
                case "split.left": detail = "Layout"; symbol = "rectangle.lefthalf.inset.filled"; keywords = "pane panel"
                case "split.right": detail = "Layout"; symbol = "rectangle.righthalf.inset.filled"; keywords = "pane panel"
                case "split.up": detail = "Layout"; symbol = "rectangle.tophalf.inset.filled"; keywords = "pane panel above"
                case "split.down": detail = "Layout"; symbol = "rectangle.bottomhalf.inset.filled"; keywords = "pane panel below"
                case "pane.zoom": detail = "Layout"; symbol = "arrow.up.left.and.arrow.down.right"; keywords = "maximize expand"
                case "layout.equalize": detail = "Layout"; symbol = "rectangle.split.2x2"; keywords = "balance resize"
                default:
                    if command.id.hasPrefix("browser.") { detail = "Browser"; symbol = "globe" }
                    else if command.id.hasPrefix("focus.") { detail = "Layout"; symbol = "scope"; keywords = "pane navigate" }
                    else if command.id.hasPrefix("tab.") { detail = "Tabs"; symbol = "square.on.square"; keywords = "navigate" }
                }
                if !command.contract.workspaceIndependent {
                    if missingTarget { unavailable = "The original workspace target was closed" }
                    else if tab == nil && command.id != "tab.new" { unavailable = "Open a workspace to use this command" }
                    else if command.id.hasPrefix("browser."), pane?.type != .browser { unavailable = "Focus a browser pane to use this command" }
                    else if command.id.hasPrefix("tab.select"), let number = Int(command.id.dropFirst("tab.select".count)),
                            let tab, let group = workspace.groups.first(where: { $0.tabs.contains(tab.id) }), number > group.tabs.count {
                        unavailable = "Tab \(number) is not available in this window"
                    }
                }
            }
            let shortcut = shortcuts[command.id] ?? ""
            return PickerCommand(item: .init(id: command.id, title: title, detail: detail, keywords: keywords),
                                 symbol: symbol, shortcut: shortcut, unavailable: unavailable)
        }
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let model = SettingsModel(configURL: settings.configURL)
            settingsModel = model
            model.save = { [weak self] source, changes in
                guard let self else { return }
                try self.saveSettings(source: source, changes: changes)
            }
            model.registerPlugin = { [weak self] in self?.registerPlugin() }
            settingsWindow = SettingsWindowController(model: model) { [weak self] in self?.refreshSettings(force: true) }
        }
        refreshSettings()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func configurationSource() throws -> String {
        do { return try String(contentsOf: settings.configURL, encoding: .utf8) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return "" }
    }

    func refreshSettings(force: Bool = false) {
        guard let model = settingsModel else { return }
        do {
            let source = try configurationSource()
            // Edit what is on disk, even when a missing palette made startup
            // fall back to defaults. Otherwise choosing a default cannot repair it.
            let editable = (try? AppConfiguration.parse(source)) ?? settings.current
            model.load(editable, source: source, error: settings.error, force: force)
        } catch { model.error = String(describing: error) }
        model.commands = pluginCatalog.registrations.flatMap(\.workspaceCommands) + CommandRegistry.commands
            + unavailableCommands.map { .init(id: $0, title: "\($0) (Unavailable)", key: "", shift: false) }
        model.plugins = pluginCatalog.registrations.map { registration in
            let instances = pluginInstances.all.filter { $0.registration.id == registration.id }
            let runs = pluginCommands.all.filter { $0.object?["type"]?.string == registration.id }
            let states = instances.map { $0.error ?? $0.state } + runs.suffix(1).compactMap { $0.object?["state"]?.string.map { "Last command: \($0)" } }
            return SettingsModel.Plugin(id: registration.id, title: registration.title,
                status: states.isEmpty ? (registration.commands.isEmpty ? "Not running" : "\(registration.commands.count) commands available") : states.joined(separator: ", "))
        }
    }

    func saveSettings(source: String, changes: [String: String], refreshEditor: Bool = true) throws {
        guard try configurationSource() == source else {
            throw ConfigurationError.invalid("The config file changed outside Settings. Choose Revert to load it before editing again.")
        }
        let updated = try AppConfiguration.updating(source: source, values: changes)
        // Resolve once and create stable snapshots before changing the TOML.
        let prepared = try settings.prepare(AppConfiguration.parse(updated))
        guard try configurationSource() == source else {
            throw ConfigurationError.invalid("The config file changed outside Settings. Choose Revert before applying.")
        }
        try FileManager.default.createDirectory(at: settings.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: settings.configURL, atomically: true, encoding: .utf8)
        do { _ = try reloadConfiguration(prepared: prepared) }
        catch {
            guard try configurationSource() == updated else {
                throw ConfigurationError.invalid("Apply failed and the config changed outside Settings; the external edit was preserved. \(error)")
            }
            try source.write(to: settings.configURL, atomically: true, encoding: .utf8)
            throw error
        }
        refreshSettings(force: refreshEditor)
    }

    @objc private func registerPlugin() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let registration = try PluginRegistration.parse(handle.read(upToCount: 262_145) ?? Data())
                let alert = NSAlert()
                alert.messageText = "Allow \(registration.title) to control Slate Terminal?"
                alert.informativeText = "Register only code you trust. This plugin can read terminal content, run commands, and change panes.\n\n\(registration.entryURL?.absoluteString ?? "On-demand executable commands")"
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Register")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                _ = try self.call("plugins.register", params: ["manifest": try .encoding(registration)])
            } catch { self.present(error) }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === paneTypeMenu else { return }
        let pane = workspace.tabs.first(where: { $0.id == workspace.keyTabID }).flatMap { tab in workspace.panes.first(where: { $0.id == tab.focusedPane }) }
        for item in menu.items {
            guard let type = item.representedObject as? String else { continue }
            let selectedType: PaneType = type == "terminal" ? .terminal : type == "browser" ? .browser : .registered(type)
            let selected = pane?.type == selectedType
            item.state = selected ? .on : .off
            item.isEnabled = pane != nil && !selected
        }
    }

    private var availablePaneTypes: [(name: String, id: String)] {
        [("Terminal", "terminal"), ("Browser", "browser")] + pluginCatalog.registrations.filter(\.hasPanel).map { ($0.title, $0.id) }
    }

    @objc private func changePaneType(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? String else { return }
        do {
            try synchronizeNativeGroups()
            changePaneType(try targetPaneID([:]), to: type)
        } catch { present(error) }
    }

    private func changePaneType(_ pane: PaneID, to type: String) {
        guard let content = leaves[pane], let choice = availablePaneTypes.first(where: { $0.id == type }),
              let current = workspace.panes.first(where: { $0.id == pane }) else { return }
        let nextType: PaneType = type == "terminal" ? .terminal : type == "browser" ? .browser : .registered(type)
        guard current.type != nextType else { return }
        do {
            if !settings.suppressTypeWarning {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Switch to \(choice.name)?"
                alert.informativeText = "The current pane’s contents and running processes will be closed. Switching back won’t restore its state."
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = "Don’t show again"
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Switch")
                guard runConfirmationAlert(alert) == .alertSecondButtonReturn else { return }
                // A modal alert runs another event loop: never replace a successor's contents.
                guard leaves[pane] === content else { return }
                if alert.suppressionButton?.state == .on {
                    try settings.setSuppressTypeWarning(true)
                    updateStatusMenu()
                }
            }
            _ = try call("command.run", params: ["id": .string("pane.type"), "type": .string(type), "pane": .string(pane.description), "force": .bool(true)])
        } catch { present(error) }
    }

    private var focusedBrowser: BrowserPane? {
        guard let pane = workspace.tabs.first(where: { $0.id == workspace.keyTabID })?.focusedPane else { return nil }
        return leaves[pane] as? BrowserPane
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(runMenuCommand(_:)) else { return true }
        let id = menuItem.representedObject as? String
        if id.map({ CommandContract.forCommand($0).workspaceIndependent }) == true || id == "tab.new" || id?.hasPrefix("plugin.") == true { return true }
        guard NSApp.keyWindow is WorkspaceWindow else { return false }
        if id?.hasPrefix("browser.") == true { return focusedBrowser != nil }
        return true
    }

    @objc private func runMenuCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        runUserCommand(id, params: [:])
    }

    private func runUserCommand(_ id: String, params: [String: JSONValue], capturedWithoutWorkspace: Bool = false) {
        var params = params
        params["id"] = .string(id)
        do {
            if id.hasPrefix("plugin.") {
                let operation = try preparePluginCommand(id, params: params, resolveWorkspace: !capturedWithoutWorkspace)
                Task { [weak self] in
                    do { _ = try await operation() }
                    catch let error as RPCFailure where error.code == -32022 { /* teardown/cancellation */ }
                    catch { if self?.server != nil { self?.present(error) } }
                }
                return
            }
            // A modal confirmation runs another event loop. Freeze its target
            // before another UI/CLI action can move focus to a different pane.
            if id == "pane.close" || id == "tab.close" {
                try synchronizeNativeGroups()
                if id == "pane.close", params["pane"] == nil {
                    params["pane"] = .string(try targetTab(params).focusedPane.description)
                }
                if id == "tab.close", params["tab"] == nil {
                    params["tab"] = .string(try targetTab(params).id.description)
                }
                let tab: TabID
                if id == "pane.close" {
                    let pane = try targetPaneID(params)
                    guard let owner = workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane) }) else { throw WorkspaceError.paneNotFound(pane) }
                    tab = owner.id
                } else { tab = try targetTab(params).id }
                params["expectedLayoutRevision"] = revisions.layoutRevision(tab).map(JSONValue.string)
            }
            _ = try call("command.run", params: params)
        } catch let error as RPCFailure where error.code == -32010 {
            if confirm("Close and terminate running processes?") {
                params["force"] = .bool(true)
                do { _ = try call("command.run", params: params) }
                catch { present(error) }
            }
        } catch { present(error) }
    }

    private func confirm(_ message: String) -> Bool {
        guard !settings.suppressCloseWarning else { return true }
        let alert = NSAlert()
        alert.messageText = message
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        alert.informativeText = "Applies to closing panes, tabs, windows, and quitting. Restore prompts with Slate Terminal → Reset Close Warnings."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Terminate")
        guard runConfirmationAlert(alert) == .alertSecondButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            do { try settings.setSuppressCloseWarning(true); updateStatusMenu() }
            catch { present(error); return false }
        }
        return true
    }

    private func runConfirmationAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        var responseTimer: Timer?
        if integration, let handler = testConfirmationHandler {
            let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                MainActor.assumeIsolated { handler(alert) }
            }
            RunLoop.main.add(timer, forMode: .common)
            responseTimer = timer
        }
        defer { responseTimer?.invalidate() }
        return alert.runModal()
    }

    private static func captureWindow(_ number: Int, path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(number), path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RPCFailure(code: -32000, message: "Screenshot failed") }
    }

    private func present(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = "The workspace could not be changed"
        alert.informativeText = String(describing: error)
        alert.runModal()
    }

    private func inspect() -> JSONValue {
        let panes = workspace.panes.compactMap { pane -> JSONValue? in
            guard let view = leaves[pane.id]?.view else { return nil }
            let terminal = terminals[pane.id]
            let frame = view.convert(view.bounds, to: nil)
            var info: [String: JSONValue] = ["paneId": .string(pane.id.description), "surface": .integer(Int(terminal?.surfaceIdentity ?? 0)),
                                             "cellHeight": .integer(terminal?.cellHeight ?? 0), "needsConfirmClose": .bool(terminal?.needsConfirmClose ?? false)]
            info["processName"] = processNames[pane.id].map(JSONValue.string) ?? .null
            info["width"] = .number(view.bounds.width); info["height"] = .number(view.bounds.height)
            info["x"] = .number(frame.minX); info["y"] = .number(frame.minY)
            info["attached"] = .bool(view.window != nil)
            info["terminalFocus"] = .bool(terminal?.hasTerminalFocus ?? false)
            info["firstResponder"] = .bool(view.window?.firstResponder === view)
            info["browser"] = (leaves[pane.id] as? BrowserPane)?.focusInfo ?? .null
            info["plugin"] = (leaves[pane.id] as? PluginPane)?.info ?? .null
            info["header"] = containers[pane.id]?.info ?? .null
            return .object(info)
        }
        let groups = nativeTabGroups().map { group in JSONValue.array(group.map { .string($0.description) }) }
        let windowSizes = workspace.tabs.compactMap { tab -> JSONValue? in
            guard let window = windows[tab.id] else { return nil }
            let split = window.contentViewController as? NSSplitViewController
            let geometry = (split as? WorkspaceSplitController)?.appliedGeometry ?? .null
            return .object(["tabId": .string(tab.id.description), "width": .number(window.frame.width), "height": .number(window.frame.height),
                            "visible": .bool(window.isVisible), "miniaturized": .bool(window.isMiniaturized), "key": .bool(window.isKeyWindow),
                            "splitSubviews": .integer(split?.splitView.subviews.count ?? 0),
                            "arrangedSubviews": .integer(split?.splitView.arrangedSubviews.count ?? 0),
                            "splitWidth": .number(Double(split?.splitView.bounds.width ?? 0)),
                            "appliedGeometry": geometry])
        }
        return .object(["panes": .array(panes), "nativeTabGroups": .array(groups), "windows": .array(windowSizes),
                        "appearance": .string(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"),
                        "appearanceFollowsSystem": .bool(NSApp.appearance == nil),
                        "applicationActive": .bool(NSApp.isActive), "pendingTerminalRuns": .integer(terminalControl.pendingRuns), "pendingTerminalWaits": .integer(terminalControl.pendingWaits)])
    }
}

@MainActor
final class WorkspaceWindow: NSWindow {
    var keybindingHandler: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keybindingHandler?(event) == true { return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keybindingHandler?(event) == true { return true }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class WorkspaceSplitController: NSSplitViewController {
    var onResize: ((Double) -> Void)?
    private let initialFraction: Double
    private var initialized = false
    private var applying = false
    private(set) var appliedGeometry: JSONValue = .null

    init(fraction: Double) { initialFraction = fraction; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    func applyInitialFractions() {
        guard splitView.arrangedSubviews.count == 2 else { return }
        let length = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
        guard length > 0 else { return }
        applying = true
        splitView.setPosition(length * initialFraction, ofDividerAt: 0)
        view.layoutSubtreeIfNeeded()
        appliedGeometry = .object(["length": .number(length), "fraction": .number(initialFraction), "firstWidth": .number(splitView.arrangedSubviews[0].frame.width)])
        for child in children { (child as? WorkspaceSplitController)?.applyInitialFractions() }
        initialized = true
        applying = false
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard initialized, !applying, let first = splitView.arrangedSubviews.first else { return }
        let length = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
        let firstLength = splitView.isVertical ? first.frame.width : first.frame.height
        guard length > 0, firstLength > 0, firstLength < length else { return }
        onResize?(Double(firstLength / length))
    }
}
