import Foundation

/// Existing capability values shared by native discovery and its constant-value
/// schema. Keep dynamic app identity, command rows and contracts out of this table.
public enum AutomationCapabilities {
    public static let updates: JSONValue = .object([
        "version": .integer(1), "methods": .array(UpdateAction.allCases.map { .string($0.method) }),
        "commands": .array([.string("updates.check"), .string("updates.show")]),
        "scope": .string("application"), "eventTopic": .string("host.updates.changed"),
        "get": .string("Current state, signed release notes, progress, and updateId; no network request"),
        "actionInput": .string("download/cancel: {updateId}; install: {updateId, confirm: true}; optional expectedInstanceId"),
        "phaseValues": .array(["idle", "unavailable", "checking", "available", "downloading", "verifying", "ready", "installing", "downloadError", "verificationError", "checkError", "current"].map(JSONValue.string)),
        "resultFields": .array(["revision", "updateId", "phase", "currentVersion", "release", "receivedBytes", "expectedBytes", "detail", "windowVisible"].map(JSONValue.string)),
        "automaticInstallation": .bool(false), "installationRequiresConfirmation": .bool(true),
        "errors": .object(["invalid": .integer(-32602), "conflict": .integer(APIError.conflict), "unavailable": .integer(APIError.unavailable)])
    ])

    public static let pluginPersistence: JSONValue = .object([
        "version": .integer(1), "dataScope": .string("stateDirectoryAndPluginId"),
        "panelScope": .string("pluginContentLifetime"), "runtimeScopeControlsStorage": .bool(false),
        "legacyInstanceStorage": .bool(false), "resetAdvancesEmptyRevision": .bool(true),
        "dataMethods": .array(["plugins.data.get", "plugins.data.patch", "plugins.data.reset"].map(JSONValue.string)),
        "panelMethods": .array(["plugins.panelState.get", "plugins.panelState.patch", "plugins.panelState.reset"].map(JSONValue.string)),
        "panelResetCommand": .string("plugins.panelState.reset"),
        "events": .array(["host.plugin.data.changed", "host.plugin.panel-state.changed"].map(JSONValue.string)),
        "dataWriteGuard": .string("expectedDataRevision"),
        "panelWriteGuards": .array(["expectedPanelId", "expectedStateRevision"].map(JSONValue.string)),
        "dataResetRequiresForce": .bool(true), "panelPersistence": .string("workspacePersistence"),
        "bounds": .object(["dataBytes": .integer(PluginPersistence.dataBytes), "dataKeys": .integer(1024),
            "stateBytes": .integer(PluginPersistence.stateBytes), "stateKeys": .integer(128),
            "configurationBytes": .integer(PluginPersistence.configurationBytes), "workspaceBytes": .integer(PluginPersistence.workspaceBytes),
            "patchBytes": .integer(PluginPersistence.patchBytes), "valueBytes": .integer(PluginPersistence.valueBytes), "operations": .integer(32)]),
        "readFields": .object(["data": .array(["id", "values", "revision"].map(JSONValue.string)),
            "panel": .array(["pluginId", "paneId", "panelId", "values", "revision"].map(JSONValue.string))]),
        "mutationFields": .object(["data": .array(["id", "revision", "changed", "persisted", "operationId"].map(JSONValue.string)),
            "panel": .array(["pluginId", "paneId", "panelId", "revision", "changed", "operationId", "outcome", "workspaceRevision", "workspacePersistence"].map(JSONValue.string))]),
        "errors": .object(["invalid": .integer(-32602), "conflict": .integer(APIError.conflict),
            "unavailable": .integer(APIError.unavailable), "incompatible": .integer(APIError.incompatible), "writeFailed": .integer(APIError.settingsWriteFailed)])
    ])

    public static let presence: JSONValue = .object([
        "version": .integer(1),
        "metadata": .string("metadata: {version: 1, actor?: {name, note?, home?, origin?: {instanceId, sessionId}}}"),
        "originVersion": .integer(1),
        "focus": .object(["method": .string("presence.focus"), "input": .string("{activityId: string}"),
                          "result": .string("{focused: boolean, paneId?: string, tabId?: string, windowId?: string}"),
                          "invalidOrigin": .string("no-op"), "invalidParameters": .integer(-32602)]),
        // Presence is for agents: plugin pages and services cannot claim an actor or hold.
        "actorOrigins": .array([.string("administrative")]),
        "ignoredWhenCaused": .bool(true),
        "maximumNameLength": .integer(PresenceActor.maximumNameLength),
        "maximumNoteCharacters": .integer(PresenceActor.maximumNoteCharacters),
        "maximumNoteBytes": .integer(PresenceActor.maximumNoteBytes),
        "maximumActivities": .integer(PresenceTracker.maximumRecords),
        "minimumHoldMilliseconds": .integer(Int(PresenceTracker.minimumHold * 1000)),
        "defaultLeaseSeconds": .integer(Int(PresenceTracker.defaultLeaseSeconds)),
        "maximumLeaseSeconds": .integer(Int(PresenceTracker.maximumLeaseSeconds)),
        "topic": .string("host.presence.changed"),
        "methods": .array(["presence.list", "presence.hold", "presence.release", "presence.focus"].map(JSONValue.string)),
        "setting": .string("agents.show_activity"),
        // A click or presence.focus moves focus to the agent's own pane, so presence is not display only.
        "displayOnly": .bool(false),
        "actorAuthorization": .string("selfDeclaredNoAuthorization"),
        "explicitFocusOnly": .bool(true),
    ])

    public static let causation: JSONValue = .object([
        "version": .integer(1), "metadata": .string("metadata: {version: 1, cause?: deliveryContext}"),
        "maximumDepth": .integer(CausationReferences.maximumDepth), "referenceTTLMilliseconds": .integer(300_000),
        "maximumReferences": .integer(4096), "maximumReferencesPerAudience": .integer(256),
        "pluginMutationsPerSecond": .integer(10), "pluginBurst": .integer(20),
        "globalMutationsPerSecond": .integer(100), "globalBurst": .integer(100),
        "recovery": .string("Inspect authoritative state; references may expire or be evicted; never automatically replay mutations")
    ])

    public static let appearance: JSONValue = .object([
        "version": .integer(1), "method": .string("appearance.get"), "topic": .string("host.appearance.changed"),
        "revision": .string("opaqueContentHash"), "pageInjection": .string("registeredPluginMainFrame"),
        "variables": .array((["--st-bg", "--st-fg", "--st-cursor", "--st-selection-bg", "--st-selection-fg"]
            + (0..<16).map { "--st-ansi-\($0)" } + ["--st-font-mono", "--st-font-mono-size"]).map(JSONValue.string)),
    ])

    public static let notifications: JSONValue = .object([
        "version": .integer(1), "capacity": .integer(NotificationStore.capacity),
        "titleBytes": .integer(NotificationStore.titleBytes), "bodyBytes": .integer(NotificationStore.bodyBytes),
        "keyBytes": .integer(NotificationStore.keyBytes), "persistent": .bool(false),
        "postParameters": .object(["title": .string("required nonempty string"), "body": .string("optional string"),
            "key": .string("optional replacement key"), "pane": .string("optional pane ID"), "tab": .string("optional tab ID"),
            "active": .string("true, exclusive with pane/tab"), "expectedAnchorSessionId": .string("optional terminal lifetime guard")]),
        "postResultFields": .array(["id", "disposition", "reason", "retained"].map(JSONValue.string)),
        "globalRatePerSecond": .integer(5), "globalBurst": .integer(10), "sourceRatePerSecond": .integer(1), "sourceBurst": .integer(5),
        "pendingPostLimit": .integer(32), "authorizationQueryLimit": .integer(1),
        "escapeSequences": .array([.string("OSC 9"), .string("OSC 777")]),
        "automaticThresholdSeconds": .integer(30), "permissionPromptOnPost": .bool(false),
        "submissionIsDelivery": .bool(false), "listOrder": .string("oldestFirst"),
        "navigationCommands": .array([.string("notifications.next"), .string("notifications.open")]),
        "topic": .string("host.notifications.changed")])

    public static let welcome: JSONValue = .object([
        "version": .integer(1), "getMethod": .string("welcome.get"),
        "readCommand": .string("welcome.read"), "unreadCommand": .string("welcome.unread"), "resetCommand": .string("welcome.reset"),
        "scope": .string("appStateDirectory"), "presentation": .string("nativeInline"),
        "shellIntegrationRequired": .bool(false), "resetAffects": .string("futureTerminalSessions"),
        "eventTopic": .string("host.welcome.changed"), "guard": .string("expectedInstanceId"),
        "resultFields": .array(["content", "acknowledged", "automaticDisplayEnabled", "revision", "error"].map(JSONValue.string)),
        "errors": .object(["invalid": .integer(-32602), "writeFailed": .integer(APIError.settingsWriteFailed)])
    ])

    public static let backgroundServices: JSONValue = .object(["version": .integer(1), "mode": .string("manual"), "automaticStartup": .bool(false), "automaticRestart": .bool(false),
                 "maximumReservations": .integer(16), "maximumPeers": .integer(4), "maximumPolls": .integer(1),
                 "logBytesPerStream": .integer(65_536), "capabilities": .string("sharedAutomationAPI"),
                 "states": .array(["stopped", "starting", "ready", "stopping", "failed"].map(JSONValue.string)),
                 "topic": .string("host.service.state.changed")])

    public static let fields: [String: JSONValue] = [
            "pluginPersistence": pluginPersistence,
            "updates": updates, "presence": presence,
            "workspaceFocus": .object([
                "structuralDefault": .string("preserve"), "creationPolicy": .array(["preserve", "new"].map(JSONValue.string)),
                "movePolicy": .array(["preserve", "target"].map(JSONValue.string)),
                "implicitWindowActivation": .bool(false), "nativeUserActionsSelectResults": .bool(true)
            ]),
            "windowControls": .object([
                "version": .integer(1), "commands": .array(NativeWindowAction.commands.sorted().map(JSONValue.string)),
                "target": .string("selectedNativeWindowId"), "framePolicy": .string("containedInOneVisibleScreen"),
                "fullscreenCompletion": .string("asynchronousPollWindowGet"), "implicitActivation": .bool(false)
            ]),
            "warningSuppression": .object([
                "commands": .array(["warnings.close.set", "warnings.type.set"].map(JSONValue.string)),
                "parameter": .string("suppressed"), "type": .string("boolean"), "changesDestructiveConsent": .bool(false)
            ]),
            "apiVersion": .integer(PluginCompatibility.currentAPIVersion), "identityGuards": .bool(true),
            "workspaceRevisions": .bool(true), "surface": .string("trusted"),
            "workspaceRestoration": .object([
                "version": .integer(1), "configuration": .string("layout.restore_workspace"),
                "locations": .array([.string("terminalWorkingDirectory"), .string("normalBrowserURL")]),
                "windowGeometry": .string("windowedFrameClampedToCurrentScreens"),
                "directoryFallback": .string("homeIfMissingOrInaccessible"),
                "privateBrowserURLs": .bool(false), "replaysCommands": .bool(false),
                "restoresProcesses": .bool(false), "persistsTranscripts": .bool(false),
                "maximumDirectoryBytes": .integer(4_096), "maximumURLBytes": .integer(16_384),
                "autosaveCoalescingMilliseconds": .integer(250)
            ]),
            "shellIntegration": .object([
                // Mirrors docs/configuration.md: bash 3.2-4.3 reports state but refuses runs.
                "version": .integer(1), "localShells": .array(ShellKind.allCases.map { .string($0.rawValue) }),
                "minimumBashRunVersion": .string("4.4"), "olderBashReportsStateOnly": .bool(true),
                "minimumFishVersion": .string("3.1"), "paneFields": .array([.string("shell"), .string("runAvailable")]),
                "runShellParameter": .string("shell"),
                "remoteIntegration": .bool(false), "requiresAuthenticatedPrompt": .bool(true),
                "rejectsNonemptyOrContinuationBuffer": .bool(true), "editsUserStartupFiles": .bool(false)
            ]),
            "terminalOperations": .object([
                "version": .integer(1), "startMethod": .string(AutomationMethod.terminalStart.rawValue),
                "lookupMethods": .array(AutomationMethod.publicMethods.filter { $0.family == .terminalOperations }.map { .string($0.rawValue) }),
                "handleFields": .array(["commandId", "paneId", "sessionId"].map(JSONValue.string)),
                "lookupRequired": .array([.string("commandId")]), "lookupTarget": .string("handleNotLivePane"),
                "listParameters": .array([]), "lookupGuards": .array([.string("expectedInstanceId")]),
                "states": .array(TerminalOperationState.allCases.map { .string($0.rawValue) }),
                "maximumActiveAndReserved": .integer(TerminalOperationStore.maximumActive),
                "maximumRecords": .integer(TerminalOperationStore.maximumRecords),
                "finishedRetentionSeconds": .integer(Int(TerminalOperationStore.retention.components.seconds)),
                "capacityEviction": .string("oldestFinishedFirst"), "maximumWaiters": .integer(TerminalOperations.maximumWaiters),
                "defaultWaitMilliseconds": .integer(30_000), "maximumWaitMilliseconds": .integer(TerminalOperations.maximumTimeoutMilliseconds),
                "waitCancellationStopsExecution": .bool(false), "waitTimeoutDropsTracking": .bool(false),
                "repeatableResults": .bool(true), "crossRestartDurability": .bool(false),
                "resultText": .string("boundedScreenAtCompletionNotCommandStdout"), "maximumOutputBytes": .integer(TerminalOutput.maximumBytes),
                "nativeInteraction": .string("existingTerminalInputAndInterruptKeys"),
                "errors": .object(["invalid": .integer(-32602), "unavailableHandle": .integer(APIError.unavailable),
                    "waitTimeout": .integer(-32024), "notReadyOrFailed": .integer(-32042)])
            ]),
            "terminalHistory": .object([
                "version": .integer(1), "maximumBytes": .integer(TerminalHistoryRequest.maximumBytes),
                "maximumLines": .integer(TerminalHistoryRequest.maximumLines), "defaultLines": .integer(2_000),
                "range": .string("retained-tail-including-active-screen"), "commandStdout": .bool(false),
                "exportOverwrites": .bool(false), "persistentTranscripts": .bool(false)
            ]),
            "terminalSearch": .object([
                "version": .integer(1), "method": .string("terminal.search"),
                "actions": .array(["get", "set", "next", "previous", "end"].map(JSONValue.string)),
                "queryMaximumBytes": .integer(4_096), "retainedHistory": .bool(true),
                "resultsAsynchronous": .bool(true), "selectedIndexBase": .integer(0)
            ]),
            "webAutomation": .object([
                "version": .integer(1), "paneKinds": .array([.string("browser"), .string("private-browser"), .string("registeredPlugin")]),
                "identity": .array([.string("viewId"), .string("documentId")]),
                "selectorMutationGuardsRequired": .bool(true), "mainDocumentOnly": .bool(true),
                "pendingActionsPerView": .integer(32), "pendingWebKitOperationsPerView": .integer(32), "resultByteLimit": .integer(900_000),
                "actions": .array(["focus", "key", "check", "setValue"].map(JSONValue.string)),
                "keyEvents": .string("syntheticWithLimitedDefaults"), "typedInputs": .array(["number", "date", "time", "datetime-local", "range"].map(JSONValue.string)),
                "screenshot": .bool(true), "screenshotInactiveTabs": .bool(true),
                "screenshotRequiresAttachedLayout": .bool(true), "screenshotViewportOnly": .bool(true),
                "domRequiresVisiblePane": .bool(true), "pluginEvaluation": .bool(false)
            ]),
            "browserData": .object([
                "version": .integer(1), "persistentProfile": .string("appWide"), "privateProfile": .string("perPaneEphemeral"),
                "clearAllMethod": .string("browser.clearData"), "clearSiteMethod": .string("browser.clearSiteData"),
                "listMethod": .string("browser.listData"), "removeStoredSiteMethod": .string("browser.removeSiteData"),
                "storedSiteRequired": .array([.string("site")]), "storedSites": .string("sortedUniqueWebKitRecordDisplayNames"),
                "siteRequired": .array([.string("pane"), .string("url")]), "siteGranularity": .string("webkitDomainGroupIncludingSubdomains"),
                "apiConfirmation": .bool(false), "nativeConfirmation": .bool(true),
                "resultFields": .array(["cleared", "scope", "storage", "host"].map(JSONValue.string))
            ]),
            "browserNavigation": .object([
                "schemes": .array(["http", "https", "about", "file"].map(JSONValue.string)),
                "aboutBlankOnly": .bool(true), "localFiles": .bool(true), "absolutePaths": .bool(true),
                "fileReadAccess": .string("containingDirectory"), "pluginBridge": .bool(false)
            ]),
            "causation": causation,
            "backgroundServices": backgroundServices,
            "pluginCompatibility": .object([
                "manifestVersion": .integer(PluginCompatibility.currentManifestVersion),
                "apiVersion": .integer(PluginCompatibility.currentAPIVersion),
                "requirements": .array(["minimumAPIVersion", "maximumAPIVersion", "requiredMethods", "requiredCommands"].map(JSONValue.string)),
                "missingDeclaration": .string("manifest-1-api-1"), "checkedBeforeExecution": .bool(true),
                "launchRevalidation": .bool(true), "permissionSystem": .bool(false)
            ]),
            "pluginManagement": .object([
                "version": .integer(2), "enableMethod": .string("plugins.enable"), "disableMethod": .string("plugins.disable"),
                "installMethod": .string("plugins.register"), "validateMethod": .string("plugins.validate"),
                "installRequired": .array([.string("packagePath")]), "installOptional": .array([.string("replace")]),
                "format": .string("zip"), "manifest": .string("plugin.json"), "managedFiles": .bool(true),
                "registry": .string("plugins/registry.json"), "packageRootEnvironment": .string("SLATE_TERM_PLUGIN_ROOT"),
                "limits": .object(["archiveBytes": .integer(134_217_728), "extractedBytes": .integer(536_870_912),
                    "fileBytes": .integer(67_108_864), "entries": .integer(10_000), "manifestBytes": .integer(262_144)]),
                "errors": .object(["invalid": .integer(-32602), "conflict": .integer(APIError.conflict),
                    "inUse": .integer(-32010), "writeFailed": .integer(APIError.settingsWriteFailed),
                    "incompatible": .integer(APIError.incompatible)]),
                "removeMethod": .string("plugins.unregister"), "required": .array([.string("id")]),
                "forceClosesPanes": .bool(true), "persisted": .bool(true), "retainsSavedData": .bool(true),
                "listEnabledField": .string("enabled"), "enableStartsProcesses": .bool(false)
            ]),
            "appearance": appearance,
            "notifications": notifications,
            "welcome": welcome,
            "settingsLifecycle": .object([
                "version": .integer(1), "scope": .string("configurationSourceAndApplied"),
                "topics": .array(["host.settings.source.changed", "host.settings.changed", "host.plugin.settings.changed", "host.settings.failed"].map(JSONValue.string)),
                "globalProjection": .string("opaqueCorrelationAndRevisions"),
                "changedPathKind": .string("topLevel"), "maximumChangedPaths": .integer(32), "maximumPathBytes": .integer(4096)
            ]),
            "commandLifecycle": .object([
                "version": .integer(1), "scope": .string("registeredCommands"),
                "topics": .array([.string("host.command.started"), .string("host.command.finished")]),
                "revisionSampling": .string("publicationTime"), "includesOutput": .bool(false)
            ]),
            "workspaceCommit": .object([
                "version": .integer(1), "scope": .string("workspace-model mutations"),
                "additionalMethods": .array([.string("plugins.unregister"), .string("plugins.enable"), .string("plugins.disable"), .string("layouts.open")]),
                "resultFields": .array(["operationId", "outcome", "workspaceRevision", "workspacePersistence"].map(JSONValue.string)),
                "outcomes": .array(["committed", "unchanged"].map(JSONValue.string)),
                "workspacePersistence": .array(WorkspacePersistence.allCases.map { .string($0.rawValue) }),
                "nativeDividerCoalescing": .bool(false)
            ]),
            "pluginReload": .object([
                "command": .string("plugins.reload"), "target": .string("pane"),
                "resultFields": .array([.string("paneId"), .string("reloading")]), "completion": .string("acceptedNotDocumentReady")
            ]),
            "tabTitle": .object([
                "version": .integer(1), "defaultTitle": .string(TabTitle.defaultTitle),
                "commands": .array(["tab.title.set", "tab.title.clear", "tab.rename"].map(JSONValue.string)),
                "stateFields": .array(["manualTitle", "title"].map(JSONValue.string)),
                "maximumCharacters": .integer(TabTitle.maximumCharacters), "maximumUTF8Bytes": .integer(TabTitle.maximumBytes),
                "trimmed": .bool(true), "emptyClears": .bool(true), "controlCharacters": .bool(false),
                "eventTopic": .string("host.tab.title.changed"), "persisted": .bool(true),
                "savedLayoutOption": .bool(true), "changesLayoutRevision": .bool(false)
            ]),
            "paneMovement": .object([
                "command": .string("pane.move"), "chooserCommand": .string("pane.move.chooseDestination"),
                "sameAppCrossWindow": .bool(true), "sourceGuard": .string("expectedLayoutRevision"),
                "crossTabGuard": .string("expectedWorkspaceRevision"), "placement": .string("besideDestinationPane"),
                "tabScopedPluginContent": .string("recreatedInDestinationScope"), "closesEmptySourceTab": .bool(true),
                "resultFields": .array(["paneId", "tabId", "layoutRevision", "path", "sourceTabId", "sourceTabClosed", "sourceLayoutRevision", "contentRecreated"].map(JSONValue.string)),
                "errors": .object(["invalid": .integer(-32602), "conflict": .integer(APIError.conflict), "unavailable": .integer(APIError.unavailable)])
            ]),
            "paneHeader": .object([
                "version": .integer(1), "stateField": .string("headerVisible"),
                "commands": .array(["pane.header.show", "pane.header.hide", "pane.header.toggle"].map(JSONValue.string)),
                "eventTopic": .string("host.pane.header.changed"), "defaultVisible": .bool(true),
                "persisted": .bool(true), "savedLayoutOption": .bool(true), "changesLayoutRevision": .bool(false)
            ]),
            "savedLayouts": .object([
                "version": .integer(1), "targetKind": .string("windowGroup"),
                "targetDiscovery": .string("layouts.windows"), "openMode": .string("newWindow"),
                "replacementSupported": .bool(false), "launcherMethod": .string("layouts.launcher"),
                "launcherOptions": .array(["name", "icon"].map(JSONValue.string)),
                "launcherIcons": .array(SavedLayoutLauncherOptions.icons.map(JSONValue.string)),
                "defaultTerminalDirectory": .string("~/"),
                "writeGuard": .string("expectedSavedLayoutRevision"), "configurationTarget": .string("pane"),
                "startupLifetime": .string("committedTerminalSession"), "mergeSupported": .bool(false)
            ]),
            "guards": .array(APIGuards.names.sorted().map(JSONValue.string)),
            "methods": .array(AutomationMethod.publicMethods.map { .string($0.rawValue) }),
            "limits": .object(["inspectionPageSize": .integer(64), "inspectionBytes": .integer(262144), "eventWaitMilliseconds": .integer(25000)]),
            "retryPolicy": .string("Mutations are not automatically retried; correlation IDs are not idempotency keys")
            ]
}
