import Foundation

extension AutomationContracts {
    public static let savedLayoutDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        func complete(_ fields: [String: JSONValue]) -> JSONValue { S.object(fields, required: Array(fields.keys)) }
        let text = S.annotated(S.string(maximumUTF8Bytes: 1024), ["x-maxGraphemeCount": .integer(100), "x-noControls": .bool(true)])
        let name = S.annotated(text, ["x-nonemptyAfterTrimmingWhitespaceAndNewlines": .bool(true)])
        let manualTitle = S.annotated(name, ["x-trimmed": .bool(true)])
        let directory = S.string(pattern: "^(?:|/[^\\u0000]*|~/[^\\u0000]*)(?![\\s\\S])")
        let command = S.string(maximumUTF8Bytes: TerminalOperationStore.maximumCommandBytes, pattern: "^[^\\u0000]*(?![\\s\\S])")
        let browserURL = S.oneOf([S.constant(.string("")), S.string(format: "slate-browser-url")])
        var definitions: [String: JSONValue] = [:]
        definitions["SavedLayoutTree"] = S.oneOf([
            complete(["kind": S.constant(.string("pane")), "pane": S.paneID]),
            complete(["kind": S.constant(.string("split")), "axis": S.strings(["horizontal", "vertical"]),
                "fraction": S.annotated(S.number, ["minimum": .number(0.1), "maximum": .number(0.9)]),
                "first": S.reference("SavedLayoutTree"), "second": S.reference("SavedLayoutTree")])
        ])
        for input in [false, true] {
            let suffix = input ? "Input" : ""
            func pane(type: JSONValue, configuration: JSONValue) -> JSONValue {
                S.object(["id": S.paneID, "type": type, "title": S.defaulted(text, .string("")),
                    "headerVisible": S.defaulted(S.boolean, .bool(true)), "configuration": S.defaulted(configuration, .object([:]))],
                    required: input ? ["id", "type"] : ["id", "type", "title", "headerVisible", "configuration"])
            }
            definitions["SavedLayoutPane" + suffix] = S.oneOf([
                pane(type: S.constant(.string("terminal")), configuration: S.object(["directory": directory, "command": command])),
                pane(type: S.strings(["browser", "private-browser"]), configuration: S.object(["url": browserURL])),
                pane(type: S.annotated(pluginNamespace, ["not": S.strings(["terminal", "browser", "private-browser"])]),
                    configuration: S.annotated(S.record(S.any), ["x-maxValueDepth": .integer(32),
                        "x-maxEncodedJSONBytes": .integer(PluginPersistence.configurationBytes)]))
            ])
            definitions["SavedLayoutTab" + suffix] = S.object([
                "name": name, "manualTitle": input ? S.nullable(manualTitle) : manualTitle, "layout": S.reference("SavedLayoutTree"),
                "panes": S.array(S.reference("SavedLayoutPane" + suffix), minimum: 1, maximum: 8)
            ], required: ["name", "layout", "panes"])
            definitions["SavedLayoutDefinition" + suffix] = S.annotated(complete([
                "version": S.constant(.integer(1)), "id": S.uuid, "name": name,
                "tabs": S.array(S.reference("SavedLayoutTab" + suffix), minimum: 1, maximum: 8)
            ]), ["x-maxEncodedJSONBytes": .integer(262_144), "x-maxValueDepth": .integer(40),
                "x-savedLayoutTopology": .object(["maximumTreeDepth": .integer(8), "globallyUniquePaneIDs": .bool(true), "exactRecipeLeafMatch": .bool(true)]),
                "x-maxNormalizedSavedLayoutBytes": .integer(262_144)])
        }
        let revision = S.string(pattern: "^[0-9a-f]{64}(?![\\s\\S])")
        definitions["SavedLayoutEntry"] = complete(["file": S.string(), "definition": S.reference("SavedLayoutDefinition"), "revision": revision])
        // Summary truncation can append an ellipsis and replace an incomplete
        // UTF-8 scalar. The emitted string is larger than the prefix byte budget.
        definitions["SavedLayoutSummary"] = complete(["file": S.string(), "id": S.nullable(S.uuid),
            "name": S.nullable(S.string(maximumUTF8Bytes: 517)), "revision": S.nullable(revision),
            "diagnostics": S.array(S.string(maximumUTF8Bytes: 261), maximum: 3)])
        definitions["SavedLayoutPaneType"] = complete(["id": pluginNamespace, "title": S.string(),
            "fields": S.array(S.reference("SavedLayoutField"), maximum: 32)])
        definitions["SavedLayoutSourceWindow"] = complete(["id": S.string(minimumLength: 1), "title": S.string(),
            "tabs": S.array(S.tabID), "groupId": S.groupID, "windowIds": S.array(S.string(minimumLength: 1)), "workspaceRevision": S.revision])
        definitions["SavedLayoutStartup"] = complete(["paneId": S.paneID, "sessionId": S.uuid,
            "state": S.strings(["waitingForPrompt", "starting", "running", "finished", "failed", "completionUnobserved"]),
            "message": S.nullable(S.string())])
        definitions["SavedLayoutOpen"] = complete(workspaceCommitFields.merging([
            "window": S.string(minimumLength: 1), "groupId": S.groupID, "windowIds": S.array(S.string(minimumLength: 1), maximum: 8),
            "paneIds": S.array(S.paneID, minimum: 1, maximum: 64), "startup": S.array(S.reference("SavedLayoutStartup"))
        ]) { _, value in value })
        return definitions
    }()

    public static let savedLayouts: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        func contract(_ parameters: [String: JSONValue] = [:], required: [String] = [], result: JSONValue,
                      guards: [String] = ["expectedInstanceId"], conditions: [JSONValue] = [], errors: [Int] = [],
                      routing: String = "savedLayoutLibrary", semantics: [String: JSONValue] = [:]) -> AutomationContract {
            AutomationContract(parameters: parameters, required: required, result: result, guards: guards,
                conditions: conditions, routing: routing, errors: errors, semantics: semantics)
        }
        func requires(_ condition: String) -> JSONValue { .object(["requires": .string(condition)]) }
        let entry = S.reference("SavedLayoutEntry")
        let definition = S.reference("SavedLayoutDefinitionInput")
        let workspaceGuards = ["expectedInstanceId", "expectedWorkspaceRevision"]
        let knownFields = requires("validValuesForAvailablePaneTypeFields")
        let uniqueFile = requires("uniqueReadableValidSavedLayoutUUID")
        let fileSemantics: [String: JSONValue] = ["authoritative": .string("rescannedFiles"), "maximumJSONFiles": .integer(256),
            "maximumPrettyPrintedFileBytes": .integer(262_144), "publication": .string("completeFileAtomicPublication"),
            "powerLossDurabilityGuaranteed": .bool(false), "externalEditorConflictDetection": .string("bestEffortNotFilesystemCompareAndSwap")]
        return [
            .layoutsList: contract(result: S.array(S.reference("SavedLayoutSummary"), maximum: 256),
                semantics: ["includesInvalidAndAmbiguousFiles": .bool(true), "fullDefinitions": .bool(false),
                    "namePrefixBytes": .integer(512), "diagnosticPrefixBytes": .integer(256), "truncation": .string("utf8ReplacementDecodingThenEllipsis")]),
            .layoutsGet: contract(["id": S.uuid], required: ["id"], result: entry, conditions: [uniqueFile]),
            .layoutsFields: contract(["type": S.string(minimumLength: 1)],
                result: S.annotated(S.array(S.reference("SavedLayoutPaneType"), maximum: 67), ["x-maxEncodedJSONBytes": .integer(899_999)]),
                conditions: [requires("requestedTypeAvailableWhenSupplied"), requires("encodedResultSmallerThan900000Bytes")],
                semantics: ["availableTypes": .string("builtinsAndActiveCompatiblePanelPlugins"), "oversizedAggregate": .string("requestOneType")]),
            .layoutsValidate: contract(["definition": definition], required: ["definition"],
                result: S.object(["valid": S.boolean, "diagnostics": S.array(S.string(), maximum: 129)], required: ["valid", "diagnostics"]),
                semantics: ["structuralErrors": .string("requestFailure"), "dependencyAndFieldErrors": .string("validFalseWithDiagnostics"), "executesOrWrites": .bool(false)]),
            .layoutsCreate: contract(["definition": definition], required: ["definition"], result: entry,
                conditions: [knownFields, requires("allReferencedPaneTypesAvailable"), requires("newUUIDAndDestinationAndAvailableLibraryCapacity")], semantics: fileSemantics),
            .layoutsUpdate: contract(["definition": definition], required: ["definition", "expectedSavedLayoutRevision"], result: entry,
                guards: ["expectedInstanceId", "expectedSavedLayoutRevision"], conditions: [uniqueFile, knownFields],
                semantics: fileSemantics.merging(["missingPluginReferencesMayBePreserved": .bool(true),
                    "expectedSavedLayoutRevision": .string("exactSavedJSONContentNotTOMLOrWorkspace")]) { _, value in value }),
            .layoutsWindows: contract(result: S.array(S.reference("SavedLayoutSourceWindow")), guards: workspaceGuards, routing: "allWorkspaceGroups",
                semantics: ["id": .string("opaqueAppEpochQualifiedWholeGroupSelectorNotNativeWindowID")]),
            .layoutsCapture: contract(["window": S.string(minimumLength: 1), "name": S.annotated(S.string(maximumUTF8Bytes: 1024), [
                    "x-maxGraphemeCount": .integer(100), "x-noControls": .bool(true), "x-nonemptyAfterTrimmingWhitespaceAndNewlines": .bool(true)]),
                "includeDirectories": S.defaulted(S.boolean, .bool(true)), "includeURLs": S.defaulted(S.boolean, .bool(true)),
                "includeCommands": S.defaulted(S.boolean, .bool(false))], required: ["window", "name"], result: entry,
                guards: workspaceGuards, conditions: [requires("liveExplicitWholeGroupSelectorFromLayoutsWindows"), requires("capturedRecipeMeetsCreateRules")],
                routing: "explicitWholeGroupNeverFocus", semantics: fileSemantics.merging([
                    "commands": .string("configuredStartupCommandsOnlyNeverCurrentShellCommands"), "includesTerminalHistory": .bool(false),
                    "pluginConfiguration": .string("startingRecipeNotRuntimeState"), "includeURLsIncludesPrivateBrowser": .bool(true)
                ]) { _, value in value }),
            .layoutsOpen: contract(["id": S.uuid, "focus": S.defaulted(S.strings(["new", "preserve"]), .string("preserve"))], required: ["id"], result: S.reference("SavedLayoutOpen"), guards: workspaceGuards,
                conditions: [uniqueFile, knownFields, requires("allReferencedPaneTypesAvailable"), requires("configuredTerminalDirectoriesExist"),
                    requires("startupCommandsRequireAutomaticLocalShellIntegrationAndAvailableRunReservations")],
                semantics: ["mode": .string("newWindowGroupOnly"), "allocatesFreshRuntimeIDs": .bool(true), "mergesPluginFieldDefaults": .bool(true),
                    "resultAcceptsWorkspaceNotStartupCompletion": .bool(true), "startupOwnedByCommittedSessions": .bool(true),
                    "startupIncludesOtherLiveLayoutSessions": .bool(true), "externalPreparationEffectsRollbackGuaranteed": .bool(false),
                    "snapshotPersistenceFailureDoesNotUndoOpen": .bool(true), "automaticCommandRetry": .bool(false)]),
            .layoutsLauncher: contract(["id": S.uuid, "path": S.string(pattern: "^/[^\\u0000]*(?![\\s\\S])", format: "slate-layout-launcher-path"),
                "name": S.string(minimumLength: 1, maximumUTF8Bytes: 240),
                "icon": S.defaulted(S.strings(SavedLayoutLauncherOptions.icons), .string("slate"))], required: ["id", "path"],
                result: S.object(["id": S.uuid, "path": S.string()], required: ["id", "path"]),
                conditions: [uniqueFile, requires("defaultLayoutLibrary"), requires("newAppDestinationAndAvailableBundledLauncherAndLocalSigner")], errors: [-32000],
                semantics: ["overwritesExistingDestination": .bool(false), "copiesRecipe": .bool(false), "shortcutUsesLatestRecipeByUUID": .bool(true),
                    "dialog": .bool(false), "spotlightIndexingGuaranteed": .bool(false)]),
            .layoutsStartupStatus: contract(result: S.array(S.reference("SavedLayoutStartup")), routing: "allLiveLayoutStartupSessions",
                semantics: ["promptWaitSeconds": .integer(30), "completionWaitSeconds": .integer(295),
                    "completionTimeoutStopsShell": .bool(false), "includesCommandText": .bool(false), "automaticRetry": .bool(false)])
        ]
    }()
}
