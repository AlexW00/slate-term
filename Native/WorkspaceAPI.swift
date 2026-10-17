import AppKit
import SlateTermCore

/// Production adapters. Debug inspection deliberately remains separate from this schema.
extension WorkspaceHost {
    static let apiGuardKeys = APIGuards.names

    func withoutAPIGuards(_ params: [String: JSONValue]) -> [String: JSONValue] {
        params.filter { !Self.apiGuardKeys.contains($0.key) }
    }

    func validateAPIGuards(_ params: [String: JSONValue], method: String) throws {
        var movePanes: [PaneID] = []
        if method == "command.run", params["id"] == .string("pane.move") {
            for key in ["pane", "target"] {
                if let value = params[key] {
                    guard let raw = value.string else { throw RPCFailure(code: -32602, message: "\(key) must be a pane ID") }
                    guard let pane = try? PaneID(parsing: raw) else { throw RPCFailure(code: -32602, message: "\(key) must be a pane ID") }
                    movePanes.append(pane)
                }
            }
        }
        let contributed = method == "command.run" && params["id"]?.string?.hasPrefix("plugin.") == true
        if !contributed, let unknown = params.keys.sorted().first(where: { $0.hasPrefix("expected") && !Self.apiGuardKeys.contains($0) }) {
            throw RPCFailure(code: -32602, message: "Unknown safety guard: \(unknown)")
        }
        func string(_ key: String) throws -> String? {
            guard let value = params[key] else { return nil }
            guard let text = value.string, !text.isEmpty else { throw RPCFailure(code: -32602, message: "\(key) must be a nonempty string") }
            return text
        }
        let persistenceMethod = method == "command.run" && params["id"] == .string("plugins.panelState.reset") ? "plugins.panelState.reset" : method
        let data = persistenceMethod.hasPrefix("plugins.data.")
        let panel = persistenceMethod.hasPrefix("plugins.panelState.")
        if data || panel {
            var supported: Set<String> = ["expectedInstanceId"]
            if panel { supported.insert("expectedWorkspaceRevision") }
            if persistenceMethod != "plugins.data.get" && data { supported.insert("expectedDataRevision") }
            if persistenceMethod != "plugins.panelState.get" && panel { supported.formUnion(["expectedPanelId", "expectedStateRevision"]) }
            if let unsupported = Set(params.keys).intersection(Self.apiGuardKeys).subtracting(supported).sorted().first {
                throw RPCFailure(code: -32602, message: "\(unsupported) is not supported by \(persistenceMethod)")
            }
        }
        for key in ["expectedDataRevision", "expectedPanelId", "expectedStateRevision"] {
            if try string(key) != nil {
                let allowed = key == "expectedDataRevision"
                    ? ["plugins.data.patch", "plugins.data.reset"]
                    : ["plugins.panelState.patch", "plugins.panelState.reset"]
                guard allowed.contains(persistenceMethod) else { throw RPCFailure(code: -32602, message: "\(key) is not supported by this operation") }
            }
        }
        if method.hasPrefix("layouts.") {
            var supported: Set<String> = ["expectedInstanceId"]
            if ["layouts.windows", "layouts.capture", "layouts.open"].contains(method) { supported.insert("expectedWorkspaceRevision") }
            if method == "layouts.update" { supported.insert("expectedSavedLayoutRevision") }
            if let unsupported = Set(params.keys).intersection(Self.apiGuardKeys).subtracting(supported).sorted().first {
                throw RPCFailure(code: -32602, message: "\(unsupported) is not supported by \(method)")
            }
        }
        if let _ = try string("expectedSavedLayoutRevision") {
            guard method == "layouts.update" else { throw RPCFailure(code: -32602, message: "expectedSavedLayoutRevision is only supported by layouts.update") }
            // This document guard is checked by SavedLayoutStore at atomic publication, not against TOML.
        }
        if params["expectedViewId"] != nil || params["expectedDocumentId"] != nil {
            guard Self.webMethods.contains(method) || method == "pane.title" else {
                throw RPCFailure(code: -32602, message: "Automation identity guards are supported by web methods and pane.title")
            }
            _ = try WebIdentity.expected(in: params)
            // The shared helper checks fresh native/DOM identity before submission;
            // parsing here must not substitute a cached document for that check.
        }
        if method == "command.run", let id = params["id"]?.string,
           NativeWindowAction.commands.contains(id) || id.hasPrefix("warnings.") {
            let supported: Set<String> = id.hasPrefix("window.") ? ["expectedInstanceId", "expectedWorkspaceRevision"] : ["expectedInstanceId"]
            if let unsupported = Set(params.keys).intersection(Self.apiGuardKeys).subtracting(supported).sorted().first {
                throw RPCFailure(code: -32602, message: "\(unsupported) is not supported by \(id)")
            }
        }
        if method == "presence.focus" {
            let supported: Set<String> = ["expectedInstanceId", "expectedWorkspaceRevision"]
            if let unsupported = Set(params.keys).intersection(Self.apiGuardKeys).subtracting(supported).sorted().first {
                throw RPCFailure(code: -32602, message: "\(unsupported) is not supported by presence.focus")
            }
        }
        if let expected = try string("expectedInstanceId"), expected != instanceID {
            throw RPCFailure(code: APIError.conflict, message: "App instance changed; rediscover context")
        }
        for pane in movePanes where !workspace.panes.contains(where: { $0.id == pane }) {
            throw RPCFailure(code: APIError.unavailable, message: "Pane \(pane) no longer exists")
        }
        if let expected = try string("expectedAnchorSessionId") {
            guard let pane = try string("pane"), shellSessions[try PaneID(parsing: pane)]?.instanceID == expected else {
                throw RPCFailure(code: APIError.conflict, message: "Launching terminal was replaced; supply an intentional new target")
            }
        }
        if let pane = try string("pane"), let tab = try string("tab") {
            guard workspace.tabs.first(where: { $0.id.description == tab })?.layout.paneIDs.contains(try PaneID(parsing: pane)) == true else {
                throw RPCFailure(code: -32602, message: "Pane does not belong to the requested tab")
            }
        }
        if let expected = try string("expectedSourceRevision") {
            let id = params["id"]?.string ?? ""
            let configurationCommand = id == "config.reload" || id.hasPrefix("appearance.") || id.hasPrefix("terminal.font.") || id == "terminal.palette.set"
                || id.hasPrefix("agents.activity.")
            guard ["config.patch", "config.reload"].contains(method) || (method == "command.run" && configurationCommand) else {
                throw RPCFailure(code: -32602, message: "expectedSourceRevision is not supported by this operation")
            }
            guard try configurationRevision().revision == expected else { throw RPCFailure(code: APIError.conflict, message: "Configuration source changed; inspect again") }
        }
        if let expected = try string("expectedWriteRevision") {
            guard method == "plugins.settings.patch" else { throw RPCFailure(code: -32602, message: "expectedWriteRevision is only supported by plugins.settings.patch") }
            guard try configurationRevision().revision == expected else { throw RPCFailure(code: APIError.conflict, message: "Settings source changed; read the namespace again") }
        }
        if let expected = try string("expectedWorkspaceRevision") { try revisions.requireWorkspace(expected) }
        if let expected = try string("expectedLayoutRevision") {
            let tab = try params["pane"].map { _ in
                let pane = try targetPaneID(params)
                return workspace.tabs.first { $0.layout.paneIDs.contains(pane) }!.id
            } ?? targetTab(params).id
            try revisions.requireLayout(expected, tab: tab)
        }
    }

    func apiMethods() -> [String] { AutomationMethod.publicMethods.map(\.rawValue) }

    func describeAPI() throws -> JSONValue {
        return .object([
            "apiVersion": .integer(1), "appInstanceId": .string(instanceID), "identityGuards": .bool(true),
            "workspaceRevisions": .bool(true), "surface": .string("trusted"),
            "pluginPersistence": Self.pluginPersistenceDescriptor,
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
            "windowControls": .object([
                "version": .integer(1), "commands": .array(NativeWindowAction.commands.sorted().map(JSONValue.string)),
                "target": .string("selectedNativeWindowId"), "framePolicy": .string("containedInOneVisibleScreen"),
                "fullscreenCompletion": .string("asynchronousPollWindowGet"), "implicitActivation": .bool(false)
            ]),
            "warningSuppression": .object([
                "commands": .array(["warnings.close.set", "warnings.type.set"].map(JSONValue.string)),
                "parameter": .string("suppressed"), "type": .string("boolean"), "changesDestructiveConsent": .bool(false)
            ]),
            "browserData": .object([
                "version": .integer(1), "persistentProfile": .string("appWide"), "privateProfile": .string("perPaneEphemeral"),
                "clearAllMethod": .string("browser.clearData"), "clearSiteMethod": .string("browser.clearSiteData"),
                "siteRequired": .array([.string("pane"), .string("url")]), "siteGranularity": .string("webkitDomainGroupIncludingSubdomains"),
                "apiConfirmation": .bool(false), "nativeConfirmation": .bool(true),
                "resultFields": .array(["cleared", "scope", "storage", "host"].map(JSONValue.string))
            ]),
            "browserNavigation": .object([
                "schemes": .array(["http", "https", "about", "file"].map(JSONValue.string)),
                "aboutBlankOnly": .bool(true), "localFiles": .bool(true), "absolutePaths": .bool(true),
                "fileReadAccess": .string("containingDirectory"), "pluginBridge": .bool(false)
            ]),
            "causation": OperationControl.descriptor,
            "presence": PresenceController.descriptor,
            "backgroundServices": Self.serviceDescriptor,
            "pluginManagement": .object([
                "version": .integer(2), "enableMethod": .string("plugins.enable"), "disableMethod": .string("plugins.disable"),
                "installMethod": .string("plugins.register"), "validateMethod": .string("plugins.validate"),
                "installRequired": .array([.string("packagePath")]), "installOptional": .array([.string("replace")]),
                "format": .string("zip"), "manifest": .string("plugin.json"), "managedFiles": .bool(true),
                "registry": .string("plugins/registry.json"), "packageRootEnvironment": .string("SLATE_TERM_PLUGIN_ROOT"),
                "limits": .object(["archiveBytes": .integer(134_217_728), "extractedBytes": .integer(536_870_912),
                    "fileBytes": .integer(67_108_864), "entries": .integer(10_000), "manifestBytes": .integer(262_144)]),
                "errors": .object(["invalid": .integer(-32602), "conflict": .integer(APIError.conflict),
                    "inUse": .integer(-32010), "writeFailed": .integer(APIError.settingsWriteFailed)]),
                "removeMethod": .string("plugins.unregister"), "required": .array([.string("id")]),
                "forceClosesPanes": .bool(true), "persisted": .bool(true), "retainsSavedData": .bool(true),
                "listEnabledField": .string("enabled"), "enableStartsProcesses": .bool(false)
            ]),
            "appearance": Self.appearanceDescriptor,
            "notifications": Self.notificationDescriptor,
            "welcome": Self.welcomeDescriptor,
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
                "writeGuard": .string("expectedSavedLayoutRevision"), "configurationTarget": .string("pane"),
                "startupLifetime": .string("committedTerminalSession"), "mergeSupported": .bool(false)
            ]),
            "guards": .array(Self.apiGuardKeys.sorted().map(JSONValue.string)),
            "methods": .array(apiMethods().map(JSONValue.string)),
            "commands": try .encoding(availableCommands),
            "limits": .object(["inspectionPageSize": .integer(64), "inspectionBytes": .integer(262144), "eventWaitMilliseconds": .integer(25000)]),
            "retryPolicy": .string("Mutations are not automatically retried; correlation IDs are not idempotency keys")
        ])
    }

    func workspaceSnapshot(_ params: [String: JSONValue]) throws -> JSONValue {
        try synchronizeNativeGroups()
        try validateAPIGuards(params, method: "workspace.snapshot")
        let scope = params["scope"]?.string ?? "global"
        guard ["global", "tab", "pane"].contains(scope) else { throw RPCFailure(code: -32602, message: "scope must be global, tab or pane") }
        let selected: [Pane]
        let scopeKey: String
        if scope == "global" { selected = workspace.panes; scopeKey = "global" }
        else {
            let pane = try targetPaneID(params)
            let tab = workspace.tabs.first { $0.layout.paneIDs.contains(pane) }!
            scopeKey = scope == "pane" ? "pane:\(pane)" : "tab:\(tab.id)"
            selected = workspace.panes.filter { scope == "pane" ? $0.id == pane : tab.layout.paneIDs.contains($0.id) }
        }
        let limit: Int
        if let value = params["limit"] {
            guard case .integer(let number) = value, (1...64).contains(number) else { throw RPCFailure(code: -32602, message: "limit must be 1...64") }
            limit = number
        } else { limit = 32 }
        let cursor: InspectionCursor?
        if let value = params["cursor"] {
            guard let text = value.string else { throw RPCFailure(code: -32602, message: "cursor must be a string") }
            cursor = try InspectionCursor.decode(text, revision: revisions.revision, scope: scopeKey)
        } else { cursor = nil }
        let offset = cursor?.offset ?? 0
        guard offset <= selected.count else { throw RPCFailure(code: APIError.conflict, message: "Cursor exceeds this snapshot") }
        let end = min(selected.count, offset + limit)
        let page = Array(selected[offset..<end])
        let ids = Set(page.map(\.id))
        let tabs = workspace.tabs.filter { !$0.layout.paneIDs.filter(ids.contains).isEmpty }
        let eventCursor = cursor?.eventCursor ?? events.head.object!["cursor"]!.string!
        let next = end == selected.count ? nil : try InspectionCursor(revision: revisions.revision, scope: scopeKey, offset: end, eventCursor: eventCursor).encoded()
        let value: JSONValue = .object([
            "appInstanceId": .string(instanceID), "workspaceRevision": .string(revisions.revision),
            "eventCursor": .string(eventCursor), "nextCursor": next.map(JSONValue.string) ?? .null,
            "sampledAt": .number(Date().timeIntervalSince1970), "scope": .string(scopeKey), "totalPanes": .integer(selected.count),
            "groups": try .encoding(workspace.groups.filter { $0.tabs.contains { id in tabs.contains { $0.id == id } } }),
            "tabs": .array(try tabs.map { tab in .object([
                "id": .string(tab.id.description), "focusedPaneId": .string(tab.focusedPane.description),
                "manualTitle": tab.manualTitle.map(JSONValue.string) ?? .null, "title": .string(tab.title),
                "unreadNotificationCount": .integer(notificationStore.records.filter { $0.anchor.paneId.map(tab.layout.paneIDs.contains) ?? ($0.anchor.tabId == tab.id) }.count),
                "layoutRevision": .string(revisions.layoutRevision(tab.id)!), "layout": try .encoding(tab.layout)
            ]) }),
            "panes": .array(try page.map { try inspectPane($0.id) })
        ])
        guard try JSONEncoder().encode(value).count <= 262144 else {
            throw RPCFailure(code: APIError.unavailable, message: "Snapshot exceeds 256 KiB; narrow scope or use pane.inspect")
        }
        return value
    }

    func inspectContext(_ params: [String: JSONValue], caller: PaneID? = nil, view: PluginPane? = nil) throws -> JSONValue {
        try synchronizeNativeGroups()
        try validateAPIGuards(params, method: "context.inspect")
        let target: PaneID? = params["pane"] != nil || params["tab"] != nil || workspace.keyTabID != nil ? try targetPaneID(params) : nil
        let anchor = caller ?? (params["pane"] != nil ? target : nil)
        var identity: [String: JSONValue] = ["appInstanceId": .string(instanceID), "identitySource": .string(view == nil ? (anchor == nil ? "none" : "supplied") : "bridgeBound")]
        if let anchor {
            identity["paneId"] = .string(anchor.description)
            identity["sessionId"] = shellSessions[anchor].map { .string($0.instanceID) } ?? .null
            if let tab = workspace.tabs.first(where: { $0.layout.paneIDs.contains(anchor) }) {
                identity["tabId"] = .string(tab.id.description)
                identity["groupId"] = workspace.groups.first { $0.tabs.contains(tab.id) }.map { .string($0.id.description) }
            }
        }
        if let view {
            identity["pluginId"] = .string(view.instance.registration.id)
            identity["pluginInstanceId"] = .string(view.instance.id)
            identity["viewId"] = .string(view.viewID)
        }
        let tab = target.flatMap { pane in workspace.tabs.first { $0.layout.paneIDs.contains(pane) } }
        return .object(["caller": .object(identity), "target": try target.map(inspectPane) ?? .null,
                        "focusedPaneId": tab.map { .string($0.focusedPane.description) } ?? .null,
                        "activeTerminalPaneId": tab?.activeTerminal.map { .string($0.description) } ?? .null,
                        "workspaceRevision": .string(revisions.revision)])
    }

    func inspectPane(_ id: PaneID) throws -> JSONValue {
        guard let pane = workspace.panes.first(where: { $0.id == id }), let tab = workspace.tabs.first(where: { $0.layout.paneIDs.contains(id) }) else {
            throw WorkspaceError.paneNotFound(id)
        }
        let type: String
        type = pane.type.identifier
        let container = containers[id]
        var geometry: JSONValue = .null
        var geometryState = "unavailable"
        let nativeWindow = container?.view.window
        let selected = nativeWindow?.tabGroup.map { $0.selectedWindow === nativeWindow } ?? true
        let visible = nativeWindow?.isVisible == true && nativeWindow?.isMiniaturized == false
            && selected && container?.view.isHiddenOrHasHiddenAncestor == false
            && (tab.zoomedPane == nil || tab.zoomedPane == id)
        if visible, !nativeGeometryUnavailable(tab.id), rendered[tab.id] == tab.layout, renderedZoom[tab.id] == tab.zoomedPane,
           let root = windows[tab.id]?.contentView, let view = container?.view, !root.needsLayout, !view.needsLayout {
            let rect = view.convert(view.bounds, to: root)
            geometry = .object(["x": .number(rect.minX), "y": .number(root.isFlipped ? rect.minY : root.bounds.height - rect.maxY),
                                "width": .number(rect.width), "height": .number(rect.height), "coordinateSpace": .string("tab-content-top-left-points"),
                                "layoutRevision": .string(revisions.layoutRevision(tab.id)!)])
            geometryState = "sampled"
        }
        var result: [String: JSONValue] = [
            "paneId": .string(id.description), "type": .string(type), "tabId": .string(tab.id.description),
            "groupId": workspace.groups.first { $0.tabs.contains(tab.id) }.map { .string($0.id.description) } ?? .null,
            "headerVisible": .bool(pane.headerVisible),
            "unreadNotificationCount": .integer(notificationStore.records.filter { $0.anchor.paneId == id }.count),
            "manualTitle": pane.manualTitle.map { .string(String($0.prefix(512))) } ?? .null,
            "manualTitleTruncated": .bool((pane.manualTitle?.count ?? 0) > 512),
            "windowId": windows[tab.id].map { .string($0.identity) } ?? .null,
            "path": tab.layout.path(to: id).map { .array($0.map { .string($0.rawValue) }) } ?? .null,
            "title": .string(String((container?.effectiveTitle ?? type).prefix(512))),
            "visible": .bool(visible), "geometry": geometry, "geometryState": .string(geometryState),
            "layoutRevision": .string(revisions.layoutRevision(tab.id)!), "sampledAt": .number(Date().timeIntervalSince1970),
            "neighbors": .object(Dictionary(uniqueKeysWithValues: Direction.allCases.map { direction in
                (direction.rawValue, tab.layout.neighbor(of: id, direction: direction).map { .string($0.description) } ?? .null)
            }))
        ]
        if let record = pane.pluginPanel {
            result["pluginPanelId"] = .string(record.panelId)
            result["pluginStateRevision"] = .string(record.stateRevision)
        }
        if let session = shellSessions[id] {
            result["sessionId"] = .string(session.instanceID)
            result["state"] = .string(session.report?.state.rawValue ?? "unknown")
            // Known only after the shell's first authenticated report.
            result["shell"] = session.report.map { .string($0.shellKind.rawValue) } ?? .null
            result["runAvailable"] = session.report.map { .bool($0.acceptsRunInput) } ?? .null
            result["contentOperations"] = .array(["terminal.capture", "terminal.send", "terminal.key", "terminal.run", "terminal.wait"].map(JSONValue.string))
        } else if let plugin = leaves[id] as? PluginPane {
            result["pluginInstanceId"] = .string(plugin.instance.id)
            result["viewId"] = .string(plugin.viewID)
            result["state"] = .string(plugin.instance.state)
            result["contentOperations"] = .array(Self.webMethods.map(JSONValue.string))
        } else {
            result["contentOperations"] = .array(Self.webMethods.map(JSONValue.string))
        }
        if let automation = webAutomation(for: id) {
            result["viewId"] = .string(automation.viewID)
            result["documentId"] = automation.info["documentId"]
            result["webReady"] = automation.info["ready"]
        }
        return .object(result)
    }
}
