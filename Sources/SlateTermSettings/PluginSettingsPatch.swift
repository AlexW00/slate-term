import Foundation
import SlateTermCore

/// A bounded, own-namespace patch. Paths are literal components, never dotted expressions.
/// All changes are prepared and semantically checked before the host writes any bytes.
public enum PluginSettingsPatch {
    private static let maxSourceBytes = 1_048_576
    private struct Operation {
        let path: [String]
        let value: JSONValue? // nil means delete; JSON null is never a TOML value.
    }

    public static func updating(source: String, pluginID: String, operations: [JSONValue],
                                parseConfiguration: (String) throws -> AppConfiguration = AppConfiguration.parse) throws -> String {
        try validateNamespace(pluginID)
        guard source.utf8.count <= maxSourceBytes else { throw invalid("Plugin patches require source of at most 1 MiB") }
        guard operations.count <= 32, try JSONEncoder().encode(operations).count <= 65536 else {
            throw invalid("Invalid plugin namespace or patch exceeds 32 operations / 64 KiB")
        }
        let before = try parseConfiguration(source)
        var expected = JSONValue.object(before.plugins[pluginID] ?? [:])
        let parsed = try operations.map(parse)
        for (index, operation) in parsed.enumerated() {
            guard !parsed.prefix(index).contains(where: { operation.path.starts(with: $0.path) || $0.path.starts(with: operation.path) }) else {
                throw invalid("Patch paths must not overlap or address ancestors of one another")
            }
        }
        var lines = source.components(separatedBy: "\n")
        for operation in parsed {
            let next = try replacing(expected, path: operation.path[...], with: operation.value) ?? .object([:])
            if next == expected { continue }
            let fullPath = ["plugins", pluginID] + operation.path
            let records = try TOMLSourceEditor.scan(lines)
            // Preserve the target's inline comment as well when updating a literal in place.
            if let value = operation.value, value.object == nil,
               let record = records.first(where: { $0.path == fullPath && !$0.arrayContext }) {
                lines[record.index] = record.replacingValue(with: try literal(value))
            } else {
                let removed = Set(records.filter { record in
                    record.path?.starts(with: fullPath) == true || record.header?.starts(with: fullPath) == true
                }.map(\.index))
                lines = lines.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
                if let value = operation.value { try insert(value, at: fullPath, into: &lines) }
            }
            expected = next
            try materializeEmptyTables(expected, at: ["plugins", pluginID], into: &lines)
        }
        if expected == .object(before.plugins[pluginID] ?? [:]) { return source }
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        let after = try parseConfiguration(result)
        guard .object(after.plugins[pluginID] ?? [:]) == expected,
              before.plugins.filter({ $0.key != pluginID }) == after.plugins.filter({ $0.key != pluginID }),
              after.changedKeys(from: before).allSatisfy({ $0 == "plugins" }) else {
            throw invalid("The source form cannot be safely patched without changing unrelated settings")
        }
        return result
    }

    public static func validateNamespace(_ id: String) throws {
        guard id.utf8.count <= 64, id.range(of: "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$", options: .regularExpression) == id.startIndex..<id.endIndex else {
            throw invalid("Invalid plugin settings namespace")
        }
    }

    private static func parse(_ input: JSONValue) throws -> Operation {
        guard let object = input.object, let op = object["op"]?.string, ["set", "delete"].contains(op),
              Set(object.keys).isSubset(of: op == "set" ? ["op", "path", "value"] : ["op", "path"]),
              case .array(let values) = object["path"], !values.isEmpty, values.count <= 32 else {
            throw invalid("Each patch requires op set/delete and a nonempty path of at most 32 literal components")
        }
        let path = try values.map { value -> String in
            guard let text = value.string, text.utf8.count <= 1024 else { throw invalid("Path components must be strings of at most 1024 UTF-8 bytes") }
            return text
        }
        if op == "set" {
            guard let value = object["value"] else { throw invalid("set requires a value") }
            _ = try literal(value)
            return Operation(path: path, value: value)
        }
        return Operation(path: path, value: nil)
    }

    private static func replacing(_ current: JSONValue?, path: ArraySlice<String>, with value: JSONValue?) throws -> JSONValue? {
        guard let key = path.first else { return value }
        if current == nil && value == nil { return nil }
        guard current == nil || current?.object != nil else { throw invalid("Patch paths cannot traverse scalar or array values") }
        var fields = current?.object ?? [:]
        fields[key] = try replacing(fields[key], path: path.dropFirst(), with: value)
        return .object(fields)
    }

    private static func insert(_ value: JSONValue, at path: [String], into lines: inout [String]) throws {
        var assignments: [(path: [String], literal: String)] = []
        var headers: [[String]] = []
        func visit(_ value: JSONValue, _ path: [String]) throws {
            if let fields = value.object {
                if fields.isEmpty { headers.append(path) }
                for key in fields.keys.sorted() { try visit(fields[key]!, path + [key]) }
            } else { assignments.append((path, try literal(value))) }
        }
        try visit(value, path)
        try TOMLSourceEditor.insert(assignments: assignments, headers: headers, into: &lines, maxBytes: maxSourceBytes)
    }

    private static func materializeEmptyTables(_ value: JSONValue, at path: [String], into lines: inout [String]) throws {
        let records = try TOMLSourceEditor.scan(lines)
        let existing = Set(records.filter { !$0.arrayContext }.compactMap(\.header))
        var headers: [[String]] = []
        func visit(_ value: JSONValue, _ path: [String]) {
            guard let fields = value.object else { return }
            if fields.isEmpty && !existing.contains(path) { headers.append(path) }
            for key in fields.keys.sorted() { visit(fields[key]!, path + [key]) }
        }
        visit(value, path)
        try TOMLSourceEditor.insert(assignments: [], headers: headers, into: &lines, maxBytes: maxSourceBytes)
    }

    /// Objects are inline only *inside arrays*. Namespace objects are emitted as dotted
    /// leaves/explicit empty tables, keeping ordinary Settings edits compatible.
    private static func literal(_ value: JSONValue, depth: Int = 0) throws -> String {
        guard depth <= 32 else { throw invalid("Plugin settings exceed 32 levels of nesting") }
        switch value {
        case .string(let text): return AppConfiguration.quotedString(text)
        case .bool(let flag): return flag ? "true" : "false"
        case .integer(let number): return String(number)
        case .number(let number) where number.isFinite: return String(number)
        case .array(let values): return "[" + (try values.map { try literal($0, depth: depth + 1) }).joined(separator: ", ") + "]"
        case .object(let fields):
            return "{" + (try fields.keys.sorted().map { AppConfiguration.quotedString($0) + " = " + (try literal(fields[$0]!, depth: depth + 1)) }).joined(separator: ", ") + "}"
        default: throw invalid("Plugin values must be finite JSON-compatible TOML; use delete rather than JSON null")
        }
    }

    private static func invalid(_ message: String) -> ConfigurationError { .invalid(message) }
}
