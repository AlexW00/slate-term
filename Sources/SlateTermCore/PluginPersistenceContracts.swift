import Foundation

extension AutomationContracts {
    public static let pluginPersistenceDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        func complete(_ fields: [String: JSONValue]) -> JSONValue { S.object(fields, required: Array(fields.keys)) }
        let key = S.string(minimumLength: 1, maximumUTF8Bytes: 256)
        let value = S.annotated(S.any, ["x-maxValueDepth": .integer(32), "x-maxEncodedJSONBytes": .integer(PluginPersistence.valueBytes)])
        func values(panel: Bool) -> JSONValue {
            S.annotated(S.record(value), ["propertyNames": key, "maxProperties": .integer(panel ? 128 : 1024),
                "x-maxEncodedJSONBytes": .integer(panel ? PluginPersistence.stateBytes : PluginPersistence.dataBytes)])
        }
        let panelIdentity: [String: JSONValue] = ["pluginId": S.reference("PluginPersistenceID"), "paneId": S.paneID,
            "panelId": S.uuid, "revision": S.uuid]
        let dataWrite: [String: JSONValue] = ["id": S.reference("PluginPersistenceID"), "revision": S.uuid,
            "changed": S.boolean, "persisted": S.constant(.bool(true)), "operationId": S.uuid]
        return [
            "PluginPersistenceID": S.annotated(pluginNamespace, ["not": S.strings(["terminal", "browser", "private-browser"])]),
            "PluginDataValues": values(panel: false), "PluginPanelValues": values(panel: true),
            "PluginPersistencePatch": S.annotated(S.array(S.oneOf([
                complete(["op": S.constant(.string("set")), "key": key, "value": value]),
                complete(["op": S.constant(.string("delete")), "key": key])
            ]), minimum: 1, maximum: 32), ["x-maxEncodedJSONBytes": .integer(PluginPersistence.patchBytes),
                "x-maxValueDepth": .integer(32), "x-uniqueProperty": .string("key")]),
            "PluginPanelRecord": complete(["panelId": S.uuid, "stateRevision": S.uuid, "state": values(panel: true),
                "configuration": S.annotated(S.record(S.any), ["x-maxValueDepth": .integer(32),
                    "x-maxEncodedJSONBytes": .integer(PluginPersistence.configurationBytes)])]),
            "PluginDataRead": complete(["id": S.reference("PluginPersistenceID"), "revision": S.uuid, "values": values(panel: false)]),
            "PluginDataWrite": complete(dataWrite),
            "PluginPanelRead": complete(panelIdentity.merging(["values": values(panel: true)]) { _, v in v }),
            "PluginPanelWrite": complete(panelIdentity.merging(workspaceCommitFields) { _, v in v }.merging(["changed": S.boolean]) { _, v in v })
        ]
    }()

    public static let pluginPersistence: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        var methods: [AutomationMethod: AutomationContract] = [:]
        for method in [AutomationMethod.pluginDataGet, .pluginDataPatch, .pluginDataReset, .panelStateGet, .panelStatePatch, .panelStateReset] {
            let data = [.pluginDataGet, .pluginDataPatch, .pluginDataReset].contains(method)
            let get = method == .pluginDataGet || method == .panelStateGet
            let reset = method == .pluginDataReset || method == .panelStateReset
            var parameters: [String: JSONValue] = data ? ["id": S.reference("PluginPersistenceID")] : ["pane": S.paneID, "tab": S.tabID]
            var required = [data ? "id" : "pane"]
            var guards = data ? ["expectedInstanceId"] : ["expectedInstanceId", "expectedWorkspaceRevision"]
            if !get {
                let revisions = data ? ["expectedDataRevision"] : ["expectedPanelId", "expectedStateRevision"]
                guards += revisions; required += revisions
                if !reset { parameters["operations"] = S.reference("PluginPersistencePatch"); required.append("operations") }
                if data && reset { parameters["force"] = S.constant(.bool(true)); required.append("force") }
            }
            methods[method] = AutomationContract(parameters: parameters, required: required,
                result: S.reference(data ? (get ? "PluginDataRead" : "PluginDataWrite") : (get ? "PluginPanelRead" : "PluginPanelWrite")),
                guards: guards, conditions: [.object(["requires": .string(data ? "registeredPluginOrRetainedDataFile" : "liveRegisteredPluginPane")])],
                routing: data ? "pluginID" : "explicitPane", errors: [APIError.unavailable, APIError.incompatible, APIError.settingsWriteFailed],
                semantics: ["scope": .string(data ? "applicationStateDirectoryAndPluginID" : "persistedPanelIdentity"),
                    "keySyntax": .string("distinctLiteralKeysNotPaths"), "nullIsStoredValue": .bool(true),
                    "equalPatchAdvancesRevision": .bool(false), "resetAlwaysAdvancesRevision": .bool(true),
                    "workspaceSaveFailure": .string(data ? "notApplicable" : "committedMemoryWithFailedPersistenceStatus"),
                    "dataWriteFailure": .string("previousDocumentRetained"), "automaticRetry": .bool(false),
                    "legacyStorageMigration": .bool(false), "configurationMutableThroughState": .bool(false),
                    "runtimeBounds": .string("mergedDocumentKeyValueDepthAndByteLimitsAndAggregateWorkspaceBudget"),
                    "resetsOtherDomain": .bool(false), "powerLossDurabilityGuaranteed": .bool(false)])
        }
        return methods
    }()
}
