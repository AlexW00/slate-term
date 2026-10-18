import Foundation

/// JSON Schema fragments used by the shared automation catalogs. x-* annotations
/// describe host constraints (notably UTF-8 byte limits) beyond standard keywords.
public enum APISchema {
    public static let dialect = "https://json-schema.org/draft/2020-12/schema"
    public static let any: JSONValue = .bool(true)
    public static let null: JSONValue = .object(["type": .string("null")])
    public static let boolean: JSONValue = .object(["type": .string("boolean")])
    public static let number: JSONValue = .object(["type": .string("number")])
    public static let emptyObject = object([:])

    public static func string(minimumLength: Int? = nil, maximumUTF8Bytes: Int? = nil,
                              pattern: String? = nil, format: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("string")]
        if let minimumLength { fields["minLength"] = .integer(minimumLength) }
        if let maximumUTF8Bytes { fields["x-maxUTF8Bytes"] = .integer(maximumUTF8Bytes) }
        if let pattern { fields["pattern"] = .string(pattern) }
        if let format { fields["format"] = .string(format) }
        return .object(fields)
    }

    public static func integer(minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("integer")]
        if let minimum { fields["minimum"] = .integer(minimum) }
        if let maximum { fields["maximum"] = .integer(maximum) }
        return .object(fields)
    }

    public static func strings(_ values: [String]) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
    }
    public static func constant(_ value: JSONValue) -> JSONValue { .object(["const": value]) }
    public static func nullable(_ schema: JSONValue) -> JSONValue { .object(["anyOf": .array([schema, null])]) }
    public static func oneOf(_ schemas: [JSONValue]) -> JSONValue { .object(["oneOf": .array(schemas)]) }
    public static func array(_ item: JSONValue, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("array"), "items": item]
        if let minimum { fields["minItems"] = .integer(minimum) }
        if let maximum { fields["maxItems"] = .integer(maximum) }
        return .object(fields)
    }
    public static func object(_ properties: [String: JSONValue], required: [String] = [], additional: Bool = false) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.sorted().map(JSONValue.string)), "additionalProperties": .bool(additional)])
    }
    public static func record(_ value: JSONValue) -> JSONValue {
        .object(["type": .string("object"), "additionalProperties": value])
    }
    public static func annotated(_ schema: JSONValue, _ annotations: [String: JSONValue]) -> JSONValue {
        let fields: [String: JSONValue]
        switch schema {
        case .object(let object): fields = object
        case .bool(true): fields = [:]
        case .bool(false): fields = ["not": .object([:])]
        default: preconditionFailure("A schema must be an object or boolean")
        }
        return .object(fields.merging(annotations) { _, next in next })
    }
    public static func defaulted(_ schema: JSONValue, _ value: JSONValue) -> JSONValue {
        annotated(schema, ["default": value])
    }
    public static func reference(_ name: String) -> JSONValue { .object(["$ref": .string("#/$defs/" + name)]) }

    public static let paneID = string(pattern: "^p[1-9][0-9]*(?![\\s\\S])", format: "slate-pane-id")
    public static let tabID = string(pattern: "^t[1-9][0-9]*(?![\\s\\S])", format: "slate-tab-id")
    public static let groupID = string(pattern: "^w[1-9][0-9]*(?![\\s\\S])", format: "slate-group-id")
    public static let uuid = string(format: "uuid")
    public static let revision = string(minimumLength: 1)
    public static let exitCode = integer(minimum: 0, maximum: 255)
}
