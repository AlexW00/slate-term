import Foundation

extension AutomationContracts {
    public static let browserPopupDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        let identity = S.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")
        guard var fields = webDefinitions["BrowserInspection"]?.object?["properties"]?.object else {
            preconditionFailure("Browser popup inspection requires the browser inspection schema")
        }
        fields["popupId"] = identity
        fields["openerPopupId"] = S.nullable(identity)
        fields["openerOrigin"] = S.string()
        return [
            "BrowserPopup": S.object(fields, required: Array(fields.keys)),
            "BrowserPopups": S.array(S.reference("BrowserPopup"), maximum: 8),
            "BrowserPopupClosed": S.object(["popupId": identity, "closed": S.constant(.bool(true))],
                                           required: ["popupId", "closed"])
        ]
    }()

    public static let browserPopups: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        let target: [String: JSONValue] = ["pane": S.paneID, "tab": S.tabID]
        let identity = S.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")
        let lifecycle: [String: JSONValue] = [
            "maximumLivePopupsPerRootPane": .integer(8),
            "popupId": .string("uniqueForWindowLifetimeNeverRetargeted"),
            "tree": .string("rootPaneOwnsAllDescendants"),
            "ancestorCloseClosesDescendants": .bool(true),
            "session": .string("inheritsOpenerWebKitConfigurationIncludingPrivateDataStore"),
            "automaticScriptPopups": .string("WebKitRequiresUserGesture"),
            "pluginBridge": .bool(false)
        ]
        return [
            .browserPopups: AutomationContract(parameters: target, required: ["pane"],
                result: S.reference("BrowserPopups"), guards: targetGuards,
                conditions: [.object(["requires": .string("browserPane")])],
                routing: "explicitOrCallerPaneNeverFocus", errors: [APIError.unavailable, APIError.conflict],
                constraints: targetConstraints, semantics: lifecycle),
            .browserClosePopup: AutomationContract(
                parameters: target.merging(["popupId": identity]) { _, value in value },
                required: ["pane", "popupId"], result: S.reference("BrowserPopupClosed"),
                guards: targetGuards + ["expectedViewId", "expectedDocumentId"],
                conditions: [.object(["requires": .string("livePopupOwnedByTargetBrowserPane")])],
                routing: "explicitOrCallerPaneNeverFocus", errors: [APIError.unavailable, APIError.conflict],
                constraints: webIdentityConstraints,
                semantics: lifecycle.merging([
                    "expectedIdentity": .string("popupViewAndDocument"),
                    "unknownOrClosedPopup": .string("conflictNeverFallsBackToRootPane"),
                    "completion": .string("sameCleanupAsNativeWindowClose")
                ]) { _, value in value })
        ]
    }()
}
