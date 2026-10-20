import Foundation

extension AutomationContracts {
    public static let updateDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        let release: [String: JSONValue] = [
            "id": S.string(), "version": S.string(), "build": S.string(), "notes": S.string(),
            "downloadURL": S.string(), "contentLength": S.integer(minimum: 0), "signature": S.string()
        ]
        return [
            "UpdateRelease": S.object(release, required: Array(release.keys)),
            "UpdateSnapshot": S.object([
                "revision": S.string(), "updateId": S.string(),
                "phase": S.annotated(S.string(), ["enum": AutomationCapabilities.updates.object!["phaseValues"]!]),
                "currentVersion": S.string(), "source": S.strings(["signedFeed", "localParent"]), "release": S.reference("UpdateRelease"),
                "receivedBytes": S.integer(minimum: 0), "expectedBytes": S.integer(minimum: 0),
                "detail": S.string(), "windowVisible": S.boolean
            ], required: ["revision", "phase", "currentVersion", "source", "receivedBytes", "expectedBytes", "windowVisible"])
        ]
    }()

    public static let updates: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        let identity = S.string(minimumLength: 1, maximumUTF8Bytes: 256, pattern: "^[!-~]+(?![\\s\\S])")
        // The shared guard schema is broader than UpdateRequest's ASCII identity rule.
        let constraints = [S.object(["expectedInstanceId": identity], additional: true)]
        var contracts: [AutomationMethod: AutomationContract] = [:]
        for action in UpdateAction.allCases {
            var parameters: [String: JSONValue] = [:]
            var required: [String] = []
            var conditions: [JSONValue] = []
            var semantics: [String: JSONValue] = [
                "layoutAppMode": .string("verifiedLocalParentRuntimeWithoutNetworkOrDownload; installRestartsAndRefreshesAtStartup; localReleaseHasEmptyDownloadURLAndSignatureAndZeroContentLength"),
                "scope": .string("application"), "eventTopic": .string("host.updates.changed"),
                "automaticInstallation": .bool(false), "result": .string("currentSnapshotNotAsynchronousCompletion"),
                "optionalResultFields": .string("omittedWhenAbsent"), "failureMayFollowNativeEffect": .bool(true)
            ]
            if [.download, .cancel, .install].contains(action) {
                parameters["updateId"] = identity; required.append("updateId")
                conditions.append(.object(["requires": .string("updateIdMatchesCurrentUpdateSession")]))
            }
            switch action {
            case .openParent:
                conditions.append(.object(["requires": .string("layoutAppWithVerifiedParentApplication")]))
                semantics["startsNetworkRequest"] = .bool(false)
                semantics["opensParentApplication"] = .bool(true)
            case .get:
                semantics["startsNetworkRequest"] = .bool(false)
            case .show:
                semantics["showsWindowAndActivatesApplication"] = .bool(true)
                semantics["startsNetworkRequest"] = .bool(false)
            case .check:
                semantics["showsWindowAndActivatesApplication"] = .bool(true)
                semantics["unconfiguredChannel"] = .string("unavailablePhaseWithWindowShown")
                semantics["activeUpdateSession"] = .string("preservesActivePhaseAndShowsWindow")
                semantics["startsNetworkRequest"] = .string("whenConfiguredAndNoActiveOfferDownloadOrInstall")
            case .download:
                conditions.append(.object(["requires": .string("standardSlateRuntime")]))
                conditions.append(.object(["requires": .string("availableOrDownloadErrorWithOfferAndSignedNotesReady")]))
                semantics["completion"] = .string("observeReadyOrErrorThroughUpdatesGetOrEvents")
                semantics["readyMeans"] = .string("signatureAuthenticatedArchiveNotCompletedInstallabilityCheck")
            case .cancel:
                conditions.append(.object(["requires": .string("standardSlateRuntime")]))
                conditions.append(.object(["requires": .string("installationHasNotStarted")]))
                semantics["resultPhase"] = .string("availableWhenOfferRemainsOtherwiseIdle")
                semantics["cancelsDownloadAndVerification"] = .bool(true)
            case .install:
                parameters["confirm"] = S.constant(.bool(true)); required.append("confirm")
                conditions.append(.object(["requires": .string("readyVerifiedOfferOrConsentedInstallationAwaitingQuitRetry")]))
                semantics["nativeQuitConfirmation"] = .bool(true)
                semantics["runningProcessConfirmation"] = .string("standardRuntimeAtActualTermination; layoutAppBeforeRestart")
                semantics["quitConfirmationCancellation"] = .string("layoutAppUnchangedSnapshotSuccess; standardRuntimeDefersTerminationWithoutRevokingInstallation")
                semantics["revalidatesAfterConfirmation"] = .array([.string("caller"), .string("updateSessionAndReadyOffer")])
                semantics["installation"] = .string("SparkleDownloadsAgainAndValidatesBeforeInstallAndRelaunch")
            }
            contracts[AutomationMethod(rawValue: action.method)!] = AutomationContract(
                parameters: parameters, required: required, result: S.reference("UpdateSnapshot"),
                guards: ["expectedInstanceId"], conditions: conditions, routing: "applicationUpdateSession",
                errors: [APIError.unavailable],
                constraints: constraints, semantics: semantics)
        }
        return contracts
    }()
}
