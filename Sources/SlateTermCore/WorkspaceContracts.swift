import Foundation

extension AutomationContracts {
    public static let workspaceDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        func complete(_ fields: [String: JSONValue]) -> JSONValue { S.object(fields, required: Array(fields.keys)) }
        let shortTitle = S.annotated(S.string(), ["x-maxGraphemeCount": .integer(512)])
        let path = S.array(S.strings(["first", "second"]))
        let frame: [String: JSONValue] = ["x": S.number, "y": S.number, "width": S.number, "height": S.number]
        let geometry = complete(frame.merging([
            "coordinateSpace": S.constant(.string("tab-content-top-left-points")), "layoutRevision": S.revision
        ]) { _, value in value })
        let paneFields: [String: JSONValue] = [
            "paneId": S.paneID, "type": S.string(), "tabId": S.tabID, "groupId": S.nullable(S.groupID),
            "headerVisible": S.boolean, "unreadNotificationCount": S.integer(minimum: 0),
            "manualTitle": S.nullable(shortTitle), "manualTitleTruncated": S.boolean,
            "windowId": S.nullable(S.string()), "path": S.nullable(path), "title": shortTitle,
            "visible": S.boolean, "geometry": S.nullable(geometry), "geometryState": S.strings(["unavailable", "sampled"]),
            "layoutRevision": S.revision, "sampledAt": S.number,
            "neighbors": complete(Dictionary(uniqueKeysWithValues: Direction.allCases.map { ($0.rawValue, S.nullable(S.paneID)) })),
            "contentOperations": S.array(S.string())
        ]
        let paneOptional: [String: JSONValue] = [
            "sessionId": S.string(), "state": S.string(), "pluginInstanceId": S.string(), "viewId": S.string(),
            "documentId": S.nullable(S.string()), "webReady": S.boolean,
            "pluginPanelId": S.uuid, "pluginStateRevision": S.uuid,
            "shell": S.nullable(S.strings(ShellKind.allCases.map(\.rawValue))), "runAvailable": S.nullable(S.boolean)
        ]
        let contextTerminal = complete([
            "paneId": S.paneID, "sessionId": S.nullable(S.string()),
            "pid": S.nullable(S.integer(minimum: 1, maximum: Int(Int32.max))), "title": S.nullable(S.string()),
            "workingDirectory": S.nullable(S.string()), "state": S.strings(["unknown", "prompt", "running"]),
            "isAtPrompt": S.nullable(S.boolean), "command": S.nullable(S.string(maximumUTF8Bytes: 16_384)),
            "exitCode": S.nullable(S.exitCode), "sequence": S.integer(minimum: 0),
            "shell": S.nullable(S.strings(ShellKind.allCases.map(\.rawValue))), "runAvailable": S.nullable(S.boolean)
        ])
        let legacyPaneType = S.oneOf(["terminal", "browser", "privateBrowser"].map { complete([$0: S.emptyObject]) }
            + [complete(["registered": complete(["_0": S.string()])])])
        return [
            "Layout": S.oneOf([
                complete(["kind": S.constant(.string("pane")), "pane": S.paneID]),
                complete(["kind": S.constant(.string("split")), "axis": S.strings(["horizontal", "vertical"]),
                    "fraction": S.annotated(S.number, ["exclusiveMinimum": .integer(0), "exclusiveMaximum": .integer(1)]),
                    "first": S.reference("Layout"), "second": S.reference("Layout")])
            ]),
            "Pane": S.object(["id": S.paneID, "type": legacyPaneType, "manualTitle": S.string(), "headerVisible": S.boolean],
                required: ["id", "type", "headerVisible"]),
            "Tab": S.object(["id": S.tabID, "manualTitle": S.string(maximumUTF8Bytes: 1_024), "layout": S.reference("Layout"),
                "focusedPane": S.paneID, "zoomedPane": S.paneID, "terminalHistory": S.array(S.paneID)],
                required: ["id", "layout", "focusedPane", "terminalHistory"]),
            "TabGroup": complete(["id": S.groupID, "tabs": S.array(S.tabID, minimum: 1)]),
            "Workspace": S.object(["schemaVersion": S.constant(.integer(2)), "panes": S.array(S.reference("Pane")),
                "tabs": S.array(S.reference("Tab")), "groups": S.array(S.reference("TabGroup")), "keyTabID": S.tabID,
                "nextPane": S.integer(minimum: 1), "nextTab": S.integer(minimum: 1), "nextGroup": S.integer(minimum: 1)],
                required: ["schemaVersion", "panes", "tabs", "groups", "nextPane", "nextTab", "nextGroup"]),
            "PaneInspection": S.object(paneFields.merging(paneOptional) { _, value in value }, required: Array(paneFields.keys)),
            "Context": complete(["mode": S.strings(["standard", "layoutApp"]), "layoutAppID": S.nullable(S.uuid), "instanceId": S.string(), "scope": S.strings(["pane", "tab", "global"]), "tabId": S.tabID,
                "focusedPaneId": S.paneID, "activeTerminalPaneId": S.nullable(S.paneID), "terminal": S.nullable(contextTerminal)]),
            "ContextInspection": complete([
                "caller": S.object(["appInstanceId": S.string(), "identitySource": S.strings(["none", "supplied", "bridgeBound"]),
                    "paneId": S.paneID, "sessionId": S.nullable(S.string()), "tabId": S.tabID, "groupId": S.groupID,
                    "pluginId": S.string(), "pluginInstanceId": S.string(), "viewId": S.string()], required: ["appInstanceId", "identitySource"]),
                "target": S.nullable(S.reference("PaneInspection")), "focusedPaneId": S.nullable(S.paneID),
                "activeTerminalPaneId": S.nullable(S.paneID), "workspaceRevision": S.revision
            ]),
            "WorkspaceSnapshot": complete([
                "appInstanceId": S.string(), "workspaceRevision": S.revision, "eventCursor": S.string(),
                "nextCursor": S.nullable(S.string()), "sampledAt": S.number, "totalPanes": S.integer(minimum: 0),
                "scope": S.string(pattern: "^(global|pane:p[1-9][0-9]*|tab:t[1-9][0-9]*)(?![\\s\\S])"),
                "groups": S.array(S.reference("TabGroup")), "panes": S.array(S.reference("PaneInspection"), maximum: 64),
                "tabs": S.array(complete(["id": S.tabID, "focusedPaneId": S.paneID, "manualTitle": S.nullable(S.string()),
                    "title": S.string(), "unreadNotificationCount": S.integer(minimum: 0),
                    "layoutRevision": S.revision, "layout": S.reference("Layout")]))
            ]),
            "NativeWindow": complete([
                "windowId": S.string(), "tabId": S.tabID, "title": S.string(), "groupId": S.nullable(S.groupID),
                "nativeWindowNumber": S.integer(), "visible": S.boolean, "selected": S.boolean, "key": S.boolean,
                "minimized": S.boolean, "fullscreen": S.boolean, "screenName": S.nullable(shortTitle),
                "presentationRevision": S.uuid, "fullscreenTransition": S.strings(["idle", "entering", "exiting", "failed"]),
                "fullscreenTransitionPending": S.boolean, "visibleScreenFrame": S.nullable(complete(frame)),
                "frame": complete(frame.merging(["coordinateSpace": S.constant(.string("screen-global-bottom-left-points"))]) { _, value in value })
            ]),
            "WindowPage": complete([
                "appInstanceId": S.string(), "workspaceRevision": S.revision, "eventCursor": S.string(),
                "nextCursor": S.nullable(S.string()), "totalWindows": S.integer(minimum: 0), "sampledAt": S.number,
                "windows": S.array(S.reference("NativeWindow"), maximum: 64)
            ])
        ]
    }()

    public static let workspace: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        let pagination: [String: JSONValue] = ["limit": S.defaulted(S.integer(minimum: 1, maximum: 64), .integer(32)),
            "cursor": S.string(maximumUTF8Bytes: 4_096)]
        let pageSemantics: [String: JSONValue] = ["maximumResultBytes": .integer(262_144), "cursorInvalidatedByWorkspaceChange": .bool(true)]
        func legacy(_ result: JSONValue) -> AutomationContract {
            AutomationContract(parameters: [:], result: result, guards: targetGuards, additionalParameters: true,
                semantics: ["unknownNonGuardParameters": .string("ignored")])
        }
        var methods: [AutomationMethod: AutomationContract] = [
            .version: legacy(S.object(["cliVersion": S.string(), "appVersion": S.string(), "protocolVersion": S.constant(.integer(1))],
                required: ["cliVersion", "appVersion", "protocolVersion"])),
            .workspaceGet: legacy(S.reference("Workspace")),
            .panesList: legacy(S.array(S.reference("Pane"))),
            .tabsList: legacy(S.array(S.reference("Tab"))),
            .layoutGet: AutomationContract(parameters: paneTarget, result: S.reference("Layout"), guards: targetGuards,
                additionalParameters: true, conditions: [.object(["requires": .string("liveTab")])], routing: "paneOrTabFocus", constraints: targetConstraints),
            .paneInspect: AutomationContract(parameters: paneTarget, result: S.reference("PaneInspection"), guards: targetGuards,
                additionalParameters: true, conditions: [.object(["requires": .string("livePane")])], routing: "paneOrTabFocus", constraints: targetConstraints),
            .contextGet: AutomationContract(parameters: paneTarget.merging([
                "scope": S.defaulted(S.strings(["pane", "tab", "global"]), .string("tab"))
            ]) { _, value in value }, result: S.reference("Context"), guards: targetGuards, additionalParameters: true,
                conditions: [.object(["requires": .string("liveTab")])], routing: "contextScope", constraints: targetConstraints),
            .contextInspect: AutomationContract(parameters: paneTarget, result: S.reference("ContextInspection"), guards: targetGuards,
                additionalParameters: true, routing: "optionalPaneOrTabFocus", constraints: targetConstraints),
            .windowList: AutomationContract(parameters: pagination, result: S.reference("WindowPage"),
                guards: ["expectedInstanceId", "expectedWorkspaceRevision"], errors: [APIError.unavailable], semantics: pageSemantics),
            .windowGet: AutomationContract(parameters: ["windowId": S.string()], required: ["windowId"], result: S.reference("NativeWindow"),
                guards: ["expectedInstanceId", "expectedWorkspaceRevision"], conditions: [.object(["requires": .string("liveNativeWindow")])],
                routing: "nativeWindowID", errors: [APIError.unavailable])
        ]
        methods[.workspaceSnapshot] = AutomationContract(parameters: paneTarget.merging(pagination) { _, value in value }.merging([
            "scope": S.defaulted(S.strings(["pane", "tab", "global"]), .string("global"))
        ]) { _, value in value }, result: S.reference("WorkspaceSnapshot"), guards: targetGuards, additionalParameters: true,
            conditions: [.object(["requires": .string("livePane"), "when": .object(["properties": .object([
                "scope": S.strings(["pane", "tab"])
            ]), "required": .array([.string("scope")])])])], routing: "snapshotScope", errors: [APIError.unavailable],
            constraints: targetConstraints, semantics: pageSemantics)
        return methods
    }()
}
