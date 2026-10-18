import Foundation

extension AutomationContracts {
    static let contributedCommandID = APISchema.string(minimumLength: 1, maximumUTF8Bytes: 136,
        pattern: "^plugin\\.[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*\\.[a-z][a-z0-9-]*(?![\\s\\S])")

    public static let contributedCommandDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        var result = pluginDefinitions["PluginCommandRun"]!.object!
        let refinements: [String: JSONValue] = ["state": S.constant(.string("succeeded")), "exitCode": S.constant(.integer(0)),
            "signal": S.null, "error": S.null, "pid": S.null,
            "stdout": S.string(maximumUTF8Bytes: 196_608), "stderr": S.string(maximumUTF8Bytes: 196_608)]
        result["properties"] = .object(result["properties"]!.object!.merging(refinements) { _, value in value })
        if case .array(let required) = result["required"] { result["required"] = .array(required + [.string("stdout"), .string("stderr")]) }
        return ["ContributedCommandResult": .object(result)]
    }()

    /// An application-owned command namespace is not a permission tier. The
    /// registration owns executable/timeout settings; arguments cannot override them.
    public static let contributedCommand = AutomationContract(
        parameters: paneTarget.merging(["id": contributedCommandID]) { _, value in value }, required: ["id"],
        result: APISchema.reference("ContributedCommandResult"), guards: targetGuards,
        additionalParameters: true, additionalExpectedArguments: true,
        conditions: [
            .object(["requires": .string("commandDeclaredByActiveCompatibleRegistration")]),
            .object(["requires": .string("capturedRegistrationAndTargetStillCurrentBeforeSpawn")]),
            .object(["requires": .string("noRunningOrCleanupPendingInvocationOfSameCommand")]),
            .object(["requires": .string("fewerThan16RunningOrCleanupPendingPluginCommands")]),
            .object(["requires": .string("resolvedInvocationJSONAtMost16384Bytes")])
        ], routing: "explicitOrCallerPaneThenFocusOrNoWorkspace",
        errors: [-32601, -32023, -32024, -32025, APIError.incompatible], constraints: targetConstraints,
        semantics: [
            "additionalArguments": .string("opaqueJSONIncludingUnknownExpectedPrefixes"),
            "reservedHostGuardsRetainHostValidation": .bool(true),
            "parametersSentToProcess": .string("fullResolvedObjectIncludingIDTargetsAndSupportedGuards"),
            "scopeArgument": .string("passedThroughNotRoutingAuthority"),
            "parameterByteLimitMeasuredAfter": .string("contextAnchorResolutionAndCapturedPaneTabReplacement"),
            "maximumResolvedParameterBytes": .integer(16_384),
            "executableAndTimeoutSource": .string("registeredCommandNotInvocationArguments"),
            "timeoutSeconds": .object(["minimum": .number(0.1), "maximum": .integer(295), "default": .integer(30)]),
            "success": .string("exitCodeZeroOnly"), "nonzeroExitOrSignal": .string("RPCFailureWithRetainedDiagnosticRecord"),
            "rawOutputTailBytesPerStream": .integer(65_536), "outputDecoding": .string("utf8ReplacingInvalidBytes"),
            "outputIsCompleteStdout": .bool(false), "maximumRetainedRuns": .integer(64),
            "eviction": .string("oldestFinishedWithCleanupCompleteFirst"),
            "retirement": .string("callerCancellationServiceRetirementRegistrationReplacementRemovalOrAppShutdownCancelsOwnedJob"),
            "cleanupMayStillBePendingAtReply": .bool(true), "crossRestartDurability": .bool(false),
            "environment": .string("hostConnectionAndCapturedContextOverrideInheritedOrManifestSlateVariables"),
            "settingsSnapshot": .string("appliedRegistrationNamespaceAtPreparation"),
            "resultHasWorkspaceCommitFields": .bool(false), "automaticRetry": .bool(false)
        ])
}
