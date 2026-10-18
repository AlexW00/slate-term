import Foundation

extension AutomationContracts {
    static let unanchoredGuards = targetGuards.filter { $0 != "expectedAnchorSessionId" }
    static let serviceSelector: [String: JSONValue] = [
        "serviceId": APISchema.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])"),
        "generation": APISchema.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[A-Za-z0-9_-]+(?![\\s\\S])")
    ]
    static let eventIdentity = APISchema.annotated(APISchema.string(minimumLength: 1), ["x-noWhitespaceOrControls": .bool(true)])
    static let eventTopic = APISchema.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[a-z][a-z0-9_-]*(\\.[a-z][a-z0-9_-]*)*(?![\\s\\S])")
    static let eventCursor = APISchema.string(minimumLength: 38, maximumUTF8Bytes: 57, format: "slate-event-cursor")

    public static let eventDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        func complete(_ fields: [String: JSONValue]) -> JSONValue { S.object(fields, required: Array(fields.keys)) }
        let recipient = complete(serviceSelector)
        let source = S.oneOf([
            complete(["kind": S.strings(["host", "client"])]),
            complete(["kind": S.constant(.string("plugin")), "type": eventIdentity, "instanceId": eventIdentity]),
            complete(serviceSelector.merging(["kind": S.constant(.string("service")), "pluginId": eventIdentity]) { _, value in value })
        ])
        return [
            "ServiceRecipient": recipient,
            "EventRecipient": S.oneOf([S.constant(.string("all")), complete(["instanceId": eventIdentity]), recipient]),
            "WorkspaceEvent": S.object([
                "cursor": eventCursor, "sequence": S.integer(minimum: 1), "topic": eventTopic,
                "timestampMillis": S.integer(), "source": source, "tab": S.tabID, "pane": S.paneID,
                "targetInstanceId": eventIdentity, "targetService": recipient, "payload": S.any,
                "deliveryContext": S.string(minimumLength: 1)
            ], required: ["cursor", "sequence", "topic", "timestampMillis", "source", "payload"]),
            "EventBatch": complete(["cursor": eventCursor, "events": S.array(S.reference("WorkspaceEvent"), maximum: EventJournal.maximumBatchEvents)])
        ]
    }()

    public static let events: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        let topicFilter = S.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[a-z][a-z0-9_-]*(\\.[a-z][a-z0-9_-]*)*(\\.\\*)?(?![\\s\\S])")
        let topic = S.annotated(eventTopic, ["not": .object(["pattern": .string("^host\\.")])])
        return [
            .eventsHead: AutomationContract(parameters: [:], result: S.object([
                "cursor": eventCursor, "pendingPolls": S.integer(minimum: 0, maximum: 128)
            ], required: ["cursor", "pendingPolls"]), guards: unanchoredGuards),
            .eventsPoll: AutomationContract(parameters: paneTarget.merging([
                "after": eventCursor, "topics": S.defaulted(S.array(topicFilter, maximum: 64), .array([])),
                "scope": S.strings(["global", "tab"]), "recipient": S.reference("EventRecipient"),
                "limit": S.defaulted(S.integer(minimum: 1, maximum: EventJournal.maximumBatchEvents), .integer(128)),
                "waitMilliseconds": S.defaulted(S.integer(minimum: 0, maximum: 25_000), .integer(20_000))
            ]) { _, value in value }, result: S.reference("EventBatch"), guards: targetGuards,
                conditions: [.object(["requires": .string("explicitTabOrCallerTabOnlyWhenPaneIsAbsent"),
                    "when": S.object(["scope": S.constant(.string("tab"))], required: ["scope"], additional: true)])],
                routing: "eventFilter", errors: [-32031, -32032], constraints: targetConstraints + [.object([
                    "if": S.object(["scope": S.constant(.string("tab"))], required: ["scope", "pane"], additional: true),
                    "then": .object(["required": .array([.string("tab")])])
                ])],
                semantics: ["afterOmitted": .string("currentHeadNotReplay"), "waitExpiry": .string("successfulPossiblyEmptyBatch"),
                    "defaultScope": .string("callerTabWhenBoundOtherwiseGlobal"), "defaultRecipient": .string("callerOrAllForAdministrative"),
                    "cursorIncludesScannedNonmatches": .bool(true), "maximumResultBytes": .integer(EventJournal.maximumBatchBytes),
                    "persistent": .bool(false), "maximumPendingPolls": .integer(128)]),
            .eventsEmit: AutomationContract(parameters: paneTarget.merging([
                "topic": topic, "payload": S.defaulted(S.any, .null), "targetInstanceId": eventIdentity,
                "targetService": S.reference("ServiceRecipient")
            ]) { _, value in value }, required: ["topic"], result: S.reference("WorkspaceEvent"), guards: targetGuards,
                conditions: [.object(["requires": .string("liveDirectedRecipientWhenSupplied")])], routing: "eventPublication",
                constraints: targetConstraints + [.object(["not": .object(["required": .array([.string("targetInstanceId"), .string("targetService")])])])],
                semantics: ["source": .string("hostStampedCaller"), "defaultScope": .string("callerUnlessExplicitTarget"),
                    "maximumEncodedEventBytes": .integer(EventJournal.maximumEventBytes),
                    "reservedDeliveryMetadataBytes": .integer(EventJournal.maximumDeliveryMetadataBytes),
                    "payloadLimitIncludesEnvelope": .bool(true), "persistent": .bool(false)])
        ]
    }()
}
