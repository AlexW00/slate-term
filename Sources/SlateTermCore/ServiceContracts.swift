import Foundation

extension AutomationContracts {
    public static let serviceDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        let fields: [String: JSONValue] = [
            "pluginId": S.string(), "serviceId": serviceSelector["serviceId"]!,
            "generation": S.nullable(serviceSelector["generation"]!),
            "state": S.strings(["stopped", "starting", "ready", "stopping", "failed"]),
            "reason": S.strings(["notStarted", "start", "ready", "stop", "registrationRemoved", "startFailed", "readinessTimeout", "processExit", "cleanupUnconfirmed"]),
            "mode": S.constant(.string("manual")), "pid": S.nullable(S.integer(minimum: 1, maximum: Int(Int32.max))),
            "cleanupConfirmed": S.boolean, "reservationHeld": S.boolean
        ]
        return ["ServiceStatus": S.object(fields.merging(["superseded": S.boolean]) { _, value in value }, required: Array(fields.keys))]
    }()

    public static let services: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        var methods: [AutomationMethod: AutomationContract] = [:]
        for method in [AutomationMethod.serviceStart, .serviceStop, .serviceList, .serviceStatus, .serviceLogs] {
            let list = method == .serviceList
            let logs = method == .serviceLogs
            methods[method] = AutomationContract(parameters: list ? [:] : ["id": S.string(minimumLength: 1)],
                required: list ? [] : ["id"], result: list ? S.array(S.reference("ServiceStatus"))
                    : logs ? S.object(["stdout": S.string(), "stderr": S.string()], required: ["stdout", "stderr"]) : S.reference("ServiceStatus"),
                guards: ["expectedInstanceId"], conditions: list ? [] : [.object(["requires": .string("registeredBackgroundService")])],
                routing: list ? "none" : "pluginID", errors: method == .serviceStart ? [APIError.unavailable, APIError.incompatible] : [],
                semantics: logs ? ["rawTailBytesPerStream": .integer(65_536), "decoding": .string("utf8ReplacingInvalidBytes")]
                    : ["activation": .string("manual"), "automaticRestart": .bool(false), "maximumReservations": .integer(16),
                       "startResult": .string("observedAcceptanceNotReadiness"), "acceptedLifecycleWorkOwner": .string("host")])
        }
        methods[.serviceReady] = AutomationContract(parameters: serviceSelector.merging(["version": S.constant(.integer(1))]) { _, value in value },
            required: ["version"], result: S.object(serviceSelector.merging([
                "version": S.constant(.integer(1)), "state": S.constant(.string("ready"))
            ]) { _, value in value }, required: ["version", "serviceId", "generation", "state"]),
            guards: unanchoredGuards, conditions: [.object(["requires": .string("explicitOrBoundLiveServiceGeneration")])],
            routing: "serviceGeneration", constraints: [.object(["oneOf": .array([
                .object(["required": .array([.string("serviceId"), .string("generation")])]),
                .object(["not": .object(["anyOf": .array([
                    .object(["required": .array([.string("serviceId")])]), .object(["required": .array([.string("generation")])])
                ])])])
            ])])], semantics: ["omittedSelector": .string("boundServiceOwnerRequired"), "selectorIsCredential": .bool(false)])
        return methods
    }()
}
