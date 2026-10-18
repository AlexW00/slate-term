import Foundation

/// Separate submitted and normalized forms: decodeIfPresent defaults accept null
/// in older manifest fields, whereas encoded registrations omit absent optionals.
enum PluginContractSchemas {
    typealias S = APISchema
    static let localID = S.string(maximumUTF8Bytes: 64, pattern: "^[a-z][a-z0-9-]*(?![\\s\\S])")
    static let title = S.annotated(S.string(minimumLength: 1), ["x-maxGraphemeCount": .integer(100),
        "x-noControls": .bool(true), "x-nonemptyAfterTrimmingWhitespaceAndNewlines": .bool(true)])
    static let absolutePath = S.string(pattern: "^/[^\\u0000]*(?![\\s\\S])")
    static let argument = S.string(maximumUTF8Bytes: 16_384, pattern: "^[^\\u0000]*(?![\\s\\S])")
    static let environment = S.annotated(S.record(argument), ["maxProperties": .integer(128),
        "propertyNames": S.string(minimumLength: 1, pattern: "^[^=\\u0000]+(?![\\s\\S])")])

    static func defaulted(_ schema: JSONValue, _ value: JSONValue, input: Bool, acceptsNull: Bool = true) -> JSONValue {
        input ? S.defaulted(acceptsNull ? S.nullable(schema) : schema, value) : schema
    }
    static func optional(_ schema: JSONValue, input: Bool) -> JSONValue { input ? S.nullable(schema) : schema }
    static func unique(_ item: JSONValue, maximum: Int, minimum: Int? = nil, by property: String? = nil) -> JSONValue {
        S.annotated(S.array(item, minimum: minimum, maximum: maximum), property.map { ["x-uniqueProperty": .string($0)] } ?? ["uniqueItems": .bool(true)])
    }
    static func process(input: Bool) -> JSONValue {
        let fields: [String: JSONValue] = [
            "executable": absolutePath, "arguments": defaulted(S.array(argument, maximum: 128), .array([]), input: input),
            "directory": optional(absolutePath, input: input), "environment": defaulted(environment, .object([:]), input: input),
            "restartLimit": defaulted(S.integer(minimum: 0, maximum: 10), .integer(3), input: input),
            "readyTimeoutSeconds": defaulted(S.annotated(S.number, ["minimum": .number(0.1), "maximum": .integer(60)]), .integer(10), input: input)
        ]
        return S.object(fields, required: input ? ["executable"] : Array(fields.keys.filter { $0 != "directory" }))
    }
    static func command(input: Bool) -> JSONValue {
        let fields: [String: JSONValue] = [
            "id": localID, "title": title, "executable": absolutePath,
            "arguments": defaulted(S.array(argument, maximum: 128), .array([]), input: input),
            "directory": optional(absolutePath, input: input), "environment": defaulted(environment, .object([:]), input: input),
            "timeoutSeconds": defaulted(S.annotated(S.number, ["minimum": .number(0.1), "maximum": .integer(295)]), .integer(30), input: input)
        ]
        return S.object(fields, required: input ? ["id", "title", "executable"] : Array(fields.keys.filter { $0 != "directory" }))
    }
    static func source(input: Bool) -> JSONValue {
        S.oneOf([
            S.object(["kind": S.constant(.string("directory")), "path": absolutePath,
                "entry": defaulted(S.string(minimumLength: 1, format: "slate-plugin-relative-entry"), .string("index.html"), input: input)],
                required: input ? ["kind", "path"] : ["kind", "path", "entry"]),
            S.object(["kind": S.constant(.string("url")), "url": S.string(format: "slate-plugin-url")], required: ["kind", "url"])
        ])
    }
    static func compatibility(input: Bool) -> JSONValue {
        let ids = unique(S.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[A-Za-z0-9._-]+(?![\\s\\S])"), maximum: 256)
        let fields: [String: JSONValue] = [
            "minimumAPIVersion": defaulted(S.integer(minimum: 1, maximum: 65_535), .integer(1), input: input, acceptsNull: false),
            "maximumAPIVersion": defaulted(S.integer(minimum: 1, maximum: 65_535), .integer(1), input: input, acceptsNull: false),
            "requiredMethods": defaulted(ids, .array([]), input: input, acceptsNull: false),
            "requiredCommands": defaulted(ids, .array([]), input: input, acceptsNull: false)
        ]
        return S.annotated(S.object(fields, required: input ? [] : Array(fields.keys)),
            ["x-orderedIntegerFields": .array([.string("minimumAPIVersion"), .string("maximumAPIVersion")])])
    }
    static func headerButton(input: Bool) -> JSONValue {
        let types = S.oneOf([S.constant(.array([.string("*")])), unique(AutomationContracts.pluginNamespace, maximum: 32, minimum: 1)])
        return S.object([
            "id": localID, "title": title, "command": localID,
            "symbol": S.string(minimumLength: 1, maximumUTF8Bytes: 128, pattern: "^[a-z0-9]+(?:[.-][a-z0-9]+)*(?![\\s\\S])"),
            "paneTypes": defaulted(types, .array([.string("*")]), input: input)
        ], required: input ? ["id", "title", "command", "symbol"] : ["id", "title", "command", "symbol", "paneTypes"])
    }
    static func layoutField(input: Bool) -> JSONValue {
        let option = S.annotated(S.string(minimumLength: 1, maximumUTF8Bytes: 1024), ["x-maxGraphemeCount": .integer(100)])
        let fields: [String: JSONValue] = [
            // Preserve the existing field decoder's regex matching, including its
            // final-line-terminator allowance; unlike plugin IDs it does not compare ranges.
            "id": S.string(pattern: "^[a-zA-Z][a-zA-Z0-9_]{0,63}$"),
            "label": S.annotated(title, ["x-maxUTF8Bytes": .integer(1024)]),
            "kind": S.strings(["text", "directory", "url", "multiline", "boolean", "choice"]),
            "required": defaulted(S.boolean, .bool(false), input: input),
            "defaultValue": input ? S.any : S.oneOf([S.boolean, argument]),
            "options": defaulted(unique(option, maximum: 32), .array([]), input: input)
        ]
        return S.annotated(S.object(fields, required: input ? ["id", "label", "kind"] : ["id", "label", "kind", "required", "options"]),
            ["x-layoutFieldValueRules": .bool(true)])
    }
    static func registration(input: Bool) -> JSONValue {
        let suffix = input ? "Input" : ""
        let fields: [String: JSONValue] = [
            "id": S.annotated(AutomationContracts.pluginNamespace, ["not": S.strings(["terminal", "browser", "private-browser"])]),
            "title": title,
            "manifestVersion": defaulted(S.integer(minimum: 1, maximum: 65_535), .integer(1), input: input, acceptsNull: false),
            "version": defaulted(S.string(minimumLength: 1, maximumUTF8Bytes: 64, pattern: "^[!-~]+(?![\\s\\S])"), .string("0.0.0"), input: input, acceptsNull: false),
            "compatibility": defaulted(S.reference("PluginCompatibility" + suffix), .object([
                "minimumAPIVersion": .integer(1), "maximumAPIVersion": .integer(1), "requiredMethods": .array([]), "requiredCommands": .array([])
            ]), input: input, acceptsNull: false),
            "source": optional(S.reference("PluginSource" + suffix), input: input),
            "scope": defaulted(S.strings(["pane", "tab", "global"]), .string("pane"), input: input),
            "process": optional(S.reference("PluginProcess" + suffix), input: input), "service": optional(S.reference("PluginProcess" + suffix), input: input),
            "commands": defaulted(unique(S.reference("PluginCommand" + suffix), maximum: 32, by: "id"), .array([]), input: input),
            "headerButtons": defaulted(unique(S.reference("PluginHeaderButton" + suffix), maximum: 8, by: "id"), .array([]), input: input),
            "layoutFields": defaulted(unique(S.reference("SavedLayoutField" + suffix), maximum: 32, by: "id"), .array([]), input: input)
        ]
        var annotations: [String: JSONValue] = ["x-pluginContributions": .bool(true), "x-pluginSourceProcessRelationship": .bool(true)]
        if input { annotations["x-maxEncodedJSONBytes"] = .integer(262_144) }
        return S.annotated(S.object(fields, required: input ? ["id", "title"] : Array(fields.keys.filter { !["source", "process", "service"].contains($0) })), annotations)
    }
}
