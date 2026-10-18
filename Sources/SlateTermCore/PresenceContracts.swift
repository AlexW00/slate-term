import Foundation

extension AutomationContracts {
    public static let presenceDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        let name = S.string(maximumUTF8Bytes: 32, pattern: "^[A-Za-z0-9][A-Za-z0-9._:-]*(?![\\s\\S])")
        // Home is presentation-only: the metadata decoder accepts bounded opaque
        // ASCII identifiers, not only live/canonical pane IDs.
        let home = S.string(minimumLength: 1, maximumUTF8Bytes: 32, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")
        let activity: [String: JSONValue] = ["activityId": S.string(), "actor": name, "label": S.string(), "pane": S.paneID,
            "actionKind": S.strings(["read", "write", "run", "wait", "navigate", "eval", "command", "hold"]),
            "count": S.integer(minimum: 0), "live": S.boolean, "leased": S.boolean, "element": S.boolean, "canFocus": S.boolean]
        let optional: [String: JSONValue] = ["note": S.string(format: "slate-presence-note"), "home": home, "tab": S.tabID,
            "leaseExpiresInMilliseconds": S.integer(minimum: 0, maximum: 600_000), "result": S.strings(["ok", "failed"])]
        let identity = S.string(minimumLength: 1, maximumUTF8Bytes: 64, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")
        return [
            // The origin names the agent's own app instance and terminal session, so a click can focus it.
            "PresenceOrigin": S.object(["instanceId": identity, "sessionId": identity], required: ["instanceId", "sessionId"]),
            "PresenceActor": S.object(["name": name, "note": S.string(format: "slate-presence-note"), "home": home,
                "origin": S.reference("PresenceOrigin")], required: ["name"]),
            "RequestMetadata": S.object(["version": S.constant(.integer(1)), "actor": S.reference("PresenceActor"),
                "cause": S.string(minimumLength: 1, maximumUTF8Bytes: 64, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")], required: ["version"]),
            "PresenceActivity": S.object(activity.merging(optional) { _, v in v }, required: Array(activity.keys)),
            "PresenceList": S.object(["visible": S.boolean, "activities": S.array(S.reference("PresenceActivity"), maximum: PresenceTracker.maximumRecords)], required: ["visible", "activities"])
        ]
    }()

    public static let presence: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        let common: [String: JSONValue] = ["identity": .string("selfClaimedAdministrativeRequestMetadataNotAuthorization"),
            "metadataWithCause": .string("actorIgnoredToPreventEventFeedback"), "bridgeAndServiceActors": .string("ignored"),
            "persistence": .string("ephemeralHostSession"), "visibilityPreferenceStopsTracking": .bool(false)]
        return [
            .presenceList: AutomationContract(parameters: [:], result: S.reference("PresenceList"), guards: unanchoredGuards,
                semantics: common.merging(["sweepsExpiredAndRetiredPaneRecords": .bool(true)]) { _, v in v }),
            .presenceHold: AutomationContract(parameters: ["pane": S.paneID,
                "ttlSeconds": S.defaulted(S.annotated(S.number, ["minimum": .integer(1), "maximum": .integer(600)]), .integer(60))], required: ["pane"],
                result: S.object(["activityId": S.string(), "pane": S.paneID, "expiresInMilliseconds": S.integer(minimum: 1000, maximum: 600_000)],
                    required: ["activityId", "pane", "expiresInMilliseconds"]), guards: targetGuards,
                conditions: [.object(["requires": .string("liveExplicitPaneAndAdministrativeActorWithoutCause")]),
                    .object(["requires": .string("targetDiffersFromActorHomeAndPresenceCapacityAvailable")])], routing: "explicitPane",
                errors: [APIError.unavailable], semantics: common.merging(["sameActorPaneCallsExtendLease": .bool(true)]) { _, v in v }),
            .presenceRelease: AutomationContract(parameters: ["pane": S.paneID], required: ["pane"],
                result: S.object(["released": S.boolean, "pane": S.paneID], required: ["released", "pane"]), guards: targetGuards,
                conditions: [.object(["requires": .string("liveExplicitPaneAndAdministrativeActorWithoutCause")])], routing: "explicitPane",
                errors: [APIError.unavailable], semantics: common.merging(["missingLease": .string("releasedFalse"),
                    "removesRunningCalls": .bool(false), "minimumDisplayHoldStillApplies": .bool(true)]) { _, v in v }),
            .presenceFocus: AutomationContract(parameters: ["activityId": S.string(minimumLength: 1, maximumUTF8Bytes: 64,
                    pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")], required: ["activityId"],
                result: S.object(["focused": S.boolean, "paneId": S.paneID, "tabId": S.tabID, "windowId": S.string()], required: ["focused"]),
                guards: ["expectedInstanceId", "expectedWorkspaceRevision"],
                conditions: [.object(["requires": .string("activityOriginIsThisInstanceAndALiveHomeTerminalWithTheSameSession")])],
                semantics: common.merging(["invalidOrigin": .string("focusedFalseNoOp"), "fallsBackToCurrentFocus": .bool(false),
                    "activatesWindow": .bool(true)]) { _, v in v })
        ]
    }()
}
