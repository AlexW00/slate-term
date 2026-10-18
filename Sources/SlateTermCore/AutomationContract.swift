import Foundation

/// Describes shared dispatch, not a client-specific permission or a runtime
/// availability guarantee. Input schemas apply after caller defaults are resolved.
public struct AutomationContract: Sendable {
    public let input: JSONValue
    public let result: JSONValue
    public let guards: [String]
    public let errors: [Int]
    public let availability: JSONValue
    public let routing: String
    public let semantics: [String: JSONValue]

    public init(parameters: [String: JSONValue], required: [String] = [], result: JSONValue,
                guards: [String] = [], additionalParameters: Bool = false, additionalExpectedArguments: Bool = false,
                conditions: [JSONValue] = [], routing: String = "none", errors: [Int] = [],
                constraints: [JSONValue] = [], semantics: [String: JSONValue] = [:]) {
        precondition(Set(guards).isSubset(of: APIGuards.names))
        var fields = parameters
        for guardName in guards { fields[guardName] = APISchema.revision }
        var input = APISchema.object(fields, required: required, additional: additionalParameters)
        if additionalParameters {
            let names: JSONValue
            if additionalExpectedArguments {
                // Contributed command arguments may start with expected, but
                // recognized unsupported host guards still fail closed.
                names = .object(["not": APISchema.strings(APIGuards.names.subtracting(guards).sorted())])
            } else {
                names = .object(["anyOf": .array([
                    .object(["not": .object(["pattern": .string("^expected")])]),
                    .object(["enum": .array(guards.map(JSONValue.string))])
                ])])
            }
            input = APISchema.annotated(input, ["propertyNames": names])
        }
        var requirements = constraints
        if guards.contains("expectedAnchorSessionId") {
            requirements.append(.object([
                "if": .object(["required": .array([.string("expectedAnchorSessionId")])]),
                "then": APISchema.object(["pane": APISchema.paneID], required: ["pane"], additional: true)
            ]))
        }
        if !requirements.isEmpty { input = APISchema.annotated(input, ["allOf": .array(requirements)]) }
        self.input = input; self.result = result
        self.guards = guards.sorted()
        // Shared decoding/dispatch may reject malformed request metadata (-32600),
        // reconciliation, caller retirement, arguments or causation even for reads.
        self.errors = Set(errors + [-32600, -32602, -32022, APIError.conflict, -32055, -32056, -32058, APIError.serviceSessionUnavailable]).sorted()
        self.availability = .array(conditions)
        self.routing = routing; self.semantics = semantics
    }

    public func descriptor(for method: AutomationMethod) -> JSONValue {
        let admission: String
        switch method.admission {
        case .read: admission = "read"
        case .mutation: admission = "mutation"
        case .emergencyControl: admission = "emergencyControl"
        case .authenticatedIntegration: admission = "authenticatedIntegration"
        }
        let codes = method.admission == .mutation ? Set(errors + [-32057]).sorted() : errors
        return .object(["input": input, "result": result,
            "guards": .array(guards.map(JSONValue.string)), "errors": .array(codes.map(JSONValue.integer)),
            "availability": availability, "routing": .string(routing), "admission": .string(admission),
            "retry": .string("never-automatic"), "semantics": .object(semantics)])
    }
}

/// Catalog slices are assembled only after their inputs and results are described;
/// integration/debug methods do not belong in public discovery.
public enum AutomationContracts {
    static let targetGuards = ["expectedInstanceId", "expectedAnchorSessionId", "expectedWorkspaceRevision", "expectedLayoutRevision"]
    static let paneTarget: [String: JSONValue] = ["pane": APISchema.paneID, "tab": APISchema.tabID, "contextPane": APISchema.paneID]
    static let targetConstraints: [JSONValue] = [
        .object(["if": .object(["required": .array([.string("contextPane")])]),
                 "then": .object(["not": .object(["anyOf": .array([
                    .object(["required": .array([.string("pane")])]), .object(["required": .array([.string("tab")])])
                 ])])])])
    ]
}
