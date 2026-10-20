import Foundation

extension AutomationContracts {
    public static let terminal: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        let output: [String: JSONValue] = ["text": S.string(maximumUTF8Bytes: TerminalOutput.maximumBytes), "truncated": S.boolean]
        let identity: [String: JSONValue] = ["paneId": S.paneID, "sessionId": S.string()]
        let handle = identity.merging(["commandId": S.uuid]) { _, value in value }
        let captured = identity.merging(output) { _, value in value }
        let resultFields = handle.merging(output) { _, value in value }.merging(["exitCode": S.exitCode]) { _, value in value }
        let runResult = S.object(resultFields, required: Array(handle.keys) + Array(output.keys))
        let status = S.object(handle.merging([
            "state": S.strings(TerminalOperationState.allCases.map(\.rawValue)),
            "exitCode": S.exitCode,
            "failure": S.strings(TerminalOperationFailure.allCases.map(\.rawValue))
        ]) { _, value in value }, required: Array(handle.keys) + ["state"])
        let timeout = S.defaulted(S.integer(minimum: 1, maximum: TerminalOperations.maximumTimeoutMilliseconds), .integer(30_000))
        let command = S.string(minimumLength: 1, maximumUTF8Bytes: TerminalOperationStore.maximumCommandBytes, pattern: "^[^\\u0000]*(?![\\s\\S])")
        let sessionTarget = paneTarget.merging([
            "scope": S.defaulted(S.strings(["pane", "tab", "global"]), .string("tab")), "sessionId": S.string()
        ]) { _, value in value }
        let live: [JSONValue] = [.object(["requires": .string("liveTerminalSession")])]
        let idle: [JSONValue] = live + [.object(["requires": .string("authenticatedIdlePrompt")]), .object(["requires": .string("runAvailableShell")]),
            .object(["requires": .string("matchingShellWhenSpecified")]), .object(["requires": .string("emptyPrimaryEditorAtClaim")])]
        // The command is source code in the pane's shell; `shell` refuses a mismatch instead of translating.
        let shell = S.strings(ShellKind.allCases.map(\.rawValue))
        let operationSemantics: [String: JSONValue] = [
            "owner": .string("terminalSession"), "disconnectStopsExecution": .bool(false),
            "waitTimeoutStopsExecution": .bool(false), "output": .string("boundedScreenNotIsolatedStdout"),
            "crossRestartDurability": .bool(false)
        ]
        func terminal(_ parameters: [String: JSONValue] = [:], required: [String] = [], result: JSONValue,
                      conditions: [JSONValue]? = nil, errors: [Int] = [], constraints: [JSONValue] = [],
                      semantics: [String: JSONValue] = [:]) -> AutomationContract {
            AutomationContract(parameters: sessionTarget.merging(parameters) { _, value in value }, required: required,
                result: result, guards: targetGuards, conditions: conditions ?? live, routing: "contextualTerminal",
                errors: [-32004] + errors, constraints: targetConstraints + constraints, semantics: semantics)
        }
        var methods: [AutomationMethod: AutomationContract] = [
            .terminalSend: terminal(["text": S.string()], required: ["text"], result: S.emptyObject,
                semantics: ["input": .string("rawUTF8NotPasteOrShellQuoting"), "promptGuarded": .bool(false)]),
            .terminalKey: terminal(["key": S.string(minimumLength: 1, maximumUTF8Bytes: 128, format: "slate-terminal-key")],
                required: ["key"], result: S.emptyObject),
            .terminalCapture: terminal(result: S.object(captured, required: Array(captured.keys)),
                semantics: ["output": .string("activeScreenNotScrollbackOrIsolatedStdout")]),
            .terminalRun: terminal(["command": command, "timeoutMilliseconds": timeout, "shell": shell], required: ["command"], result: runResult,
                conditions: idle, errors: [-32041, -32042, -32024], semantics: operationSemantics),
            .terminalStart: terminal(["command": command, "shell": shell], required: ["command"], result: S.object(handle, required: Array(handle.keys)),
                conditions: idle, errors: [-32041, -32042],
                semantics: operationSemantics.merging(["completion": .string("adoptedNotExecuted"), "deliveryFailureRetainedAfterAdoption": .bool(true)]) { _, value in value }),
            .terminalWait: terminal([
                "contains": S.string(minimumLength: 1, maximumUTF8Bytes: 4_096),
                "afterSequence": S.integer(minimum: 0), "timeoutMilliseconds": timeout
            ], result: S.object(identity.merging([
                "matched": S.constant(.bool(true)), "sequence": S.nullable(S.integer(minimum: 0)), "exitCode": S.nullable(S.exitCode)
            ]) { _, value in value }, required: Array(identity.keys) + ["matched", "sequence", "exitCode"]),
                conditions: live + [.object(["requires": .string("authenticatedPromptState"),
                    "when": .object(["not": .object(["required": .array([.string("contains")])])])])],
                errors: [-32041, -32042, -32024],
                constraints: [.object(["not": .object(["required": .array([.string("contains"), .string("afterSequence")])])])],
                semantics: ["outputCondition": .string("literalActiveScreenMayMatchExistingText"), "timeoutStopsExecution": .bool(false)])
        ]
        let historySource = S.strings(TerminalHistoryRequest.Source.allCases.map(\.rawValue))
        let historyInput = [
            "source": S.defaulted(historySource, .string("current")),
            "maxBytes": S.defaulted(S.integer(minimum: 1, maximum: TerminalHistoryRequest.maximumBytes), .integer(TerminalHistoryRequest.maximumBytes)),
            "maxLines": S.defaulted(S.integer(minimum: 1, maximum: TerminalHistoryRequest.maximumLines), .integer(2_000))
        ]
        let historyResult = identity.merging([
            "source": historySource, "available": S.boolean,
            "capturedAt": S.nullable(S.annotated(S.number, ["minimum": .integer(-62_135_596_800), "maximum": .integer(253_402_300_799)])),
            "ended": S.nullable(S.boolean),
            "truncated": S.boolean, "lineCount": S.integer(minimum: 0, maximum: TerminalHistoryRequest.maximumLines),
            "byteCount": S.integer(minimum: 0, maximum: TerminalHistoryRequest.maximumBytes)
        ]) { _, value in value }
        methods[.terminalHistory] = terminal(historyInput,
            result: S.object(historyResult.merging(["text": output["text"]!]) { _, value in value }, required: Array(historyResult.keys) + ["text"]),
            semantics: ["output": .string("tailOfSelectedHistoryNotIsolatedStdout"),
                "defaultSource": .string("current"), "previousUnavailable": .string("emptyTextWithAvailableFalse"),
                "sessionId": .string("currentPaneSessionGuardNotHistoricalSession"),
                "capturedAt": .string("unixSecondsForPreviousOtherwiseNull"), "ended": .string("previousProcessExitObservedOtherwiseNull")])
        let absolutePath = S.string(pattern: "^/[^\\u0000]*(?![\\s\\S])")
        methods[.terminalHistoryExport] = terminal(historyInput.merging(["path": absolutePath]) { _, value in value }, required: ["path"],
            result: S.object(historyResult.merging(["path": absolutePath]) { _, value in value }, required: Array(historyResult.keys) + ["path"]),
            errors: [-32020, APIError.unavailable], semantics: ["overwrites": .bool(false), "followsFinalSymlink": .bool(false),
                "newFileMode": .string("0600"), "failedWriteMayLeavePartialFile": .bool(true), "output": .string("tailOfSelectedHistoryNotIsolatedStdout"),
                "defaultSource": .string("current"), "previousUnavailable": .string("errorWithoutCreatingFile"),
                "sessionId": .string("currentPaneSessionGuardNotHistoricalSession"),
                "capturedAt": .string("unixSecondsForPreviousOtherwiseNull"), "ended": .string("previousProcessExitObservedOtherwiseNull")])
        methods[.terminalSearch] = terminal([
            "action": S.defaulted(S.strings(TerminalSearchRequest.Action.allCases.map(\.rawValue)), .string("get")),
            "query": S.string(maximumUTF8Bytes: 4_096, pattern: "^[^\\u0000]*(?![\\s\\S])")
        ], result: S.object(identity.merging([
            "active": S.boolean, "query": S.string(), "total": S.nullable(S.integer(minimum: 0)), "selected": S.nullable(S.integer(minimum: 0))
        ]) { _, value in value }, required: Array(identity.keys) + ["active", "query", "total", "selected"]),
            constraints: [.object([
                "if": S.object(["action": S.constant(.string("set"))], required: ["action"], additional: true),
                "then": .object(["required": .array([.string("query")])]),
                "else": .object(["not": .object(["required": .array([.string("query")])])])
            ])], semantics: ["searches": .string("retainedHistory"), "selectedIndexBase": .integer(0), "resultsAsynchronous": .bool(true)])
        for method in [AutomationMethod.terminalOperations, .terminalOperationStatus, .terminalOperationResult, .terminalOperationWait] {
            let list = method == .terminalOperations
            let wait = method == .terminalOperationWait
            var parameters: [String: JSONValue] = list ? [:] : ["commandId": S.uuid]
            if wait { parameters["timeoutMilliseconds"] = timeout }
            methods[method] = AutomationContract(parameters: parameters, required: list ? [] : ["commandId"],
                result: list ? S.array(status, maximum: TerminalOperationStore.maximumRecords) : method == .terminalOperationStatus ? status : runResult,
                guards: ["expectedInstanceId"], conditions: list ? [] : [.object(["requires": .string("retainedOperationHandle")])],
                routing: "operationHandleNotLivePane", errors: list ? [] : [APIError.unavailable] + (method == .terminalOperationStatus ? [] : [-32042]) + (wait ? [-32024] : []),
                semantics: operationSemantics.merging(["resultsRepeatable": .bool(true), "retentionSeconds": .integer(Int(TerminalOperationStore.retention.components.seconds))]) { _, value in value })
        }
        for method in [AutomationMethod.panesSend, .panesCapture] {
            var parameters = paneTarget.merging(["sessionId": S.string()]) { _, value in value }
            if method == .panesSend { parameters["text"] = S.string() }
            methods[method] = AutomationContract(parameters: parameters, required: method == .panesSend ? ["text"] : [],
                result: method == .panesSend ? S.emptyObject : S.object(output, required: Array(output.keys)), guards: targetGuards,
                additionalParameters: true, conditions: live, routing: "directTerminalPane", constraints: targetConstraints,
                semantics: ["legacy": .bool(true), "unknownNonGuardParameters": .string("ignored"), "promptGuarded": .bool(false)])
        }
        return methods
    }()
}
