import Foundation

extension AutomationContracts {
    public static let webDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        func complete(_ fields: [String: JSONValue]) -> JSONValue { S.object(fields, required: Array(fields.keys)) }
        func clipped(_ units: Int) -> JSONValue { S.annotated(S.string(), ["x-maxUTF16CodeUnits": .integer(units)]) }
        let identity = S.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")
        let identityFields: [String: JSONValue] = ["viewId": identity, "documentId": identity]
        let point = complete(["x": S.number, "y": S.number])
        let placement: [String: JSONValue] = ["rect": complete(["x": S.number, "y": S.number, "width": S.number, "height": S.number]),
            "viewport": complete(["width": S.number, "height": S.number])]
        let inspection: [String: JSONValue] = ["viewId": identity, "documentId": S.nullable(identity), "ready": S.boolean,
            "pendingOperations": S.integer(minimum: 0, maximum: 32), "pendingActions": S.integer(minimum: 0, maximum: 32),
            "pendingSubmissions": S.integer(minimum: 0, maximum: 32)]
        var definitions: [String: JSONValue] = ["WebElementRef": S.string(minimumLength: 1, maximumUTF8Bytes: 2048, format: "slate-web-element-ref")]
        definitions["WebElement"] = S.object([
            "ref": S.reference("WebElementRef"), "tag": S.string(), "role": S.string(), "name": clipped(256), "enabled": S.boolean,
            "rect": complete(["x": S.number, "y": S.number, "width": S.number, "height": S.number]), "inViewport": S.boolean,
            "value": clipped(512), "checked": S.boolean, "expanded": S.boolean,
            "type": S.string(), "min": clipped(128), "max": clipped(128), "step": clipped(128)
        ], required: ["ref", "tag", "role", "name", "enabled", "rect", "inViewport"])
        definitions["BrowserInspection"] = complete(inspection.merging([
            "url": S.string(), "title": S.string(), "loading": S.boolean, "type": S.strings(["browser", "private-browser"]), "persistent": S.boolean
        ]) { _, value in value })
        definitions["WebInspection"] = complete(inspection.merging([
            "url": S.annotated(S.string(), ["maxLength": .integer(8192)]), "title": S.annotated(S.string(), ["maxLength": .integer(512)]),
            "truncated": S.boolean, "renderable": S.boolean, "screenshotReady": S.boolean,
            "paneId": S.paneID, "sampledAt": S.number
        ]) { _, value in value })
        var actionFields: [String: [String: JSONValue]] = [
            "Snapshot": ["url": clipped(8192), "title": clipped(512), "viewport": complete(["width": S.number, "height": S.number]),
                "scroll": point, "text": clipped(16_384), "elements": S.array(S.reference("WebElement"), maximum: 256), "truncated": S.boolean],
            "Click": ["performed": S.constant(.bool(true))], "Fill": ["performed": S.constant(.bool(true))],
            // Page input/change listeners can synchronously change selected options;
            // the observed result is not constrained to the submitted values array.
            "Select": ["performed": S.constant(.bool(true)), "values": S.array(S.string())],
            "Scroll": ["x": S.number, "y": S.number],
            "Wait": ["matched": S.constant(.bool(true)), "state": S.strings(["attached", "detached", "visible", "hidden"])]
        ]
        for key in Array(actionFields.keys) {
            actionFields[key] = actionFields[key]!.merging(identityFields) { _, value in value }
            let fields = actionFields[key]!
            let optionalPlacement = ["Scroll", "Wait"].contains(key)
            let located = key == "Snapshot" ? fields : fields.merging(placement) { _, v in v }
            let required = Array((optionalPlacement ? fields : located).keys)
            definitions["Browser" + key] = S.object(located, required: required)
            definitions["Web" + key] = S.object(located.merging(["paneId": S.paneID, "sampledAt": S.number]) { _, value in value },
                required: required + ["paneId", "sampledAt"])
        }
        let newActions: [String: [String: JSONValue]] = [
            "Focus": ["focused": S.constant(.bool(true))],
            "Key": ["dispatched": S.constant(.bool(true)), "defaultPrevented": S.boolean,
                "defaultAction": S.strings(["none", "focus", "activate", "submit"]), "synthetic": S.constant(.bool(true))],
            "Check": ["performed": S.boolean, "checked": S.boolean],
            "SetValue": ["performed": S.constant(.bool(true)), "value": S.string(maximumUTF8Bytes: 4096), "type": S.string()]
        ]
        for (name, fields) in newActions {
            definitions["Web" + name] = complete(fields.merging(identityFields) { _, v in v }.merging(placement) { _, v in v }
                .merging(["paneId": S.paneID, "sampledAt": S.number]) { _, v in v })
        }
        definitions["BrowserNavigation"] = complete(["url": S.string(), "title": S.string(), "loading": S.constant(.bool(false))])
        definitions["BrowserScreenshot"] = complete(["path": S.string()])
        definitions["WebScreenshot"] = complete(["path": S.string(), "paneId": S.paneID, "viewId": identity,
            "documentId": S.nullable(identity), "sampledAt": S.number])
        let chooser = complete(["chooserId": identity, "allowsMultipleSelection": S.boolean, "allowsDirectories": S.boolean])
        let chooserIdentity: [String: JSONValue] = ["paneId": S.paneID, "viewId": identity,
            "documentId": S.nullable(identity), "sampledAt": S.number]
        definitions["WebFileChooser"] = complete(chooserIdentity.merging(["chooser": S.nullable(chooser)]) { _, v in v })
        definitions["WebFileChooserCompletion"] = complete(chooserIdentity.merging([
            "chooserId": identity, "selectedCount": S.integer(minimum: 0, maximum: 128), "cancelled": S.boolean
        ]) { _, v in v })
        definitions["BrowserStoredSites"] = complete(["storage": S.constant(.string("persistent")), "sites": S.array(S.string(minimumLength: 1))])
        definitions["BrowserClearAll"] = complete(["cleared": S.constant(.bool(true)), "scope": S.constant(.string("all")),
            "storage": S.constant(.string("persistent")), "host": S.null])
        definitions["BrowserClearSite"] = complete(["cleared": S.constant(.bool(true)), "scope": S.constant(.string("site")),
            "storage": S.strings(["persistent", "private"]), "host": S.string(minimumLength: 1)])
        for key in Array(definitions.keys) where key.hasPrefix("Web") {
            guard var schema = definitions[key]?.object, var properties = schema["properties"]?.object else { continue }
            properties["popupId"] = identity
            schema["properties"] = .object(properties)
            definitions[key] = .object(schema)
        }
        return definitions
    }()

    public static let web: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        func requires(_ condition: String) -> JSONValue { .object(["requires": .string(condition)]) }
        let pair = ["expectedViewId", "expectedDocumentId"]
        let strictTarget: [String: JSONValue] = ["pane": S.paneID, "tab": S.tabID, "popupId": S.string(minimumLength: 1, maximumUTF8Bytes: 128)]
        let errors = [APIError.unavailable, -32023, -32024, -32025]
        let domSemantics: [String: JSONValue] = ["world": .string("isolatedMainDocumentNotSubframesOrShadowTrees"),
            "maximumPendingActionsPerView": .integer(32), "maximumPendingPlatformSubmissionsPerView": .integer(32),
            "maximumWebKitResultBytesBeforeHostEnrichment": .integer(900_000), "timeoutUndoesSubmittedEffects": .bool(false),
            "selectorRequiresUniqueMatch": .bool(true), "refs": .string("viewAndDocumentBoundWith2048EntryEviction"),
            "defaultTimeoutMilliseconds": .integer(10_000)]
        var methods: [AutomationMethod: AutomationContract] = [:]
        let actions: [(AutomationMethod, AutomationMethod, String)] = [(.webSnapshot, .browserSnapshot, "Snapshot"), (.webClick, .browserClick, "Click"),
            (.webFill, .browserFill, "Fill"), (.webSelect, .browserSelect, "Select"), (.webScroll, .browserScroll, "Scroll"), (.webWait, .browserWait, "Wait")]
        for (webMethod, browserMethod, name) in actions {
            for canonical in [false, true] {
                let method = canonical ? webMethod : browserMethod
                var parameters = canonical ? strictTarget : paneTarget.merging(["popupId": S.string(minimumLength: 1, maximumUTF8Bytes: 128)]) { _, v in v }
                var required = canonical ? ["pane"] : []
                var constraints = canonical ? webIdentityConstraints : targetConstraints
                var semantics = domSemantics
                if name != "Snapshot" {
                    parameters["selector"] = S.string(minimumLength: 1, maximumUTF8Bytes: 2048)
                    parameters["ref"] = canonical ? S.reference("WebElementRef") : S.string(minimumLength: 1, maximumUTF8Bytes: 2048)
                    let targetAlternatives = ["selector", "ref"].map { S.object([:], required: [$0], additional: true) }
                    constraints.append(.object([name == "Scroll" ? "not" : "oneOf": name == "Scroll"
                        ? S.object([:], required: ["selector", "ref"], additional: true) : .array(targetAlternatives)]))
                    if canonical {
                        constraints.append(.object(["x-refIdentityMatchesExpected": .bool(true)]))
                        if name != "Wait" {
                            constraints.append(.object(["if": .object(["not": S.object([:], required: ["ref"], additional: true)]),
                                "then": S.object([:], required: pair, additional: true)]))
                        }
                    }
                }
                switch name {
                case "Snapshot":
                    parameters["maxElements"] = S.defaulted(S.integer(minimum: 1, maximum: 256), .integer(128))
                    semantics["maximumVisitedElements"] = .integer(4000); semantics["maximumVisitedTextNodes"] = .integer(2048)
                    semantics["maximumElementJSONBytes"] = .integer(350_000); semantics["excludesPasswordValues"] = .bool(true)
                    semantics["textClippingUnits"] = .string("utf16CodeUnitsWithoutTrailingHighSurrogate")
                case "Fill": parameters["text"] = S.string(maximumUTF8Bytes: 65_536); required.append("text")
                case "Select": parameters["values"] = S.array(S.string(maximumUTF8Bytes: 4096), maximum: 64); required.append("values")
                case "Scroll":
                    for axis in ["x", "y"] { parameters[axis] = S.defaulted(S.annotated(S.number, ["minimum": .integer(-10_000_000), "maximum": .integer(10_000_000)]), .integer(0)) }
                    semantics["distanceUnits"] = .string("cssPixels"); semantics["noElementTarget"] = .string("scrollWindow")
                case "Wait":
                    parameters["state"] = S.defaulted(S.strings(["attached", "detached", "visible", "hidden"]), .string("visible"))
                    parameters["timeoutMilliseconds"] = S.defaulted(S.integer(minimum: 0, maximum: 10_000), .integer(10_000))
                    semantics["zeroTimeout"] = .string("oneProbeWith10000msPlatformBudgetNotImmediateReturn")
                default: break
                }
                methods[method] = AutomationContract(parameters: parameters, required: required,
                    result: S.reference((canonical ? "Web" : "Browser") + name), guards: targetGuards + (canonical ? pair : []),
                    conditions: [requires(canonical ? "readyRenderableBrowserOrRegisteredPluginPane" : "browserPane")],
                    routing: canonical ? "explicitOrCallerPaneNeverFocus" : "paneOrTabFocus", errors: errors, constraints: constraints, semantics: semantics)
            }
        }
        for (method, name) in [(AutomationMethod.webFocus, "Focus"), (.webKey, "Key"), (.webCheck, "Check"), (.webSetValue, "SetValue")] {
            var parameters = strictTarget.merging(["selector": S.string(minimumLength: 1, maximumUTF8Bytes: 2048),
                "ref": S.reference("WebElementRef")]) { _, v in v }
            var required = ["pane"]
            if method == .webKey { parameters["key"] = S.string(minimumLength: 1, maximumUTF8Bytes: 128, format: "slate-web-key"); required.append("key") }
            if method == .webCheck { parameters["checked"] = S.boolean; required.append("checked") }
            if method == .webSetValue { parameters["value"] = S.string(maximumUTF8Bytes: 4096); required.append("value") }
            let constraints = webIdentityConstraints + [
                .object(["oneOf": .array(["selector", "ref"].map { S.object([:], required: [$0], additional: true) })]),
                .object(["x-refIdentityMatchesExpected": .bool(true)]),
                .object(["if": .object(["not": S.object([:], required: ["ref"], additional: true)]),
                    "then": S.object([:], required: pair, additional: true)])
            ]
            var semantics = domSemantics
            semantics["nativeKeyInjection"] = .bool(false)
            semantics["keyDefaults"] = .string("syntheticKeydownKeyupWithLimitedTabFocusEnterSpaceActivationAndEnterSubmission")
            semantics["check"] = .string("nativeCheckboxOrRadioDesiredStateRadioCannotBeCleared")
            semantics["setValue"] = .string("canonicalValidNumberDateTimeDatetimeLocalOrRangeInputValue")
            semantics["pageHandlersMayRunBeforeReturn"] = .bool(true)
            methods[method] = AutomationContract(parameters: parameters, required: required, result: S.reference("Web" + name),
                guards: targetGuards + pair, conditions: [requires("readyRenderableBrowserOrRegisteredPluginPane"),
                    requires("uniqueConnectedVisibleEnabledElementWithActionSpecificTypeAndState")],
                routing: "explicitOrCallerPaneNeverFocus", errors: errors, constraints: constraints, semantics: semantics)
        }
        methods[.webGet] = AutomationContract(parameters: strictTarget, required: ["pane"], result: S.reference("WebInspection"),
            guards: targetGuards + pair, conditions: [requires("browserOrRegisteredPluginPane"), requires("readyDocumentWhenExpectedIdentitySupplied")],
            routing: "explicitOrCallerPaneNeverFocus", errors: errors, constraints: webIdentityConstraints,
            semantics: ["unreadyWithoutExpectedIdentity": .string("readyFalseAndNullDocumentId"), "urlAndTitleClippingUnits": .string("unicodeScalars"),
                "identityIsCredential": .bool(false), "sampledAtUnits": .string("unixSeconds")])
        for method in [AutomationMethod.webFileChooser, .webChooseFiles, .webCancelFileChooser] {
            var parameters = strictTarget
            var required = ["pane"]
            if method != .webFileChooser {
                parameters["chooserId"] = S.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")
                required.append("chooserId")
            }
            if method == .webChooseFiles {
                parameters["paths"] = S.array(S.string(maximumUTF8Bytes: 4096, pattern: "^/[^\\u0000]*(?![\\s\\S])"), minimum: 1, maximum: 128)
                required.append("paths")
            }
            methods[method] = AutomationContract(parameters: parameters, required: required,
                result: S.reference(method == .webFileChooser ? "WebFileChooser" : "WebFileChooserCompletion"),
                guards: targetGuards + pair, conditions: [requires("browserOrRegisteredPluginPane"),
                    requires(method == .webFileChooser ? "none" : "matchingPendingChooser")],
                routing: "explicitOrCallerPaneNeverFocus", errors: [APIError.unavailable],
                constraints: webIdentityConstraints, semantics: [
                    "chooserIdentity": .string("singleUseBoundToViewAndDocumentLifetime"),
                    "paths": .string("existingReadableLocalFilesOrDirectoriesForDirectoryInputs"),
                    "completion": .string("sameWebKitCallbackAsNativeSheet"),
                    "selectionMayTriggerPageUpload": .bool(true),
                    "navigationAndCloseCancel": .bool(true),
                    "doesNotRequireDOMRenderability": .bool(true)
                ])
        }
        methods[.webScreenshot] = AutomationContract(parameters: strictTarget.merging([
            "path": S.string(maximumUTF8Bytes: 4096, pattern: "^/[^\\u0000]*(?![\\s\\S])")
        ]) { _, value in value }, required: ["pane", "path"], result: S.reference("WebScreenshot"), guards: targetGuards + pair,
            conditions: [requires("readyAttachedLaidOutWebViewportInVisibleNonMinimizedWindowGroup"), requires("unchangedBoundsLayoutAndDocumentBeforeWrite")],
            routing: "explicitOrCallerPaneNeverFocus", errors: errors, constraints: webIdentityConstraints,
            semantics: ["format": .string("png"), "region": .string("viewport"), "inactiveNativeTabAllowed": .bool(true),
                "zoomDetachedPaneAllowed": .bool(false), "changesFocusOrTabSelection": .bool(false), "write": .string("atomicMayReplaceExistingFile"),
                "sampledAtUnits": .string("unixSeconds")])
        for (method, parameters, required, result) in [
            (AutomationMethod.browserGet, [String: JSONValue](), [String](), S.reference("BrowserInspection")),
            (.browserNavigate, ["url": S.string(format: "slate-browser-navigation-url")], ["url"], S.reference("BrowserNavigation")),
            (.browserEval, ["script": S.string()], ["script"], S.any),
            (.browserScreenshot, ["path": S.string()], ["path"], S.reference("BrowserScreenshot"))
        ] {
            var semantics: [String: JSONValue] = ["legacyPermissiveNonGuardParameters": .bool(true)]
            var conditions = [requires("browserPane")]
            if method == .browserNavigate {
                conditions.append(requires("localFileExistsAndIsNotDirectoryWhenFileURL"))
                semantics["urlParsing"] = .string("trimWhitespaceAndAssumeHTTPSNotSearch")
                semantics["timeoutMilliseconds"] = .integer(15_000); semantics["timeoutStopsNavigation"] = .bool(true)
            } else if method == .browserEval {
                semantics["world"] = .string("page"); semantics["maximumWebKitResultBytes"] = .integer(900_000)
                semantics["timeoutMilliseconds"] = .integer(10_000); semantics["timeoutUndoesSubmittedEffects"] = .bool(false)
            } else if method == .browserScreenshot {
                semantics["write"] = .string("atomicMayReplaceExistingFile"); semantics["format"] = .string("png")
                semantics["canonicalWebScreenshotEligibilityAndFinalDocumentCheck"] = .bool(false)
            }
            methods[method] = AutomationContract(parameters: paneTarget.merging(["popupId": S.string(minimumLength: 1, maximumUTF8Bytes: 128)]) { _, v in v }.merging(parameters) { _, value in value }, required: required,
                result: result, guards: targetGuards, additionalParameters: true, conditions: conditions,
                routing: "paneOrTabFocus", errors: errors, constraints: targetConstraints, semantics: semantics)
        }
        methods[.browserListData] = AutomationContract(parameters: [:], result: S.reference("BrowserStoredSites"), guards: unanchoredGuards,
            routing: "applicationPersistentBrowserProfile", semantics: ["includesPrivateOrPluginStores": .bool(false),
                "sites": .string("sortedUniqueWebKitRecordDisplayNames")])
        methods[.browserRemoveSiteData] = AutomationContract(parameters: [
            "site": S.annotated(S.string(minimumLength: 1, maximumUTF8Bytes: 16_384), ["x-noControls": .bool(true)])
        ], required: ["site"], result: S.reference("BrowserClearSite"), guards: unanchoredGuards,
            conditions: [requires("noOtherClearOfSameDataStoreInProgress")], routing: "applicationPersistentBrowserProfile", errors: [-32020],
            semantics: ["selection": .string("exactWebKitRecordDisplayName"), "storage": .string("persistent"),
                "includesPrivateOrPluginStores": .bool(false), "confirmationDialog": .bool(false), "cancellationRollsBackRemoval": .bool(false)])
        methods[.browserClearData] = AutomationContract(parameters: [:], result: S.reference("BrowserClearAll"), guards: unanchoredGuards,
            conditions: [requires("noOtherClearOfSameDataStoreInProgress")], routing: "applicationPersistentBrowserProfile", errors: [-32020],
            semantics: ["includesPrivateOrPluginStores": .bool(false), "confirmationDialog": .bool(false), "cancellationRollsBackRemoval": .bool(false)])
        methods[.browserClearSiteData] = AutomationContract(parameters: ["pane": S.paneID, "tab": S.tabID].merging([
            "url": S.string(maximumUTF8Bytes: 16_384, format: "slate-browser-data-site-url")
        ]) { _, value in value }, required: ["pane", "url"], result: S.reference("BrowserClearSite"), guards: targetGuards,
            conditions: [requires("browserPane"), requires("webKitCanClassifySiteAndNoOtherClearOfSameDataStoreInProgress")],
            routing: "explicitOrCallerBrowserPaneStoreAndExplicitURL", errors: [-32020],
            semantics: ["selection": .string("webKitSiteDataGroupMayIncludeParentAndSiblingDomains"), "noURLOrFocusFallback": .bool(true),
                "includesPluginStores": .bool(false), "confirmationDialog": .bool(false), "cancellationRollsBackRemoval": .bool(false)])
        return methods
    }()
}
