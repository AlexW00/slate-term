import Foundation

/// Bounded structured data, not a blob/database or a storage permission boundary.
public enum PluginPersistence {
    public static let dataBytes = 262_144
    public static let stateBytes = 32_768
    public static let configurationBytes = 65_536
    public static let workspaceBytes = 2_097_152
    public static let patchBytes = 49_152
    public static let valueBytes = 16_384

    public static func validateID(_ id: String) throws {
        guard id.utf8.count <= 64,
              id.range(of: "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$", options: .regularExpression) == id.startIndex..<id.endIndex,
              !["terminal", "browser", "private-browser"].contains(id) else { throw invalid("Invalid plugin ID") }
    }
    public static func validateRevision(_ revision: String) throws {
        guard UUID(uuidString: revision) != nil else { throw invalid("Invalid plugin state revision") }
    }
    public static func validateJSON(_ value: JSONValue, depth: Int = 0) throws {
        guard depth <= 32 else { throw invalid("Plugin JSON nesting exceeds 32") }
        switch value {
        case .number(let number): guard number.isFinite else { throw invalid("Plugin numbers must be finite") }
        case .array(let values): for child in values { try validateJSON(child, depth: depth + 1) }
        case .object(let values): for child in values.values { try validateJSON(child, depth: depth + 1) }
        default: break
        }
    }
    public static func validateConfiguration(_ configuration: [String: JSONValue]) throws {
        try validateJSON(.object(configuration))
        guard try JSONEncoder().encode(configuration).count <= configurationBytes else { throw invalid("Plugin configuration exceeds 64 KiB") }
    }
    public static func validateValues(_ values: [String: JSONValue], panel: Bool) throws {
        guard values.count <= (panel ? 128 : 1024) else { throw invalid("Too many plugin storage keys") }
        for (key, value) in values {
            try validateKey(key)
            try validateJSON(value)
            guard try JSONEncoder().encode(value).count <= valueBytes else { throw invalid("Plugin storage value exceeds 16 KiB") }
        }
        guard try JSONEncoder().encode(values).count <= (panel ? stateBytes : dataBytes) else { throw invalid("Plugin storage document exceeds its byte limit") }
    }
    public static func patch(_ values: [String: JSONValue], operations: JSONValue, panel: Bool) throws -> [String: JSONValue] {
        try validateJSON(operations)
        guard case .array(let operations) = operations, (1...32).contains(operations.count),
              try JSONEncoder().encode(operations).count <= patchBytes else { throw invalid("Patch requires 1–32 operations within 48 KiB") }
        var seen = Set<String>()
        var result = values
        for value in operations {
            guard let operation = value.object, let kind = operation["op"]?.string, let key = operation["key"]?.string,
                  seen.insert(key).inserted else { throw invalid("Patch requires distinct literal keys and valid operations") }
            try validateKey(key)
            switch kind {
            case "set":
                guard Set(operation.keys) == ["op", "key", "value"], let value = operation["value"] else { throw invalid("Set requires exactly op, key and value") }
                result[key] = value
            case "delete":
                guard Set(operation.keys) == ["op", "key"] else { throw invalid("Delete requires exactly op and key") }
                result.removeValue(forKey: key)
            default: throw invalid("Unknown plugin patch operation")
            }
        }
        try validateValues(result, panel: panel)
        return result
    }
    public static func summary(before: [String: JSONValue], after: [String: JSONValue]) -> [String: JSONValue] {
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
        var keys: [String] = []
        for key in changed.prefix(32) {
            guard let bytes = try? JSONEncoder().encode(keys + [key]), bytes.count <= 4096 else { break }
            keys.append(key)
        }
        return ["keys": .array(keys.map(JSONValue.string)), "keyCount": .integer(changed.count), "truncated": .bool(keys.count != changed.count)]
    }
    private static func validateKey(_ key: String) throws {
        guard (1...256).contains(key.utf8.count) else { throw invalid("Plugin storage keys must contain 1–256 UTF-8 bytes") }
    }
    static func invalid(_ message: String) -> RPCFailure { RPCFailure(code: -32602, message: message) }
}

public struct PluginDataDocument: Equatable, Codable, Sendable {
    public let schemaVersion: Int
    public let revision: String
    public let values: [String: JSONValue]
    public init() { schemaVersion = 1; revision = UUID().uuidString; values = [:] }
    private init(values: [String: JSONValue]) { schemaVersion = 1; revision = UUID().uuidString; self.values = values }
    private enum CodingKeys: String, CodingKey { case schemaVersion, revision, values }
    public init(from decoder: any Decoder) throws {
        try requirePluginKeys(decoder, allowed: ["schemaVersion", "revision", "values"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        revision = try c.decode(String.self, forKey: .revision)
        values = try c.decode([String: JSONValue].self, forKey: .values)
        guard schemaVersion == 1 else { throw RPCFailure(code: APIError.incompatible, message: "Unsupported plugin data schema") }
        try PluginPersistence.validateRevision(revision)
        try PluginPersistence.validateValues(values, panel: false)
    }
    /// nil operations is an explicit reset: it always advances the generation.
    public func changing(operations: JSONValue?, expectedRevision: String) throws -> Self {
        guard expectedRevision == revision else { throw RPCFailure(code: APIError.conflict, message: "Plugin data changed; read before rebasing", data: .object(["revision": .string(revision)])) }
        let next = try operations.map { try PluginPersistence.patch(values, operations: $0, panel: false) } ?? [:]
        if operations != nil, next == values { return self }
        return Self(values: next)
    }
}

public struct PluginPanelRecord: Equatable, Codable, Sendable {
    public let panelId: String
    public private(set) var configuration: [String: JSONValue]
    public private(set) var state: [String: JSONValue]
    public private(set) var stateRevision: String
    public init() { panelId = UUID().uuidString; configuration = [:]; state = [:]; stateRevision = UUID().uuidString }
    private enum CodingKeys: String, CodingKey { case panelId, configuration, state, stateRevision }
    public init(from decoder: any Decoder) throws {
        try requirePluginKeys(decoder, allowed: ["panelId", "configuration", "state", "stateRevision"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        panelId = try c.decode(String.self, forKey: .panelId)
        configuration = try c.decode([String: JSONValue].self, forKey: .configuration)
        state = try c.decode([String: JSONValue].self, forKey: .state)
        stateRevision = try c.decode(String.self, forKey: .stateRevision)
        try validated()
    }
    public func validated() throws {
        try PluginPersistence.validateRevision(panelId)
        try PluginPersistence.validateRevision(stateRevision)
        try PluginPersistence.validateConfiguration(configuration)
        try PluginPersistence.validateValues(state, panel: true)
    }
    mutating func configure(_ configuration: [String: JSONValue]) throws {
        try PluginPersistence.validateConfiguration(configuration)
        self.configuration = configuration
    }
    mutating func patch(expectedPanelId: String, expectedRevision: String, operations: JSONValue?) throws {
        guard expectedPanelId == panelId, expectedRevision == stateRevision else {
            throw RPCFailure(code: APIError.conflict, message: "Plugin panel changed; inspect before rebasing", data: .object(["panelId": .string(panelId), "revision": .string(stateRevision)]))
        }
        let next = try operations.map { try PluginPersistence.patch(state, operations: $0, panel: true) } ?? [:]
        guard operations == nil || next != state else { return }
        state = next; stateRevision = UUID().uuidString
    }
}
