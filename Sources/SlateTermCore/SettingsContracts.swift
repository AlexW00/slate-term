import Foundation

extension AutomationContracts {
    static let pluginNamespace = APISchema.string(maximumUTF8Bytes: 64, pattern: "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*(?![\\s\\S])")
    static let paletteName = APISchema.string(minimumLength: 1, maximumUTF8Bytes: 128, format: "slate-palette-name")
    static let configurationRestartKeys = APISchema.array(APISchema.strings([
        "terminal.shell", "terminal.shell_integration", "terminal.padding_x", "terminal.padding_y"
    ]))

    static let terminalConfigurationFields: [String: JSONValue] = {
        typealias S = APISchema
        return [
            "shell": S.string(pattern: "^/", format: "slate-shell-path"),
            "font_family": S.string(minimumLength: 1, format: "slate-configuration-line"),
            "font_size": S.annotated(S.number, ["minimum": .integer(1), "maximum": .integer(256)]),
            "shell_integration": S.strings(["auto", "off"]), "font_thicken": S.boolean,
            "minimum_contrast": S.annotated(S.number, ["minimum": .integer(1), "maximum": .integer(21)]),
            "cursor_style": S.strings(["block", "bar", "underline", "block_hollow"]), "cursor_blink": S.strings(["auto", "on", "off"]),
            "padding_x": S.integer(minimum: 0, maximum: 64), "padding_y": S.integer(minimum: 0, maximum: 64),
            "light_theme": paletteName, "dark_theme": paletteName
        ]
    }()

    public static let settingsDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        func complete(_ fields: [String: JSONValue]) -> JSONValue { S.object(fields, required: Array(fields.keys)) }
        let keybindingCommand = S.oneOf([
            S.strings(CommandRegistry.commands.map(\.id) + ["unbound"]),
            S.string(maximumUTF8Bytes: 136, pattern: "^plugin\\.[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*\\.[a-z][a-z0-9-]*(?![\\s\\S])")
        ])
        let notificationFields = notificationDefinitions["NotificationPolicy"]!.object!["properties"]!.object!
        let browserFields = ["search_url": S.string(format: "slate-search-url-template")]
        let layoutFields = ["restore_workspace": S.boolean]
        let agentFields = ["show_activity": S.boolean]
        var patchFields: [String: JSONValue] = ["appearance.theme": S.strings(["auto", "system", "light", "dark"])]
        for (section, fields) in [("terminal", terminalConfigurationFields), ("notifications", notificationFields), ("browser", browserFields), ("layout", layoutFields), ("agents", agentFields)] {
            for (key, schema) in fields { patchFields[section + "." + key] = schema }
        }
        let patch = S.annotated(S.object(patchFields), [
            "maxProperties": .integer(128), "x-maxEncodedJSONBytes": .integer(65_536),
            "patternProperties": .object(["^keybind\\.": keybindingCommand]),
            "propertyNames": S.oneOf([S.strings(Array(patchFields.keys).sorted()), S.string(pattern: "^keybind\\.", format: "slate-keybinding-setting")])
        ])
        let namespaceValues = S.record(S.annotated(S.reference("TOMLValue"), ["x-maxValueDepth": .integer(32)]))
        let namespaceResult: [String: JSONValue] = [
            "id": pluginNamespace, "values": namespaceValues, "appliedValues": namespaceValues,
            "sourceValid": S.boolean, "writeRevision": S.revision
        ]
        let revisionFields: [String: JSONValue] = [
            "sourceRevision": S.nullable(S.revision), "appliedRevision": S.revision,
            "sourceValid": S.boolean, "appliedMatchesSource": S.boolean
        ]
        let warning = complete(["suppressed": S.boolean, "error": S.nullable(S.string())])
        let statusFields: [String: JSONValue] = [
            "path": S.string(), "current": S.reference("AppConfiguration"), "welcome": S.reference("Welcome"),
            "welcomeError": S.nullable(S.string()), "closeWarning": warning, "typeWarning": warning, "error": S.nullable(S.string()),
            "restartRequired": configurationRestartKeys, "unavailableCommands": S.array(S.string()),
            "workspace": complete(["path": S.string(), "savingSuspended": S.boolean, "error": S.nullable(S.string())])
        ]
        let status = statusFields.merging(revisionFields) { _, value in value }
        let write = revisionFields.merging([
            "persisted": S.constant(.bool(true)), "operationId": S.uuid, "restartRequired": configurationRestartKeys
        ]) { _, value in value }
        let color = S.string(pattern: "^#[0-9a-fA-F]{6}(?![\\s\\S])")
        let palette = complete([
            "background": color, "foreground": color, "cursor": color, "cursorText": color,
            "selectionBackground": color, "selectionForeground": color, "ansi": S.array(color, minimum: 16, maximum: 16)
        ])
        let tone = S.strings(["light", "dark"])
        let pluginPatchPath = S.array(S.string(maximumUTF8Bytes: 1024), minimum: 1, maximum: 32)
        return [
            "TOMLValue": S.oneOf([S.string(), S.boolean, S.number, S.array(S.reference("TOMLValue")), S.record(S.reference("TOMLValue"))]),
            "ConfigurationPatch": patch,
            "AppConfiguration": complete([
                "appearance": complete(["theme": S.strings(["system", "light", "dark"])]), "terminal": complete(terminalConfigurationFields),
                "agents": complete(agentFields), "browser": complete(browserFields), "layout": complete(layoutFields), "notifications": S.reference("NotificationPolicy"),
                "keybind": S.annotated(S.record(keybindingCommand), ["propertyNames": S.string(format: "slate-key-chord")]),
                "plugins": S.annotated(S.record(namespaceValues), ["maxProperties": .integer(64), "x-maxEncodedJSONBytes": .integer(65_536), "propertyNames": pluginNamespace])
            ]),
            "ConfigurationStatus": S.object(status.merging(["sourceError": S.string()]) { _, value in value }, required: Array(status.keys)),
            "ConfigurationWrite": S.object(write.merging(["sourceError": S.string()]) { _, value in value }, required: Array(write.keys)),
            "PluginSettings": complete(namespaceResult),
            "PluginSettingsWrite": complete(namespaceResult.merging(["operationId": S.uuid]) { _, value in value }),
            "PluginSettingsOperations": S.annotated(S.array(S.oneOf([
                complete(["op": S.constant(.string("set")), "path": pluginPatchPath,
                    "value": S.annotated(S.reference("TOMLValue"), ["x-maxValueDepth": .integer(32)])]),
                complete(["op": S.constant(.string("delete")), "path": pluginPatchPath])
            ]), maximum: 32), ["x-maxEncodedJSONBytes": .integer(65_536), "x-disjointLiteralPaths": .bool(true), "x-maxSetValueDepthIncludingPath": .integer(32)]),
            "Appearance": complete([
                "revision": S.revision, "tone": tone, "systemAppearance": S.nullable(tone), "setting": S.strings(["system", "light", "dark"]),
                "slot": tone, "paletteName": paletteName, "palette": palette,
                "font": complete(["family": terminalConfigurationFields["font_family"]!, "size": terminalConfigurationFields["font_size"]!]),
                "minimumContrast": terminalConfigurationFields["minimum_contrast"]!
            ])
        ]
    }()

    public static let settings: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        // These legacy handlers ignore unknown non-guard parameters. Strict newer
        // methods (appearance.get) deliberately keep their distinct boundary.
        func legacy(_ parameters: [String: JSONValue] = [:], required: [String] = [], result: JSONValue,
                    extraGuards: [String] = [], errors: [Int] = [], conditions: [JSONValue] = [],
                    semantics: [String: JSONValue] = [:]) -> AutomationContract {
            AutomationContract(parameters: paneTarget.merging(parameters) { _, value in value }, required: required, result: result,
                guards: targetGuards + extraGuards, additionalParameters: true, conditions: conditions, errors: errors,
                constraints: targetConstraints, semantics: semantics)
        }
        let validSource: [JSONValue] = [.object(["requires": .string("validReadableConfigurationOrAbsentFile")])]
        return [
            .configGet: legacy(result: S.reference("ConfigurationStatus"), semantics: ["sourceReadFailure": .string("nullSourceRevisionWithSourceError")]),
            .configValidate: legacy(result: S.object(["valid": S.constant(.bool(true)), "configuration": S.reference("AppConfiguration")], required: ["valid", "configuration"]),
                conditions: validSource, semantics: ["applies": .bool(false), "checksExecutableAndBothPalettes": .bool(true)]),
            .configReload: legacy(result: S.object([
                "changed": S.array(S.string()), "restartRequired": configurationRestartKeys, "operationId": S.uuid
            ], required: ["changed", "restartRequired", "operationId"]), extraGuards: ["expectedSourceRevision"], errors: [-32020],
                conditions: validSource, semantics: ["restartRequiredRelativeTo": .string("launchConfiguration"), "restartsProcesses": .bool(false)]),
            .configPatch: legacy(["values": S.reference("ConfigurationPatch")], required: ["values", "expectedSourceRevision"],
                result: S.reference("ConfigurationWrite"), extraGuards: ["expectedSourceRevision"], errors: [APIError.settingsWriteFailed], conditions: validSource,
                semantics: ["preservesUnrelatedSource": .bool(true), "requiresValidMergedConfiguration": .bool(true),
                    "failureMayHavePersisted": .bool(true), "recovery": .string("readConfigBeforeAnyRetry")]),
            .pluginSettingsGet: legacy(["id": pluginNamespace], required: ["id"], result: S.reference("PluginSettings"),
                semantics: ["registrationRequired": .bool(false), "invalidSourceValues": .string("lastAppliedNamespace")]),
            .pluginSettingsPatch: legacy(["id": pluginNamespace, "operations": S.reference("PluginSettingsOperations")],
                required: ["id", "operations", "expectedWriteRevision"], result: S.reference("PluginSettingsWrite"),
                extraGuards: ["expectedWriteRevision"], errors: [APIError.settingsWriteFailed], conditions: validSource,
                semantics: ["pathSyntax": .string("literalComponentsNotDotted"), "maximumSourceBytes": .integer(1_048_576),
                    "registrationRequired": .bool(false), "deletion": .string("deleteOperationNotNull"),
                    "preservesUnrelatedSource": .bool(true), "failureMayHavePersisted": .bool(true), "diagnostics": .string("namespaceRedacted")]),
            .paletteList: legacy(result: S.array(S.object([
                "name": paletteName, "source": S.strings(["bundled", "custom"]), "valid": S.boolean
            ], required: ["name", "source", "valid"])), errors: [APIError.unavailable], semantics: ["maximumCustomEntries": .integer(1000)]),
            .paletteImport: legacy(["path": S.string(pattern: "^/")], required: ["path"], result: S.object([
                "name": paletteName, "activated": S.constant(.bool(false))
            ], required: ["name", "activated"]), conditions: [.object(["requires": .string("readableRegularUTF8ColorOnlyPaletteFile")])],
                semantics: ["maximumSourceBytes": .integer(65_536), "overwritesDifferentPalette": .bool(false),
                    "changesConfiguration": .bool(false), "reusesIdenticalNamedPalette": .bool(true), "normalizesImportedColors": .bool(true)]),
            .appearanceGet: AutomationContract(parameters: [:], result: S.reference("Appearance"), guards: unanchoredGuards, errors: [APIError.unavailable],
                semantics: ["source": .string("appliedSettingsAndPaletteSnapshot"), "revision": .string("opaqueContentHash")])
        ]
    }()
}
