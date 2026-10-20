import Foundation

extension AutomationContracts {
    public static let browserDownloadDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        let fields: [String: JSONValue] = [
            "downloadId": S.string(minimumLength: 36, maximumUTF8Bytes: 36, format: "uuid"),
            "state": S.strings(["starting", "awaitingDestination", "downloading", "completed", "cancelled", "failed"]),
            "suggestedFilename": S.string(minimumLength: 1, maximumUTF8Bytes: 240),
            "mimeType": S.nullable(S.annotated(S.string(), ["maxLength": .integer(128)])),
            "path": S.nullable(S.string(maximumUTF8Bytes: 4096)),
            "receivedBytes": S.integer(minimum: 0),
            "totalBytes": S.nullable(S.integer(minimum: 0)),
            "error": S.nullable(S.object([
                "message": S.string(maximumUTF8Bytes: 512),
                "domain": S.annotated(S.string(), ["maxLength": .integer(128)]),
                "code": S.integer()
            ], required: ["message"]))
        ]
        return [
            "BrowserDownload": S.object(fields, required: Array(fields.keys)),
            "BrowserDownloads": S.object(["downloads": S.array(S.reference("BrowserDownload"), maximum: 64)], required: ["downloads"]),
            "BrowserDownloadsShown": S.object(["shown": S.constant(.bool(true))], required: ["shown"])
        ]
    }()

    public static let browserDownloads: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        var methods: [AutomationMethod: AutomationContract] = [:]
        for method in [AutomationMethod.browserDownloads, .browserDownload, .browserSaveDownload, .browserCancelDownload, .browserShowDownloads] {
            var parameters: [String: JSONValue] = ["pane": S.paneID, "tab": S.tabID,
                "popupId": S.string(minimumLength: 1, maximumUTF8Bytes: 128)]
            var required = ["pane"]
            if method != .browserDownloads && method != .browserShowDownloads {
                parameters["downloadId"] = S.string(minimumLength: 36, maximumUTF8Bytes: 36, format: "uuid")
                required.append("downloadId")
            }
            if method == .browserSaveDownload {
                parameters["path"] = S.annotated(S.string(minimumLength: 2, maximumUTF8Bytes: 4096, pattern: "^/"), [
                    "x-noControls": .bool(true)
                ])
                required.append("path")
            }
            methods[method] = AutomationContract(parameters: parameters, required: required,
                result: S.reference(method == .browserDownloads ? "BrowserDownloads" : method == .browserShowDownloads ? "BrowserDownloadsShown" : "BrowserDownload"),
                guards: targetGuards, conditions: [.object(["requires": .string("liveBrowserPane")])],
                routing: "explicitOrCallerBrowserPaneNeverFocus", errors: [APIError.unavailable, APIError.conflict], semantics: [
                    "downloadIdentity": .string("opaqueOwnerBoundIdentitySurvivesDocumentNavigation"),
                    "maximumActiveDownloadsPerOwner": .integer(8), "maximumRetainedStatusesPerOwner": .integer(64),
                    "destinationSelectionTimeoutSeconds": .integer(300),
                    "nativeAndAPICompletion": .string("sameDestinationAndCancellationOperations"),
                    "saveRequiresState": .string("awaitingDestination"), "cancelRequiresActiveState": .bool(true),
                    "destination": .string("newFileInExistingWritableDirectory"),
                    "existingFiles": .string("neverReplacedIncludingFilesCreatedDuringTransfer"),
                    "path": .string("selectedFinalDestinationAppearsOnlyAfterSuccessfulCompletion"),
                    "partialFiles": .string("privateAdjacentStagingRemovedOnCancellationOrFailure"),
                    "apiSaveDismissesNativeChooser": .bool(true), "ownerCloseCancels": .bool(true),
                    "webKitSessionAndPrivateStorePreserved": .bool(true), "resume": .bool(false),
                    "returnsWithoutWaitingForTransfer": .bool(true), "doesNotRequireDOMRenderability": .bool(true)
                ])
        }
        return methods
    }()
}
