import Foundation

extension AutomationContracts {
    public static let notificationDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        func complete(_ fields: [String: JSONValue]) -> JSONValue { S.object(fields, required: Array(fields.keys)) }
        let origin = S.oneOf([
            complete(["kind": S.strings(["native", "administrative"])]),
            complete(["kind": S.constant(.string("plugin")), "pluginId": S.string(), "instanceId": S.string(), "viewId": S.string()]),
            complete(serviceSelector.merging(["kind": S.constant(.string("service")), "pluginId": S.string()]) { _, value in value })
        ])
        let source = S.oneOf([origin, complete(["kind": S.constant(.string("terminal")), "protocol": S.strings(["OSC", "commandFinished"])])])
        return [
            "OperationOrigin": origin,
            "NotificationPolicy": complete([
                "automatic": S.boolean, "minimum_seconds": S.integer(minimum: 1, maximum: 86_400),
                "tools": S.boolean, "banners": S.strings(NotificationPolicy.Banner.allCases.map(\.rawValue)),
                "sound": S.boolean, "command_details": S.boolean
            ]),
            "Notification": S.object([
                "id": S.string(), "title": S.string(minimumLength: 1, maximumUTF8Bytes: NotificationStore.titleBytes),
                "body": S.string(maximumUTF8Bytes: NotificationStore.bodyBytes), "key": S.string(minimumLength: 1, maximumUTF8Bytes: NotificationStore.keyBytes),
                "source": source, "anchor": S.object(["paneId": S.paneID, "tabId": S.nullable(S.tabID), "lifetime": S.string()]),
                "automatic": S.boolean, "createdAt": S.number, "disposition": S.strings(["submitted", "suppressed", "failed"]), "reason": S.string()
            ], required: ["id", "title", "body", "source", "anchor", "automatic", "createdAt", "disposition"]),
            "Welcome": complete([
                "content": complete(["title": S.string(), "paragraphs": S.array(S.string())]),
                "acknowledged": S.nullable(S.boolean), "automaticDisplayEnabled": S.boolean,
                "revision": S.revision, "error": S.nullable(S.string())
            ])
        ]
    }()

    public static let notifications: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        let title = S.annotated(S.string(minimumLength: 1, maximumUTF8Bytes: NotificationStore.titleBytes),
            ["x-nonemptyAfterNotificationSanitization": .bool(true)])
        let key = S.annotated(S.string(minimumLength: 1, maximumUTF8Bytes: NotificationStore.keyBytes), ["x-noControls": .bool(true)])
        return [
            .notificationsPost: AutomationContract(parameters: paneTarget.merging([
                "title": title, "body": S.defaulted(S.string(maximumUTF8Bytes: NotificationStore.bodyBytes), .string("")),
                "key": key, "active": S.constant(.bool(true))
            ]) { _, value in value }, required: ["title"], result: S.object([
                "id": S.nullable(S.string()), "disposition": S.strings(["submitted", "suppressed"]),
                "reason": S.nullable(S.string()), "retained": S.boolean
            ], required: ["id", "disposition", "reason", "retained"]), guards: targetGuards,
                conditions: [.object(["requires": .string("liveNotificationAnchorWhenTargeted")])], routing: "notificationAnchor",
                errors: [APIError.unavailable], constraints: targetConstraints + [.object([
                    "if": .object(["required": .array([.string("active")])]),
                    "then": .object(["not": .object(["anyOf": .array(["pane", "tab", "contextPane"].map {
                        .object(["required": .array([.string($0)])])
                    })])])
                ])], semantics: ["submissionIsDelivery": .bool(false), "maySuppressWithoutError": .bool(true),
                    "permissionPromptOnPost": .bool(false), "persistent": .bool(false),
                    "replacementKeyScope": .string("sourceAndAnchorLifetime"), "defaultAnchor": .string("callerOrApplication")]),
            .notificationsList: AutomationContract(parameters: [:], result: S.array(S.reference("Notification"), maximum: NotificationStore.capacity),
                guards: unanchoredGuards, semantics: ["order": .string("oldestFirst"), "refreshMayRemoveFocusedOrDeadSources": .bool(true)]),
            .notificationsDismiss: AutomationContract(parameters: ["id": S.string(), "all": S.constant(.bool(true))],
                result: S.object(["dismissed": S.array(S.string(), maximum: NotificationStore.capacity)], required: ["dismissed"]), guards: unanchoredGuards,
                constraints: [.object(["oneOf": .array([
                    .object(["required": .array([.string("id")]), "not": .object(["required": .array([.string("all")])])]),
                    .object(["required": .array([.string("all")]), "not": .object(["required": .array([.string("id")])])])
                ])])]),
            .notificationsStatus: AutomationContract(parameters: [:], result: S.object([
                "authorization": S.strings(["authorized", "denied", "notDetermined", "unavailable"]), "policy": S.reference("NotificationPolicy"),
                "outstanding": S.integer(minimum: 0, maximum: NotificationStore.capacity), "capacity": S.constant(.integer(NotificationStore.capacity)),
                "deliveryBackend": S.strings(["test", "macOS"]), "persistent": S.constant(.bool(false))
            ], required: ["authorization", "policy", "outstanding", "capacity", "deliveryBackend", "persistent"]), guards: unanchoredGuards),
            .welcomeGet: AutomationContract(parameters: [:], result: S.reference("Welcome"), guards: ["expectedInstanceId"],
                semantics: ["acknowledges": .bool(false), "scope": .string("appStateDirectory")])
        ]
    }()
}
