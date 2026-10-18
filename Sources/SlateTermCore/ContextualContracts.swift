import Foundation

extension AutomationContracts {
    // Public web automation identities are paired, not bridge credentials. The
    // constructor supplies common revision guards; these clauses refine this pair.
    static let webIdentityConstraints: [JSONValue] = [
        APISchema.object([
            "expectedViewId": APISchema.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])"),
            "expectedDocumentId": APISchema.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")
        ], additional: true),
        .object(["oneOf": .array([
            .object(["required": .array([.string("expectedViewId"), .string("expectedDocumentId")])]),
            .object(["not": .object(["anyOf": .array([
                .object(["required": .array([.string("expectedViewId")])]),
                .object(["required": .array([.string("expectedDocumentId")])])
            ])])])
        ])])
    ]

    public static let contextual: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        let methods: [AutomationMethod: AutomationContract] = [
            .layoutConfiguration: AutomationContract(parameters: ["pane": S.paneID, "tab": S.tabID], required: ["pane"],
                result: S.record(S.any), guards: targetGuards, conditions: [.object(["requires": .string("liveExplicitOrCallerPane")])],
                routing: "explicitPane", semantics: ["missingRecipe": .string("emptyObject"), "source": .string("perPaneStartingConfigurationNotLiveState")]),
            .settingsGet: AutomationContract(parameters: ["id": pluginNamespace], required: ["id"], result: S.record(S.reference("TOMLValue")),
                guards: unanchoredGuards, conditions: [.object(["requires": .string("registeredPlugin")])], routing: "pluginID",
                semantics: ["source": .string("appliedNamespace"), "missingNamespace": .string("emptyObject"), "disabledRegistrationAllowed": .bool(true)]),
            .paneTitle: AutomationContract(parameters: paneTarget.merging(["title": S.nullable(S.string(maximumUTF8Bytes: 512))]) { _, value in value },
                required: ["title"], result: S.null, guards: targetGuards + ["expectedViewId", "expectedDocumentId"],
                conditions: [.object(["requires": .string("registeredPluginPane")]),
                    .object(["requires": .string("callerBoundTargetViewOrPairedAutomationIdentity")])],
                routing: "paneOrTabFocus", errors: [APIError.unavailable, -32024, -32025], constraints: targetConstraints + webIdentityConstraints,
                semantics: ["scope": .string("viewDocument"), "nullTitle": .string("restoreDocumentTitleFallback"),
                    "manualTitleHasPriority": .bool(true), "changesPersistentManualTitle": .bool(false)])
        ]
        return methods
    }()
}
