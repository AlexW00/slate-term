import Foundation

/// One method inventory for every trusted automation client. Families select host
/// handlers; neither discovery nor invocation selects a client-specific allowlist.
public enum AutomationMethod: String, CaseIterable, Sendable {
    case describe = "api.describe", version
    case contextGet = "context.get", contextInspect = "context.inspect"
    case workspaceGet = "workspace.get", workspaceSnapshot = "workspace.snapshot"
    case layoutsList = "layouts.list", layoutsGet = "layouts.get", layoutsFields = "layouts.fields", layoutsValidate = "layouts.validate"
    case layoutsCreate = "layouts.create", layoutsUpdate = "layouts.update", layoutsWindows = "layouts.windows"
    case layoutsCapture = "layouts.capture", layoutsOpen = "layouts.open", layoutsRestoreOriginal = "layouts.restoreOriginal", layoutsLauncher = "layouts.launcher", layoutsStartupStatus = "layouts.startupStatus"
    case layoutAppsList = "layoutApps.list", layoutAppsRefresh = "layoutApps.refresh"
    case layoutConfiguration = "layout.configuration"
    case layoutGet = "layout.get", tabsList = "tabs.list", panesList = "panes.list", paneInspect = "pane.inspect"
    case commandList = "command.list", commandRun = "command.run"
    case windowList = "window.list", windowGet = "window.get"
    case configGet = "config.get", configReload = "config.reload", configValidate = "config.validate", configPatch = "config.patch", configResetOverrides = "config.resetOverrides"
    case paletteList = "palette.list", paletteImport = "palette.import", appearanceGet = "appearance.get"
    case skillsList = "skills.list", skillsInstall = "skills.install", skillsUninstall = "skills.uninstall"
    case updatesGet = "updates.get", updatesShow = "updates.show", updatesCheck = "updates.check"
    case updatesDownload = "updates.download", updatesCancel = "updates.cancel", updatesInstall = "updates.install", updatesOpenParent = "updates.openParent"
    case welcomeGet = "welcome.get"
    case presenceList = "presence.list", presenceHold = "presence.hold", presenceRelease = "presence.release", presenceFocus = "presence.focus"
    case pluginsList = "plugins.list", pluginsRegister = "plugins.register", pluginsValidate = "plugins.validate", pluginsUnregister = "plugins.unregister"
    case pluginsEnable = "plugins.enable", pluginsDisable = "plugins.disable"
    case pluginsStatus = "plugins.status", pluginsRestart = "plugins.restart", pluginsLogs = "plugins.logs"
    case pluginSettingsGet = "plugins.settings.get", pluginSettingsPatch = "plugins.settings.patch", settingsGet = "settings.get"
    case pluginDataGet = "plugins.data.get", pluginDataPatch = "plugins.data.patch", pluginDataReset = "plugins.data.reset"
    case panelStateGet = "plugins.panelState.get", panelStatePatch = "plugins.panelState.patch", panelStateReset = "plugins.panelState.reset"
    case paneTitle = "pane.title"
    case terminalSend = "terminal.send", terminalKey = "terminal.key", terminalCapture = "terminal.capture"
    case terminalSearch = "terminal.search"
    case terminalRun = "terminal.run", terminalWait = "terminal.wait", terminalStart = "terminal.start"
    case terminalOperations = "terminal.operations", terminalOperationStatus = "terminal.operationStatus"
    case terminalOperationResult = "terminal.operationResult", terminalOperationWait = "terminal.operationWait"
    case panesSend = "panes.send", panesCapture = "panes.capture"
    case eventsHead = "events.head", eventsPoll = "events.poll", eventsEmit = "events.emit"
    case notificationsPost = "notifications.post", notificationsList = "notifications.list"
    case notificationsDismiss = "notifications.dismiss", notificationsStatus = "notifications.status"
    case webGet = "web.get", webSnapshot = "web.snapshot", webClick = "web.click", webFill = "web.fill"
    case webSelect = "web.select", webScroll = "web.scroll", webWait = "web.wait", webScreenshot = "web.screenshot"
    case webFocus = "web.focus", webKey = "web.key", webCheck = "web.check", webSetValue = "web.setValue"
    case webFileChooser = "web.fileChooser", webChooseFiles = "web.chooseFiles", webCancelFileChooser = "web.cancelFileChooser"
    case webDialog = "web.dialog", webRespondDialog = "web.respondDialog"
    case browserShowDownloads = "browser.showDownloads"
    case browserDownloads = "browser.downloads", browserDownload = "browser.download"
    case browserSaveDownload = "browser.saveDownload", browserCancelDownload = "browser.cancelDownload"
    case browserPopups = "browser.popups", browserClosePopup = "browser.closePopup"
    case browserClearData = "browser.clearData", browserClearSiteData = "browser.clearSiteData"
    case browserListData = "browser.listData", browserRemoveSiteData = "browser.removeSiteData"
    case browserGet = "browser.get", browserNavigate = "browser.navigate", browserSnapshot = "browser.snapshot"
    case browserClick = "browser.click", browserFill = "browser.fill", browserSelect = "browser.select"
    case browserScroll = "browser.scroll", browserWait = "browser.wait", browserEval = "browser.eval", browserScreenshot = "browser.screenshot"
    case serviceStart = "plugins.service.start", serviceStop = "plugins.service.stop", serviceList = "plugins.service.list"
    case serviceStatus = "plugins.service.status", serviceLogs = "plugins.service.logs", serviceReady = "service.ready"
    case shellUpdate = "shell.update", shellRunInput = "shell.runInput"

    public enum Family: String, Sendable { case synchronous, contextual, notifications, terminal, terminalOperations, browser, web, events, pluginRuntime, pluginPersistence, services, integration }
    public var family: Family {
        switch self {
        case .layoutAppsList, .layoutAppsRefresh, .layoutsList, .layoutsGet, .layoutsFields, .layoutsValidate, .layoutsCreate, .layoutsUpdate, .layoutsWindows, .layoutsCapture, .layoutsOpen, .layoutsRestoreOriginal, .layoutsLauncher, .layoutsStartupStatus,
             .describe, .version, .contextGet, .workspaceGet, .workspaceSnapshot, .layoutGet, .tabsList, .panesList, .paneInspect,
             .commandList, .commandRun, .windowList, .windowGet, .configGet, .configReload, .configValidate, .configPatch, .configResetOverrides,
             .paletteList, .paletteImport, .appearanceGet, .welcomeGet, .skillsList, .skillsInstall, .skillsUninstall, .pluginsList, .pluginsRegister, .pluginsValidate, .pluginsUnregister, .pluginsEnable, .pluginsDisable, .pluginsStatus, .pluginsLogs,
             .pluginSettingsGet, .pluginSettingsPatch, .panesSend, .panesCapture, .presenceList, .presenceHold, .presenceRelease, .presenceFocus,
             .updatesGet, .updatesShow, .updatesCheck, .updatesDownload, .updatesCancel, .updatesInstall, .updatesOpenParent: .synchronous
        case .notificationsPost, .notificationsList, .notificationsDismiss, .notificationsStatus: .notifications
        case .layoutConfiguration, .contextInspect, .settingsGet, .paneTitle: .contextual
        case .terminalSend, .terminalKey, .terminalCapture, .terminalRun, .terminalWait, .terminalStart, .terminalSearch: .terminal
        case .terminalOperations, .terminalOperationStatus, .terminalOperationResult, .terminalOperationWait: .terminalOperations
        case .pluginDataGet, .pluginDataPatch, .pluginDataReset, .panelStateGet, .panelStatePatch, .panelStateReset: .pluginPersistence
        case .browserShowDownloads, .browserDownloads, .browserDownload, .browserSaveDownload, .browserCancelDownload, .browserPopups, .browserClosePopup, .browserGet, .browserNavigate, .browserSnapshot, .browserClick, .browserFill, .browserSelect,
             .browserScroll, .browserWait, .browserEval, .browserScreenshot, .browserClearData, .browserClearSiteData, .browserListData, .browserRemoveSiteData: .browser
        case .webGet, .webSnapshot, .webClick, .webFill, .webSelect, .webScroll, .webWait, .webFocus, .webKey, .webCheck, .webSetValue, .webDialog, .webRespondDialog, .webFileChooser, .webChooseFiles, .webCancelFileChooser, .webScreenshot: .web
        case .eventsHead, .eventsPoll, .eventsEmit: .events
        case .pluginsRestart: .pluginRuntime
        case .serviceStart, .serviceStop, .serviceList, .serviceStatus, .serviceLogs, .serviceReady: .services
        case .shellUpdate, .shellRunInput: .integration
        }
    }
    public var isPublic: Bool { family != .integration }
    public static var publicMethods: [Self] { allCases.filter(\.isPublic).sorted { $0.rawValue < $1.rawValue } }

    public var admission: AdmissionAction {
        switch self {
        case .shellUpdate, .shellRunInput: .authenticatedIntegration
        case .serviceReady, .serviceStop: .emergencyControl
        case .layoutAppsList, .layoutsList, .layoutsGet, .layoutsFields, .layoutsValidate, .layoutsWindows, .layoutsStartupStatus, .layoutConfiguration,
             .describe, .version, .contextGet, .contextInspect, .workspaceGet, .workspaceSnapshot, .layoutGet,
             .tabsList, .panesList, .paneInspect, .commandList, .windowList, .windowGet, .configGet, .configValidate,
             .paletteList, .appearanceGet, .welcomeGet, .skillsList, .pluginsList, .pluginsValidate, .pluginsStatus, .pluginsLogs, .pluginSettingsGet, .settingsGet, .pluginDataGet, .panelStateGet,
             .terminalOperations, .terminalOperationStatus, .terminalOperationResult, .terminalOperationWait,
             .terminalCapture, .terminalWait, .panesCapture, .eventsHead, .eventsPoll, .webDialog, .webFileChooser, .webGet, .webSnapshot, .webWait,
             .browserDownloads, .browserDownload, .browserPopups, .browserGet, .browserSnapshot, .browserWait, .browserListData, .serviceList, .serviceStatus, .serviceLogs,
             .notificationsList, .notificationsStatus, .presenceList, .presenceHold, .presenceRelease, .updatesGet: .read
        case .layoutAppsRefresh, .layoutsCreate, .layoutsUpdate, .layoutsCapture, .layoutsOpen, .layoutsRestoreOriginal, .layoutsLauncher, .commandRun, .configReload, .configPatch, .configResetOverrides, .paletteImport, .skillsInstall, .skillsUninstall, .pluginsRegister, .pluginsUnregister, .pluginsEnable, .pluginsDisable,
             .pluginsRestart, .pluginSettingsPatch, .pluginDataPatch, .pluginDataReset, .panelStatePatch, .panelStateReset, .paneTitle, .terminalSend,
             .terminalKey, .terminalRun, .terminalStart, .terminalSearch, .panesSend, .eventsEmit, .webClick, .webFill, .webSelect, .webScroll,
             .webFocus, .webKey, .webCheck, .webSetValue, .webRespondDialog, .webChooseFiles, .webCancelFileChooser, .webScreenshot, .browserNavigate, .browserClick, .browserFill, .browserSelect, .browserScroll,
             .browserShowDownloads, .browserSaveDownload, .browserCancelDownload, .browserClosePopup, .browserEval, .browserScreenshot, .browserClearData, .browserClearSiteData, .browserRemoveSiteData, .serviceStart,
             .notificationsPost, .notificationsDismiss, .presenceFocus, .updatesShow, .updatesCheck, .updatesDownload, .updatesCancel, .updatesInstall, .updatesOpenParent: .mutation
        }
    }

    /// Resolve caller defaults BEFORE validating target-dependent guards. Explicit
    /// targets never inherit a conflicting sibling tab/pane or another namespace.
    public func resolving(_ input: [String: JSONValue], defaults: AutomationDefaults) -> [String: JSONValue] {
        var params = input
        let explicitTarget = input["pane"] != nil || input["tab"] != nil || input["contextPane"] != nil
        func inheritPane() {
            guard !explicitTarget else { return }
            if let pane = defaults.pane { params["pane"] = .string(pane.description) }
            if let tab = defaults.tab { params["tab"] = .string(tab.description) }
        }
        func inheritScope() {
            if params["scope"] == nil, let scope = defaults.scope { params["scope"] = .string(scope) }
        }
        switch self {
        case .contextGet, .workspaceSnapshot:
            inheritScope()
            if params["scope"] != .string("global") { inheritPane() }
        case .notificationsPost:
            if params["active"] != .bool(true) { inheritPane() }
        case .panelStateGet, .panelStatePatch, .panelStateReset, .layoutConfiguration, .contextInspect, .layoutGet, .paneInspect, .paneTitle,
             .webGet, .webSnapshot, .webClick, .webFill, .webSelect, .webScroll, .webWait, .webFocus, .webKey, .webCheck, .webSetValue, .webDialog, .webRespondDialog, .webFileChooser, .webChooseFiles, .webCancelFileChooser, .webScreenshot,
             .browserShowDownloads, .browserDownloads, .browserDownload, .browserSaveDownload, .browserCancelDownload, .browserPopups, .browserClosePopup, .browserGet, .browserNavigate, .browserSnapshot, .browserClick, .browserFill, .browserSelect,
             .browserScroll, .browserWait, .browserEval, .browserScreenshot, .browserClearSiteData, .panesSend, .panesCapture:
            inheritPane()
        case .terminalSend, .terminalKey, .terminalCapture, .terminalRun, .terminalWait, .terminalStart, .terminalSearch:
            inheritPane(); inheritScope()
        case .commandRun:
            if let id = input["id"]?.string {
                if !CommandContract.forCommand(id).workspaceIndependent { inheritPane() }
                if id.hasPrefix("plugin.") { inheritScope() }
            }
        case .pluginDataGet, .pluginDataPatch, .pluginDataReset, .settingsGet, .pluginSettingsGet, .pluginSettingsPatch:
            if params["id"] == nil, let plugin = defaults.pluginID { params["id"] = .string(plugin) }
        case .terminalOperations, .terminalOperationStatus, .terminalOperationResult, .terminalOperationWait,
             .layoutAppsList, .layoutAppsRefresh, .layoutsList, .layoutsGet, .layoutsFields, .layoutsValidate, .layoutsCreate, .layoutsUpdate, .layoutsWindows, .layoutsCapture, .layoutsOpen, .layoutsRestoreOriginal, .layoutsLauncher, .layoutsStartupStatus,
             .describe, .version, .workspaceGet, .tabsList, .panesList, .commandList, .windowList, .windowGet,
             .configGet, .configReload, .configValidate, .configPatch, .configResetOverrides, .paletteList, .paletteImport, .appearanceGet, .welcomeGet,
             .skillsList, .skillsInstall, .skillsUninstall, .pluginsList, .pluginsRegister, .pluginsValidate, .pluginsUnregister, .pluginsEnable, .pluginsDisable, .pluginsStatus, .pluginsRestart, .pluginsLogs,
             .eventsHead, .eventsPoll, .eventsEmit, .serviceStart, .serviceStop, .serviceList, .serviceStatus,
             .serviceLogs, .serviceReady, .shellUpdate, .shellRunInput, .browserClearData, .browserListData, .browserRemoveSiteData,
             .notificationsList, .notificationsDismiss, .notificationsStatus, .presenceList, .presenceHold, .presenceRelease, .presenceFocus,
             .updatesGet, .updatesShow, .updatesCheck, .updatesDownload, .updatesCancel, .updatesInstall, .updatesOpenParent: break
        }
        return params
    }
}

/// Defaults are host-supplied context, never a permission grant. Missing context
/// leaves inputs absent for the operation's common validation/fallback policy.
public struct AutomationDefaults: Sendable {
    public let pane: PaneID?
    public let tab: TabID?
    public let pluginID: String?
    public let instanceID: String?
    public let scope: String?
    public init(pane: PaneID? = nil, tab: TabID? = nil, pluginID: String? = nil, instanceID: String? = nil, scope: String? = nil) {
        self.pane = pane; self.tab = tab; self.pluginID = pluginID; self.instanceID = instanceID; self.scope = scope
    }
}
