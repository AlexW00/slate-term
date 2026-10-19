import Foundation

extension AutomationContracts {
    /// Inputs are complete command.run parameter objects, after caller defaults.
    static func commandContract(_ id: String, parameters: [String: JSONValue] = [:], required: [String] = [],
                                result: JSONValue, guards: [String] = targetGuards, additional: Bool = false,
                                conditions: [JSONValue] = [], routing: String = "paneOrTabFocus", errors: [Int] = [],
                                constraints: [JSONValue] = [], semantics: [String: JSONValue] = [:]) -> AutomationContract {
        AutomationContract(parameters: parameters.merging(["id": APISchema.constant(.string(id))]) { _, value in value },
            required: required + ["id"], result: result, guards: guards, additionalParameters: additional,
            conditions: conditions, routing: routing, errors: errors, constraints: constraints,
            semantics: semantics.merging(["workspaceIndependentCallerDefaults": .bool(CommandContract.forCommand(id).workspaceIndependent)]) { _, value in value })
    }

    public static let commandDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        func committed(_ fields: [String: JSONValue]) -> JSONValue {
            let all = workspaceCommitFields.merging(fields) { _, value in value }
            return S.object(all, required: Array(all.keys))
        }
        let tab: [String: JSONValue] = ["tabId": S.tabID, "layoutRevision": S.revision]
        let pane = tab.merging(["paneId": S.paneID, "path": S.nullable(S.array(S.strings(["first", "second"])))]) { _, value in value }
        var definitions: [String: JSONValue] = [
            "WorkspaceCommit": committed([:]), "LegacySplitCommit": committed(["paneId": S.paneID]),
            "NewTabCommit": committed(["tabId": S.tabID]), "TabLayoutCommit": committed(tab), "PaneLayoutCommit": committed(pane),
            "PaneHeaderCommit": committed(pane.merging(["headerVisible": S.boolean]) { _, value in value }),
            "PaneMoveCommit": committed(pane.merging(["sourceTabId": S.tabID, "sourceTabClosed": S.boolean,
                "sourceLayoutRevision": S.nullable(S.revision), "contentRecreated": S.boolean]) { _, value in value }),
            "TabGroupCommit": committed(tab.merging(["groupId": S.groupID]) { _, value in value }),
            "TabTitleCommit": committed(tab.merging(["manualTitle": S.nullable(S.string()), "title": S.string()]) { _, value in value })
        ]
        var window = workspaceDefinitions["NativeWindow"]!.object!
        window["properties"] = .object(window["properties"]!.object!.merging(workspaceCommitFields) { _, value in value })
        if case .array(let required) = window["required"] { window["required"] = .array(required + workspaceCommitFields.keys.sorted().map(JSONValue.string)) }
        definitions["WindowFocusCommit"] = .object(window)
        return definitions
    }()

    public static let workspaceCommands: [String: AutomationContract] = {
        typealias S = APISchema
        func requires(_ value: String) -> JSONValue { .object(["requires": .string(value)]) }
        let commitSemantics: [String: JSONValue] = ["noOpAdvancesRevisions": .bool(false), "diskPersistenceFailureUndoesWorkspace": .bool(false),
            "externalResourcePreparationIsRollbackable": .bool(false), "forceOnlyWhenBooleanTrue": .bool(true)]
        let directions = S.strings(["left", "right", "up", "down"])
        let fraction = S.annotated(S.number, ["exclusiveMinimum": .integer(0), "exclusiveMaximum": .integer(1)])
        var commands: [String: AutomationContract] = [:]
        let legacy = ["split.left", "split.right", "split.up", "split.down", "focus.left", "focus.right", "focus.up", "focus.down",
            "pane.zoom", "layout.equalize", "pane.type", "pane.close", "pane.focus", "tab.new", "window.new", "tab.close",
            "tab.next", "tab.previous", "tab.select1", "tab.select2", "tab.select3", "tab.select4", "tab.select5", "tab.select6",
            "tab.select7", "tab.select8", "tab.select9", "tab.focus"]
        for id in legacy {
            var parameters = paneTarget
            parameters["force"] = S.defaulted(S.any, .bool(false))
            var required: [String] = []
            var conditions = [requires("liveTargetPaneOrTabUnlessCreatingFirstWindow")]
            var semantics = commitSemantics
            var result = "WorkspaceCommit"
            if id.hasPrefix("split.") {
                result = "LegacySplitCommit"
                conditions.append(requires("resultingTreeDepthAtMost64AndNativeMinimum80PointGeometry"))
                semantics["splittingClearsZoom"] = .bool(true)
                semantics["terminalWorkingDirectory"] = .string("inheritTargetWhenEnabledOtherwiseConfiguredDefault")
                semantics["newPaneType"] = .string("terminal"); semantics["newPaneFraction"] = .number(0.5)
            }
            if id == "tab.new" || id == "window.new" { result = "NewTabCommit" }
            if id == "window.new" { conditions = []; semantics["mode"] = .string("newWindowGroup") }
            if id == "tab.new" { semantics["mode"] = .string("targetGroupOrNewWindowWhenNoWorkspace") }
            if id == "pane.type" {
                parameters["type"] = S.string(minimumLength: 1); required = ["type"]
                conditions.append(requires("builtinOrActiveCompatiblePanelType"))
            }
            if ["pane.type", "pane.close", "tab.close"].contains(id) { conditions.append(requires("forceTrueIfRetiringTerminalNeedsCloseConfirmation")) }
            if id.hasPrefix("tab.select") { semantics["missingTabIndex"] = .string("unchangedSuccess") }
            // These legacy focus operations accept the usual fallback target even
            // though the older picker-oriented descriptor suggests explicit IDs.
            if id == "pane.focus" || id == "tab.focus" { semantics["explicitTargetRequired"] = .bool(false) }
            commands[id] = commandContract(id, parameters: parameters, required: required, result: S.reference(result),
                additional: true, conditions: conditions, routing: id == "window.new" ? "newWindowGroup" : "paneOrTabFocus", errors: [-32004, -32010, APIError.unavailable], constraints: targetConstraints, semantics: semantics)
        }
        for id in WorkspaceMutationCommand.ids.sorted() {
            var parameters = paneTarget
            parameters["force"] = S.defaulted(S.boolean, .bool(false))
            var required: [String] = []
            var result = "TabLayoutCommit"
            var conditions = [requires("liveTargetPaneOrTab")]
            var semantics = commitSemantics
            if WorkspaceMutationCommand.layoutGuarded.contains(id) {
                required.append("expectedLayoutRevision")
                conditions.append(requires("availableNativeGeometryAndAffectedPanesAtLeast80Points"))
                if id != "pane.split" { conditions.append(requires("unzoomedTargetTab")) }
            }
            if WorkspaceMutationCommand.workspaceGuarded.contains(id) { required.append("expectedWorkspaceRevision") }
            switch id {
            case "pane.split":
                parameters.merge(["direction": directions, "target": S.defaulted(S.strings(["pane", "root"]), .string("pane")),
                    "type": S.defaulted(S.string(minimumLength: 1), .string("terminal")), "newPaneFraction": S.defaulted(fraction, .number(0.5)),
                    "focus": S.defaulted(S.strings(["new", "preserve"]), .string("new"))]) { _, value in value }
                required.append("direction"); result = "PaneLayoutCommit"
                conditions += [requires("resultingTreeDepthAtMost64"), requires("builtinOrActiveCompatiblePanelType")]
                semantics["splittingClearsZoom"] = .bool(true)
                semantics["terminalWorkingDirectory"] = .string("inheritTargetWhenEnabledOtherwiseConfiguredDefault")
                semantics["fractionMeaning"] = .string("newPaneShareNotAlwaysFirstChildShare")
            case "pane.move":
                parameters.merge(["target": S.paneID, "direction": directions]) { _, value in value }
                required += ["target", "direction"]; result = "PaneMoveCommit"
                conditions += [requires("liveDestinationPaneAndUnzoomedSourceAndDestination"), requires("expectedWorkspaceRevisionForCrossTabMove"),
                    requires("resultingTreeDepthAtMost64AndBothNativeGeometriesAvailable")]
                semantics["samePaneDestination"] = .string("unchangedSuccessWhenGeometryAvailable")
                semantics["contentLifetime"] = .string("preservedExceptTabScopedPluginRebindingAcrossTabs")
                semantics["lastSourcePane"] = .string("retiresEmptySourceTabAndGroup")
            case "layout.resize":
                parameters.merge(["path": S.array(S.strings(["first", "second"]), maximum: 64), "firstChildFraction": fraction]) { _, value in value }
                required += ["path", "firstChildFraction"]
                conditions.append(requires("pathResolvesToSplit")); semantics["pathRoot"] = .string("emptyArray")
            case "pane.header.show", "pane.header.hide", "pane.header.toggle": result = "PaneHeaderCommit"
            case "pane.title.set", "pane.title.clear":
                result = "PaneLayoutCommit"
                if id == "pane.title.set" { parameters["title"] = S.string(format: "slate-manual-pane-title"); required.append("title") }
                semantics["emptyTrimmedTitle"] = .string("clearManualOverride")
                semantics["limitAfterTrimmingUTF8Bytes"] = .integer(4096)
            case "tab.title.set", "tab.title.clear":
                result = "TabTitleCommit"
                if id == "tab.title.set" { parameters["title"] = S.string(format: "slate-manual-tab-title"); required.append("title") }
                semantics["emptyTrimmedTitle"] = .string("clearManualOverride")
                semantics["limitsAfterTrimming"] = .object(["graphemes": .integer(100), "utf8Bytes": .integer(1024), "controlsAllowed": .bool(false)])
            case "tab.reorder", "tab.move", "tab.detach", "tab.detachCurrent":
                result = "TabGroupCommit"
                // detachCurrent has no declared focus argument in the authoritative
                // strict allowed-key set, despite its internal target-focus default.
                if id != "tab.detachCurrent" { parameters["focus"] = S.defaulted(S.strings(["target", "preserve"]), .string("preserve")) }
                if id == "tab.reorder" || id == "tab.move" {
                    // Int.max is rounded by JavaScript clients. Keep the host bound
                    // exact without putting an unsafe integer in shared discovery.
                    parameters["index"] = S.annotated(S.integer(minimum: 0), ["x-signed64BitInteger": .bool(true)])
                }
                if id == "tab.reorder" { required.append("index"); conditions.append(requires("indexWithinExistingGroupFinalOrder")) }
                if id == "tab.move" {
                    parameters["group"] = S.groupID; required.append("group")
                    conditions.append(requires("existingDestinationGroupAndValidInsertionIndex")); semantics["omittedIndex"] = .object(["crossGroup": .string("append"), "sameGroup": .string("preserveOrder")])
                }
                if id == "tab.detach" || id == "tab.detachCurrent" { semantics["alreadySingleTabGroup"] = .string("unchangedGroup") }
                if id == "tab.detachCurrent" { semantics["focus"] = .string("target") }
            default: preconditionFailure("Describe new model command: \(id)")
            }
            commands[id] = commandContract(id, parameters: parameters, required: required, result: S.reference(result), conditions: conditions,
                errors: [APIError.unavailable, -32010], constraints: targetConstraints, semantics: semantics)
        }
        commands["window.focus"] = commandContract("window.focus", parameters: ["windowId": S.string(), "activate": S.defaulted(S.boolean, .bool(false))],
            required: ["windowId"], result: S.reference("WindowFocusCommit"), guards: ["expectedInstanceId", "expectedWorkspaceRevision"],
            conditions: [requires("liveNativeWindowIDFromWindowList")], routing: "nativeWindowID", errors: [APIError.unavailable],
            semantics: commitSemantics.merging(["deminimizes": .bool(true), "activateApplicationOnlyWhenTrue": .bool(true)]) { _, value in value })
        return commands
    }()
}
