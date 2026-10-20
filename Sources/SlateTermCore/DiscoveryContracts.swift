import Foundation

extension AutomationContracts {
    public static let discoveryDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        func complete(_ fields: [String: JSONValue]) -> JSONValue { S.object(fields, required: Array(fields.keys)) }
        let builtinIDs = CommandRegistry.commands.map(\.id)
        let commandID = S.oneOf([S.strings(builtinIDs), contributedCommandID])
        let commandReferences = builtinIDs.map { "#/commands/" + $0 } + ["#/commands/" + AutomationCatalog.contributedCommandKey]
        var definitions: [String: JSONValue] = [
            "JSONSchema": S.oneOf([S.boolean, S.record(S.any)]),
            "LegacyCommandHints": complete(["requiresArguments": S.boolean, "workspaceIndependent": S.boolean,
                "parameters": S.record(S.string()), "required": S.array(S.string()), "additionalParameters": S.boolean,
                "retry": S.constant(.string("never-automatic"))]),
            "CommandDescription": complete(["id": commandID, "title": S.string(), "key": S.string(), "shift": S.boolean,
                "alt": S.boolean, "control": S.boolean, "contract": S.reference("LegacyCommandHints"), "contractRef": S.strings(commandReferences)]),
            "AutomationContract": complete(["input": S.reference("JSONSchema"), "result": S.reference("JSONSchema"),
                "guards": S.array(S.strings(APIGuards.names.sorted())), "errors": S.array(S.integer()),
                "availability": S.array(S.record(S.any)), "routing": S.string(),
                "admission": S.strings(["read", "mutation", "emergencyControl", "authenticatedIntegration"]),
                "retry": S.constant(.string("never-automatic")), "semantics": S.record(S.any)])
        ]
        let methods = Dictionary(uniqueKeysWithValues: AutomationMethod.publicMethods.map { ($0.rawValue, S.reference("AutomationContract")) })
        let commands = Dictionary(uniqueKeysWithValues: (builtinIDs + [AutomationCatalog.contributedCommandKey]).map { ($0, S.reference("AutomationContract")) })
        definitions["AutomationCatalog"] = complete([
            "version": S.constant(.integer(AutomationCatalog.version)), "schemaDialect": S.constant(.string(S.dialect)),
            "$defs": S.record(S.reference("JSONSchema")), "methods": complete(methods), "commands": complete(commands),
            "requestMetadata": S.reference("JSONSchema"),
            "schemaExtensions": S.record(S.string()), "formats": S.record(S.string()),
            "inputStage": S.constant(.string("afterCallerDefaultsBeforeContextPaneNormalization")),
            "referenceBase": S.constant(.string("api.describe.contracts")), "hostValidationAuthoritative": S.constant(.bool(true)),
            "legacyCommandContract": S.constant(.string("pickerAndCallerDefaultHintsNotCompleteInvocationValidation"))
        ])
        definitions["CommandList"] = S.array(S.reference("CommandDescription"), maximum: builtinIDs.count + 64 * 32)
        var description = AutomationCapabilities.fields.mapValues(S.constant)
        description["appInstanceId"] = S.uuid
        description["mode"] = S.strings(["standard", "layoutApp"])
        description["layoutAppID"] = S.nullable(S.uuid)
        description["runtimeAvailability"] = S.record(S.boolean)
        description["commands"] = S.reference("CommandList")
        description["contracts"] = S.reference("AutomationCatalog")
        definitions["APIDescription"] = complete(description)
        return definitions
    }()

    public static let discovery: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        var results: [JSONValue] = []
        var inputs: [JSONValue] = []
        var errors: Set<Int> = [-32601]
        var guards: Set<String> = []
        for key in AutomationCatalog.commands.keys.sorted() {
            let contract = AutomationCatalog.commands[key]!
            inputs.append(S.reference(AutomationCatalog.commandInputDefinitionName(key)))
            if !results.contains(contract.result) { results.append(contract.result) }
            errors.formUnion(contract.errors); guards.formUnion(contract.guards)
        }
        let fits = JSONValue.object(["requires": .string("unpaginatedDiscoveryResponseFitsTransportEnvelope")])
        return [
            .describe: AutomationContract(parameters: paneTarget, result: S.reference("APIDescription"), guards: targetGuards,
                additionalParameters: true, conditions: [fits], constraints: targetConstraints,
                semantics: ["catalogIsCompleteForPublicMethodsAndBuiltinCommands": .bool(true), "contributedCommandsUseSharedTemplate": .bool(true),
                    "contractReferencesResolveFrom": .string("contracts"), "discoveryGuaranteesCurrentResourceAvailability": .bool(false),
                    "transportLimitsStillApply": .bool(true)]),
            .commandList: AutomationContract(parameters: paneTarget, result: S.reference("CommandList"), guards: targetGuards,
                additionalParameters: true, conditions: [fits], constraints: targetConstraints,
                semantics: ["includes": .string("allBuiltinsAndActiveCompatiblePluginContributions"),
                    "notFilteredByCurrentNativeAvailability": .bool(true), "contractReferencesResolveFrom": .string("api.describe.contracts")]),
            .commandRun: AutomationContract(parameters: ["id": S.string()], required: ["id"],
                result: S.annotated(S.any, ["anyOf": .array(results)]), guards: guards.sorted(),
                additionalParameters: true, additionalExpectedArguments: true,
                conditions: [.object(["requires": .string("selectedCommandContractAvailability")])], routing: "commandIDThenCommandSpecificRouting",
                errors: errors.sorted(), constraints: [.object(["oneOf": .array(inputs)])],
                semantics: ["inputAndResultContractSelection": .string("contracts.commands[id]OrPluginWildcardForContributedID"),
                    "callerDefaults": .string("legacyWorkspaceIndependentHintThenCommandSpecificValidation"),
                    "nativeDialogsMayRequireHumanInteraction": .bool(true), "nativeAndAPIConfirmationDiffer": .bool(true),
                    "correlationIDsAreIdempotencyKeys": .bool(false)])
        ]
    }()
}
