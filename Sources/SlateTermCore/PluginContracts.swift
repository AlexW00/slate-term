import Foundation

extension AutomationContracts {
    static let workspaceCommitFields: [String: JSONValue] = [
        "operationId": APISchema.uuid, "workspaceRevision": APISchema.revision,
        "outcome": APISchema.strings(["committed", "unchanged"]),
        "workspacePersistence": APISchema.strings(WorkspacePersistence.allCases.map(\.rawValue))
    ]

    public static let pluginDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        func complete(_ fields: [String: JSONValue]) -> JSONValue { S.object(fields, required: Array(fields.keys)) }
        var definitions = PluginContractSchemas.packageDefinitions
        for input in [false, true] {
            let suffix = input ? "Input" : ""
            definitions["PluginRegistration" + suffix] = PluginContractSchemas.registration(input: input)
            definitions["PluginSource" + suffix] = PluginContractSchemas.source(input: input)
            definitions["PluginProcess" + suffix] = PluginContractSchemas.process(input: input)
            definitions["PluginCommand" + suffix] = PluginContractSchemas.command(input: input)
            definitions["PluginCompatibility" + suffix] = PluginContractSchemas.compatibility(input: input)
            definitions["PluginHeaderButton" + suffix] = PluginContractSchemas.headerButton(input: input)
            definitions["SavedLayoutField" + suffix] = PluginContractSchemas.layoutField(input: input)
        }
        definitions["PluginCompatibilityReport"] = complete([
            "compatible": S.boolean, "hostAPIVersion": S.constant(.integer(PluginCompatibility.currentAPIVersion)),
            "hostManifestVersion": S.constant(.integer(PluginCompatibility.currentManifestVersion)), "reasons": S.array(S.string(), maximum: 4)
        ])
        let installed: [String: JSONValue] = [
            "id": pluginNamespace, "title": S.string(), "enabled": S.boolean, "installationID": S.uuid,
            "available": S.boolean, "diagnostic": S.nullable(S.string()), "packageRoot": PluginContractSchemas.absolutePath,
            "compatibilityStatus": S.nullable(S.reference("PluginCompatibilityReport"))
        ]
        var healthy = definitions["PluginRegistration"]!.object!
        healthy["properties"] = .object(healthy["properties"]!.object!.merging(installed) { old, _ in old }.merging([
            "available": S.constant(.bool(true)), "diagnostic": S.null, "compatibilityStatus": S.reference("PluginCompatibilityReport")
        ]) { _, v in v })
        if case .array(let required) = healthy["required"] {
            healthy["required"] = .array(Array(Set(required.compactMap(\.string) + Array(installed.keys))).sorted().map(JSONValue.string))
        }
        let unavailable = complete(installed.merging(["available": S.constant(.bool(false)),
            "diagnostic": S.string(), "compatibilityStatus": S.null]) { _, v in v })
        definitions["InstalledPlugin"] = S.oneOf([.object(healthy), unavailable])
        definitions["PluginInstallation"] = .object(healthy)
        definitions["ListedPlugin"] = S.oneOf([JSONValue.object(healthy), unavailable].map { value in
            var schema = value.object!
            var properties = schema["properties"]!.object!
            properties["cleanupPending"] = S.boolean
            schema["properties"] = .object(properties)
            if case .array(let required) = schema["required"] { schema["required"] = .array(required + [.string("cleanupPending")]) }
            return .object(schema)
        })
        definitions["PluginPackageValidation"] = complete(["valid": S.constant(.bool(true)), "id": pluginNamespace, "title": PluginContractSchemas.title,
            "manifest": S.reference("PluginPackageManifest"), "archiveSHA256": S.string(pattern: "^[0-9a-f]{64}(?![\\s\\S])"),
            "compatibilityStatus": S.reference("PluginCompatibilityReport")])
        definitions["PluginPackageCleanup"] = complete(["type": S.string(), "kind": S.constant(.string("packageCleanup")),
            "packageRoot": PluginContractSchemas.absolutePath, "cleanupPending": S.constant(.bool(true)), "diagnostic": S.string()])
        let pid = S.nullable(S.integer(minimum: 1, maximum: Int(Int32.max)))
        definitions["PluginInstance"] = complete([
            "instanceId": S.uuid, "type": pluginNamespace, "scope": S.strings(["pane", "tab", "global"]), "scopeKey": S.string(),
            "url": S.string(), "state": S.strings(["idle", "starting", "ready", "failed", "restarting", "stopping", "closed"]),
            "error": S.nullable(S.string()), "pid": pid, "restartCount": S.integer(minimum: 0, maximum: 10), "panes": S.array(S.paneID)
        ])
        definitions["PluginCommandRun"] = complete([
            "instanceId": S.uuid, "type": pluginNamespace, "kind": S.constant(.string("command")), "commandId": S.string(),
            "state": S.strings(["running", "succeeded", "failed", "timedOut", "cancelled"]),
            "tabId": S.nullable(S.tabID), "paneId": S.nullable(S.paneID), "pid": pid, "cleanupPending": S.boolean,
            "exitCode": S.nullable(S.integer()), "signal": S.nullable(S.integer()), "error": S.nullable(S.string())
        ])
        definitions["PluginLifecycleResult"] = complete(workspaceCommitFields.merging(["id": pluginNamespace, "enabled": S.boolean]) { _, value in value })
        return definitions
    }()

    public static let plugins: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        func legacy(_ parameters: [String: JSONValue] = [:], required: [String] = [], result: JSONValue,
                    errors: [Int] = [], conditions: [JSONValue] = [], routing: String = "none", semantics: [String: JSONValue] = [:]) -> AutomationContract {
            AutomationContract(parameters: paneTarget.merging(parameters) { _, value in value }, required: required, result: result,
                guards: targetGuards, additionalParameters: true, conditions: conditions, routing: routing, errors: errors,
                constraints: targetConstraints, semantics: semantics)
        }
        var methods: [AutomationMethod: AutomationContract] = [
            .pluginsList: legacy(result: S.array(S.reference("ListedPlugin"), maximum: 64),
                semantics: ["includesDisabledAndIncompatible": .bool(true), "enabledIsPreferenceNotCompatibility": .bool(true)]),
            .pluginsStatus: legacy(["id": S.any], result: S.array(S.oneOf([S.reference("PluginInstance"), S.reference("PluginCommandRun"), S.reference("PluginPackageCleanup")])),
                semantics: ["nonStringOrOmittedID": .string("noTypeFilter"), "includesRetainedCommandRuns": .bool(true), "includesBackgroundServices": .bool(false)]),
            .pluginsLogs: legacy(["instanceId": S.string()], required: ["instanceId"], result: S.object(["text": S.string()], required: ["text"]),
                conditions: [.object(["requires": .string("livePanelInstanceOrRetainedCommandRun")])], routing: "pluginInstanceOrCommandInvocation",
                semantics: ["rawPanelTailBytes": .integer(65_536), "rawCommandTailBytesPerStream": .integer(65_536),
                    "decoding": .string("utf8ReplacingInvalidBytes"), "includesBackgroundServices": .bool(false)]),
            .pluginsRestart: legacy(["id": pluginNamespace], required: ["id"], result: S.array(S.reference("PluginInstance"), minimum: 1),
                conditions: [.object(["requires": .string("atLeastOneActivePanelInstanceOfType")])], routing: "pluginID",
                semantics: ["restartResult": .string("observedStateNotReadiness"), "concurrentRestartsCoalesce": .bool(true), "restartsBackgroundService": .bool(false)])
        ]
        for method in [AutomationMethod.pluginsRegister, .pluginsValidate] {
            let validate = method == .pluginsValidate
            var parameters = ["packagePath": PluginContractSchemas.absolutePath]
            if !validate { parameters["replace"] = S.defaulted(S.boolean, .bool(false)) }
            methods[method] = AutomationContract(parameters: parameters, required: ["packagePath"],
                result: S.reference(validate ? "PluginPackageValidation" : "PluginInstallation"), guards: unanchoredGuards,
                conditions: (validate ? [] : [.object(["requires": .string("standardSlateRuntime")])])
                    + [.object(["requires": .string("regularReadableZIPWithValidPortableRootManifestAndSafeBoundedContents")]),
                    .object(["requires": .string("compatibleManifestAndNoConcurrentPackageOperation")])]
                    + (validate ? [] : [.object(["requires": .string("unchangedRegistryNoOpenPanesOfTypeAndInstallationAndCleanupCapacity")])]),
                routing: "explicitZIPPathThenManifestPluginID", errors: [APIError.incompatible, APIError.settingsWriteFailed, APIError.unavailable, -32010]
                    + (validate ? [] : [APIError.layoutAppManagementUnavailable]),
                semantics: ["format": .string("zipWithRootPluginJSON"), "legacyManifestRegistration": .bool(false),
                    "validationPublishesInstallation": .bool(false), "validationStagesPrivateTemporaryFiles": .bool(true),
                    "relativeResources": .string("resolvedAgainstManagedPackageRoot"), "dependencyInstallation": .bool(false),
                    "maximumRegistrations": .integer(64), "preservesEnabledPreference": .bool(true),
                    "incompatibleReplacementPreservesPrevious": .bool(true), "activatesService": .bool(false),
                    "publication": .string("completeGenerationThenAtomicRegistryPointer"),
                    "maximumArchiveBytes": .integer(134_217_728), "maximumExtractedBytes": .integer(536_870_912),
                    "maximumFileBytes": .integer(67_108_864), "maximumEntries": .integer(10_000),
                    "maximumManifestBytes": .integer(262_144), "powerLossDurabilityGuaranteed": .bool(false),
                    "oldFiles": .string("retiredOnlyAfterConfirmedProcessAndResourceRelease")])
        }
        for method in [AutomationMethod.pluginsEnable, .pluginsDisable, .pluginsUnregister] {
            methods[method] = AutomationContract(parameters: ["id": pluginNamespace, "force": S.defaulted(S.boolean, .bool(false))], required: ["id"],
                result: S.reference("PluginLifecycleResult"), guards: unanchoredGuards,
                conditions: [.object(["requires": .string("standardSlateRuntime")]), .object(["requires": .string("registeredPlugin")]),
                    .object(["requires": .string(method == .pluginsEnable ? "compatibleManifest" : "forceWhenPanesUsePlugin")])],
                routing: "pluginID", errors: [APIError.unavailable, APIError.settingsWriteFailed, APIError.layoutAppManagementUnavailable] + (method == .pluginsEnable ? [APIError.incompatible] : [-32010]),
                semantics: ["preservesSavedPluginData": .bool(true), "forceClosesUsingPanes": .bool(method != .pluginsEnable),
                    "modelAcceptanceIsDiskDurability": .bool(false), "retirementOnDisableOrRemoval": .string("viewsPanelInstancesCommandsAndBackgroundServices")])
        }
        return methods
    }()
}
