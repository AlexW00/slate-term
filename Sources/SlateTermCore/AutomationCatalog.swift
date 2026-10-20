import Foundation

/// One complete catalog for every trusted adapter. References in descriptors and
/// command rows resolve from `api.describe.contracts`, not from an individual row.
public enum AutomationCatalog {
    public static let version = 1
    public static let contributedCommandKey = "plugin.*"
    static func commandInputDefinitionName(_ key: String) -> String { "CommandInput." + key }

    public static let commands: [String: AutomationContract] = {
        var commands = AutomationContracts.workspaceCommands
        commands.merge(AutomationContracts.applicationCommands) { _, _ in preconditionFailure("Duplicate built-in command contract") }
        precondition(Set(commands.keys) == Set(CommandRegistry.commands.map(\.id)), "Incomplete built-in command catalog")
        commands[contributedCommandKey] = AutomationContracts.contributedCommand
        return commands
    }()

    public static let methods: [AutomationMethod: AutomationContract] = {
        var methods: [AutomationMethod: AutomationContract] = [:]
        for slice in [AutomationContracts.terminal, AutomationContracts.workspace, AutomationContracts.events, AutomationContracts.notifications,
                      AutomationContracts.updates, AutomationContracts.services, AutomationContracts.settings, AutomationContracts.contextual, AutomationContracts.skills,
                      AutomationContracts.plugins, AutomationContracts.pluginPersistence, AutomationContracts.presence, AutomationContracts.savedLayouts, AutomationContracts.web, AutomationContracts.discovery] {
            methods.merge(slice) { _, _ in preconditionFailure("Duplicate method contract") }
        }
        precondition(Set(methods.keys) == Set(AutomationMethod.publicMethods), "Incomplete public method catalog")
        return methods
    }()

    public static let definitions: [String: JSONValue] = {
        var definitions: [String: JSONValue] = [:]
        for slice in [AutomationContracts.workspaceDefinitions, AutomationContracts.eventDefinitions, AutomationContracts.notificationDefinitions,
                      AutomationContracts.updateDefinitions, AutomationContracts.serviceDefinitions, AutomationContracts.settingsDefinitions, AutomationContracts.skillDefinitions,
                      AutomationContracts.pluginDefinitions, AutomationContracts.pluginPersistenceDefinitions, AutomationContracts.presenceDefinitions, AutomationContracts.savedLayoutDefinitions, AutomationContracts.webDefinitions,
                      AutomationContracts.commandDefinitions, AutomationContracts.applicationCommandDefinitions,
                      AutomationContracts.contributedCommandDefinitions, AutomationContracts.discoveryDefinitions] {
            definitions.merge(slice) { _, _ in preconditionFailure("Duplicate schema definition") }
        }
        for (key, command) in commands {
            let previous = definitions.updateValue(command.input, forKey: commandInputDefinitionName(key))
            precondition(previous == nil, "Duplicate command input definition")
        }
        return definitions
    }()

    public static let document: JSONValue = .object([
        "version": .integer(version), "schemaDialect": .string(APISchema.dialect), "$defs": .object(definitions),
        "methods": .object(Dictionary(uniqueKeysWithValues: methods.map { ($0.key.rawValue, $0.value.descriptor(for: $0.key)) })),
        "commands": .object(Dictionary(uniqueKeysWithValues: commands.map { key, command in
            var descriptor = command.descriptor(for: .commandRun).object!
            descriptor["input"] = APISchema.reference(commandInputDefinitionName(key))
            return (key, .object(descriptor))
        })),
        "requestMetadata": APISchema.reference("RequestMetadata"),
        "schemaExtensions": .object(AutomationSchemaVocabulary.extensions.mapValues(JSONValue.string)),
        "formats": .object(AutomationSchemaVocabulary.formats.mapValues(JSONValue.string)),
        "inputStage": .string("afterCallerDefaultsBeforeContextPaneNormalization"),
        "referenceBase": .string("api.describe.contracts"), "hostValidationAuthoritative": .bool(true),
        "legacyCommandContract": .string("pickerAndCallerDefaultHintsNotCompleteInvocationValidation")
    ])

    /// Keep legacy fields and ordering. Full schemas are shared once in the
    /// catalog rather than duplicated for every registered command contribution.
    public static func describeCommand(_ command: WorkspaceCommand) throws -> JSONValue {
        let key: String
        if commands[command.id] != nil { key = command.id }
        else if PluginCommand.isNamespacedID(command.id) { key = contributedCommandKey }
        else { throw RPCFailure(code: APIError.unavailable, message: "No automation contract for command: \(command.id)") }
        var fields = try JSONValue.encoding(command).object!
        fields["contractRef"] = .string("#/commands/" + key)
        return .object(fields)
    }

    public static func runtimeAvailability(layoutApp: Bool) -> JSONValue {
        let parentRequirement = JSONValue.object(["requires": .string("standardSlateRuntime")])
        return .object(Dictionary(uniqueKeysWithValues: AutomationMethod.publicMethods.map { method in
            let parentOnly = methods[method]?.availability.array?.contains(parentRequirement) == true
            let childOnly = method == .configResetOverrides || method == .updatesOpenParent || method == .layoutsRestoreOriginal
            return (method.rawValue, JSONValue.bool(childOnly ? layoutApp : !(layoutApp && parentOnly)))
        }))
    }

    public static func describe(instanceID: String, commands: [WorkspaceCommand]) throws -> JSONValue {
        var fields = AutomationCapabilities.fields
        fields["appInstanceId"] = .string(instanceID)
        fields["mode"] = .string("standard")
        fields["layoutAppID"] = .null
        fields["runtimeAvailability"] = runtimeAvailability(layoutApp: false)
        fields["commands"] = .array(try commands.map(describeCommand))
        fields["contracts"] = document
        return .object(fields)
    }
}
