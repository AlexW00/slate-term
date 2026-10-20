import Foundation

extension AutomationContracts {
    public static let webDialogDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        let identity = S.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")
        let dialogFields: [String: JSONValue] = [
            "dialogId": identity, "kind": S.strings(["alert", "confirm", "prompt"]),
            "message": S.string(maximumUTF8Bytes: 16_384), "origin": S.string(),
            "defaultText": S.nullable(S.string(maximumUTF8Bytes: 65_536)), "truncated": S.boolean
        ]
        let context: [String: JSONValue] = [
            "paneId": S.paneID, "viewId": identity, "documentId": S.nullable(identity),
            "sampledAt": S.number, "popupId": identity
        ]
        let requiredContext = ["paneId", "viewId", "documentId", "sampledAt"]
        return [
            "WebDialog": S.object(context.merging([
                "dialog": S.nullable(S.object(dialogFields, required: Array(dialogFields.keys)))
            ]) { _, value in value }, required: requiredContext + ["dialog"]),
            "WebDialogResponse": S.object(context.merging([
                "dialogId": identity, "accepted": S.boolean
            ]) { _, value in value }, required: requiredContext + ["dialogId", "accepted"])
        ]
    }()

    public static let webDialogs: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        let identity = S.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")
        let target: [String: JSONValue] = ["pane": S.paneID, "tab": S.tabID, "popupId": identity]
        var methods: [AutomationMethod: AutomationContract] = [:]
        for method in [AutomationMethod.webDialog, .webRespondDialog] {
            let responding = method == .webRespondDialog
            var parameters = target
            var required = ["pane"]
            var constraints = webIdentityConstraints
            if responding {
                parameters["dialogId"] = identity
                parameters["action"] = S.strings(["accept", "dismiss"])
                parameters["text"] = S.string(maximumUTF8Bytes: 65_536)
                required += ["dialogId", "action"]
                constraints.append(.object([
                    "if": S.object([:], required: ["text"], additional: true),
                    "then": S.object(["action": S.constant(.string("accept"))], required: ["action"], additional: true)
                ]))
            }
            methods[method] = AutomationContract(
                parameters: parameters, required: required, result: S.reference(responding ? "WebDialogResponse" : "WebDialog"),
                guards: targetGuards + ["expectedViewId", "expectedDocumentId"],
                conditions: [.object(["requires": .string("browserOrRegisteredPluginWebView")])],
                routing: "explicitOrCallerPaneNeverFocus", errors: [APIError.unavailable, APIError.conflict],
                constraints: constraints, semantics: [
                    "dialogIdentity": .string("singleUseBoundToOwningViewAndDocumentLifetime"),
                    "completion": .string("sameWebKitCallbackAsNativeSheet"),
                    "doesNotRequireDOMRenderability": .bool(true),
                    "navigationCloseAndProcessTerminationCancel": .bool(true),
                    "conflictingSheet": .string("cancelWithoutAccepting"),
                    "promptText": .string("acceptOnlyForPromptOmissionUsesCurrentNativeFieldIncludingDefault"),
                    "maximumPendingDialogsPerView": .integer(1),
                    "popupId": .string("optionalOwnedPopupOtherwiseMainPaneView")
                ])
        }
        return methods
    }()
}
