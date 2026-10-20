import Foundation

extension AutomationContracts {
    public static let applicationCommandDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        var welcome = notificationDefinitions["Welcome"]!.object!
        let fields: [String: JSONValue] = ["changed": S.boolean, "persisted": S.constant(.bool(true)), "operationId": S.uuid]
        welcome["properties"] = .object(welcome["properties"]!.object!.merging(fields) { _, value in value })
        if case .array(let required) = welcome["required"] { welcome["required"] = .array(required + fields.keys.sorted().map(JSONValue.string)) }
        let opened = workspaceCommitFields.merging(["opened": S.constant(.bool(true)), "notificationId": S.string()]) { _, value in value }
        var window = workspaceDefinitions["NativeWindow"]!.object!
        let presentation: [String: JSONValue] = ["accepted": S.constant(.bool(true)), "changed": S.boolean, "settled": S.boolean]
        window["properties"] = .object(window["properties"]!.object!.merging(presentation) { _, v in v })
        if case .array(let required) = window["required"] { window["required"] = .array(required + presentation.keys.sorted().map(JSONValue.string)) }
        return ["WelcomeWrite": .object(welcome), "NotificationOpen": S.object(opened, required: Array(opened.keys)),
            "WindowPresentationWrite": .object(window)]
    }()

    public static let applicationCommands: [String: AutomationContract] = {
        typealias S = APISchema
        func requires(_ value: String) -> JSONValue { .object(["requires": .string(value)]) }
        func legacy(_ id: String, parameters: [String: JSONValue] = [:], required: [String] = [], result: JSONValue = S.emptyObject,
                    extraGuards: [String] = [], conditions: [JSONValue] = [], routing: String = "paneOrTabFocus", errors: [Int] = [], semantics: [String: JSONValue] = [:]) -> AutomationContract {
            commandContract(id, parameters: paneTarget.merging(parameters) { _, value in value }, required: required,
                result: result, guards: targetGuards + extraGuards, additional: true, conditions: conditions,
                routing: routing, errors: errors, constraints: targetConstraints, semantics: semantics)
        }
        // These commands dispatch directly to the same method handlers. Rebind only
        // the command identifier; preserve all parameter constraints and semantics.
        func methodCommand(_ id: String, contract: AutomationContract) -> AutomationContract {
            let input = contract.input.object!
            let parameters = input["properties"]!.object!.filter { !contract.guards.contains($0.key) }
            let required: [String]
            if case .array(let values) = input["required"] { required = values.compactMap(\.string) } else { required = [] }
            let constraints: [JSONValue]
            if case .array(let values) = input["allOf"] { constraints = values } else { constraints = [] }
            let conditions: [JSONValue]
            if case .array(let values) = contract.availability { conditions = values } else { conditions = [] }
            return commandContract(id, parameters: parameters, required: required, result: contract.result, guards: contract.guards,
                additional: input["additionalProperties"] == .bool(true), conditions: conditions, routing: contract.routing,
                errors: contract.errors, constraints: constraints, semantics: contract.semantics)
        }
        var commands: [String: AutomationContract] = [:]
        for (id, method) in [("browser.clearData", AutomationMethod.browserClearData), ("browser.clearSiteData", .browserClearSiteData)] {
            commands[id] = methodCommand(id, contract: web[method]!)
        }
        for (id, method) in [("updates.check", AutomationMethod.updatesCheck), ("updates.show", .updatesShow), ("updates.openParent", .updatesOpenParent)] {
            commands[id] = methodCommand(id, contract: updates[method]!)
        }
        commands["layouts.restoreOriginal"] = methodCommand("layouts.restoreOriginal", contract: savedLayouts[.layoutsRestoreOriginal]!)
        commands["config.reload"] = methodCommand("config.reload", contract: settings[.configReload]!)
        commands["plugins.panelState.reset"] = methodCommand("plugins.panelState.reset", contract: pluginPersistence[.panelStateReset]!)
        for id in NativeWindowAction.commands {
            var parameters = ["windowId": S.string(minimumLength: 1, maximumUTF8Bytes: 128)]
            var required = ["windowId"]
            if id == "window.frame.set" {
                for axis in ["x", "y", "width", "height"] {
                    parameters[axis] = S.annotated(S.number, axis == "x" || axis == "y"
                        ? ["minimum": .integer(-1_000_000), "maximum": .integer(1_000_000)]
                        : ["exclusiveMinimum": .integer(0), "maximum": .integer(1_000_000)])
                    required.append(axis)
                }
            }
            if id == "window.fullscreen.set" { parameters["fullscreen"] = S.boolean; required.append("fullscreen") }
            commands[id] = commandContract(id, parameters: parameters, required: required, result: S.reference("WindowPresentationWrite"),
                guards: ["expectedInstanceId", "expectedWorkspaceRevision"],
                conditions: [requires("selectedLiveNativeWindowWithoutSheetResizeOrFullscreenTransition"),
                    requires("frameMeetsNativeSizeLimitsAndFitsOneVisibleScreenWhenSettingFrame"),
                    requires("windowedForFrameAndMinimizationAndRestoredForFrameAndFullscreen")],
                routing: "explicitNativeWindowID", errors: [APIError.unavailable], semantics: [
                    "coordinates": .string("screenGlobalBottomLeftPoints"), "activatesApplication": .bool(false),
                    "acceptedMeansSettled": .bool(false), "completion": .string("pollWindowGetAfterFullscreenRequest"),
                    "failureMayFollowNativeEffect": .bool(true), "workspaceTopologyChanged": .bool(false)])
        }
        let writing = ["appearance.set", "appearance.light", "appearance.dark", "appearance.auto", "terminal.palette.set",
            "terminal.font.set", "terminal.font.increase", "terminal.font.decrease", "terminal.font.reset",
            "agents.activity.show", "agents.activity.hide", "agents.activity.toggle"]
        for id in writing {
            var parameters: [String: JSONValue] = [:]
            var required: [String] = []
            var conditions = [requires("validReadableConfigurationOrAbsentFileAndValidMergedSettings")]
            var semantics: [String: JSONValue] = ["scope": .string("applicationNotPane"), "preservesUnrelatedSource": .bool(true),
                "failureMayHavePersisted": .bool(true), "recovery": .string("readConfigBeforeAnyRetry")]
            if id == "appearance.set" { parameters["mode"] = S.strings(["light", "dark", "auto"]); required = ["mode"] }
            if id == "terminal.palette.set" {
                parameters = ["slot": S.strings(["light", "dark"]), "name": paletteName]; required = ["slot", "name"]
                conditions.append(requires("paletteExistsAndIsValid"))
            }
            if id == "terminal.font.set" { parameters["size"] = terminalConfigurationFields["font_size"]!; required = ["size"] }
            if id == "terminal.font.increase" || id == "terminal.font.decrease" {
                semantics["deltaPoints"] = .integer(id == "terminal.font.increase" ? 1 : -1)
                semantics["clampPoints"] = .array([.integer(1), .integer(256)])
            }
            if id == "terminal.font.reset" { semantics["resetTo"] = .string("applicationDefaultFontSize") }
            commands[id] = legacy(id, parameters: parameters, required: required, result: S.reference("ConfigurationWrite"),
                extraGuards: ["expectedSourceRevision"], conditions: conditions, routing: "applicationConfiguration", errors: [APIError.settingsWriteFailed], semantics: semantics)
        }
        for id in ["warnings.close.reset", "warnings.type.reset", "warnings.close.set", "warnings.type.set"] {
            let setter = id.hasSuffix(".set")
            commands[id] = commandContract(id, parameters: setter ? ["suppressed": S.boolean] : [:], required: setter ? ["suppressed"] : [],
                result: S.object(["suppressed": setter ? S.boolean : S.constant(.bool(false))], required: ["suppressed"]),
                guards: ["expectedInstanceId"], routing: "applicationWarningPreference", errors: [-32000],
                semantics: ["scope": .string("application"), "changesDestructiveConsent": .bool(false), "resetSuppression": .bool(false)])
        }
        for id in ["welcome.read", "welcome.unread", "welcome.reset"] {
            commands[id] = commandContract(id, result: S.reference("WelcomeWrite"), guards: ["expectedInstanceId"], routing: "applicationStateDirectory",
                errors: [APIError.settingsWriteFailed, APIError.unavailable], semantics: ["acknowledged": .bool(id == "welcome.read"),
                    "unreadAffects": .string("futureTerminalSessions"), "readDismissesCurrentInlineMessages": .bool(true),
                    "savedPreferenceIsRollbackableWorkspaceMutation": .bool(false), "recovery": .string("readWelcomeBeforeAnyRetry")])
        }
        for id in ["settings.open", "notifications.settings", "skills.settings", "command.picker"] {
            commands[id] = legacy(id, routing: id == "command.picker" ? "optionalPaneOrTabContextForNativePicker" : "applicationSettings", semantics: ["nativeUI": .bool(true), "resultMeans": .string("presentationRequestedNotUserActionCompleted"),
                "dialogInputParameters": .bool(false)])
        }
        commands["skills.reveal"] = legacy("skills.reveal", result: S.object(["path": S.string()], required: ["path"]),
            routing: "managedSkillCopy", errors: [APIError.unavailable], semantics: ["createsManagedCopyIfMissing": .bool(true), "opensFinder": .bool(true)])
        for id in ["layouts.edit", "layouts.openWindow", "layouts.captureWindow", "layouts.launcher", "layouts.folder"] {
            var conditions: [JSONValue] = []
            if id == "layouts.launcher" { conditions += [requires("defaultLayoutLibrary"), requires("standardSlateRuntime")] }
            if id == "layouts.captureWindow" { conditions.append(requires("atLeastOneWorkspaceWindow")) }
            var semantics: [String: JSONValue] = ["nativeUI": .bool(true)]
            if ["layouts.openWindow", "layouts.captureWindow", "layouts.launcher"].contains(id) {
                semantics["useStructuredLayoutsMethodsForNoninteractiveCalls"] = .bool(true)
                semantics["dialogCancellation"] = .string("emptyObjectSuccess")
                semantics["nativeSelection"] = .string(id == "layouts.captureWindow" ? "sourceWorkspaceWindowAndName" : "savedLibraryEntryNotArgumentID")
            }
            commands[id] = legacy(id, conditions: conditions, routing: "savedLayoutLibraryAndNativeUI",
                errors: [-32000, APIError.unavailable] + (id == "layouts.launcher" ? [APIError.layoutAppManagementUnavailable] : []), semantics: semantics)
        }
        for id in ["notifications.next", "notifications.open"] {
            let explicit = id == "notifications.open"
            let result = explicit ? S.reference("NotificationOpen") : S.oneOf([
                S.object(["opened": S.constant(.bool(false))], required: ["opened"]), S.reference("NotificationOpen")])
            commands[id] = commandContract(id, parameters: explicit ? ["notificationId": S.string()] : [:],
                required: explicit ? ["notificationId"] : [], result: result, guards: unanchoredGuards,
                conditions: explicit ? [requires("outstandingNotificationWithLiveSource")] : [], routing: "notificationSource",
                errors: [APIError.unavailable], semantics: ["revealsZoomHiddenSource": .bool(true), "deminimizesAndActivates": .bool(true),
                    "dismissesOpenedRecord": .bool(true), "nextSelection": .string("firstOutstandingRecord")])
        }
        for id in ["plugins.reload", "terminal.find", "terminal.find.next", "terminal.find.previous", "terminal.find.end",
                   "pane.move.chooseDestination", "tab.rename", "tab.showAll"] {
            var fields: [String: JSONValue] = ["paneId": S.paneID]
            var conditions: [JSONValue]
            var semantics: [String: JSONValue] = [:]
            switch id {
            case "plugins.reload":
                fields["reloading"] = S.constant(.bool(true)); conditions = [requires("registeredPluginPane")]
                semantics["resultMeans"] = .string("reloadRequestedNotReadiness")
            case "tab.showAll":
                fields = ["tabId": S.tabID, "overviewVisible": S.constant(.bool(true))]
                conditions = [requires("visibleNativeWindowWithMultipleTabsAndNoSheet")]
                semantics["nativeUI"] = .bool(true)
                semantics["idempotent"] = .bool(true)
                semantics["scope"] = .string("targetTabNativeWindowGroup")
            case "tab.rename":
                fields = ["tabId": S.tabID, "editing": S.constant(.bool(true))]
                conditions = [requires("nativeTabCanPresentRenameEditor")]
                semantics["resultMeans"] = .string("editorOpenedNotTitleChanged")
            case "pane.move.chooseDestination":
                conditions = [requires("visibleNonMinimizedUnzoomedPaneBarAndAnotherPane")]
                semantics["resultMeans"] = .string("chooserPresentedNotPaneMoved")
            default:
                conditions = [requires(id == "terminal.find" ? "visibleTerminalInNonMinimizedWindow" : "terminalPane")]
                semantics["noSubmittedQueryForNextOrPrevious"] = .string("unchangedSuccess")
            }
            commands[id] = commandContract(id, parameters: paneTarget, result: S.object(fields, required: Array(fields.keys)),
                conditions: conditions, errors: [APIError.unavailable], constraints: targetConstraints, semantics: semantics)
        }
        commands["pane.rename"] = legacy("pane.rename", result: S.object(["paneId": S.paneID], required: ["paneId"]),
            conditions: [requires("visiblePaneBarInNonMinimizedWindow")], semantics: ["resultMeans": .string("editorOpenedNotTitleChanged")])
        commands["pane.copyID"] = legacy("pane.copyID", result: S.object(["paneId": S.paneID], required: ["paneId"]), errors: [-32000],
            semantics: ["replacesClipboardText": .bool(true)])
        for id in ["browser.back", "browser.forward", "browser.focusAddress", "browser.reload", "browser.showDownloads"] {
            commands[id] = legacy(id, conditions: [requires("browserPane")], semantics: [
                "resultMeans": .string("nativeActionRequestedNotNavigationCompletion"), "mayChangeNativeFocus": .bool(true)])
        }
        return commands
    }()
}
