import Foundation
import SlateTermCore
import TOMLDecoder

/// Use TOML's typed table API: its generic Decoder cannot distinguish a scalar
/// from its enclosing keyed container, and JSONValue expects JSON-style containers.
func parsePluginSettings(_ table: TOMLTable) throws -> [String: [String: JSONValue]] {
    func value(_ source: Any, depth: Int) throws -> JSONValue {
        guard depth <= 32 else { throw ConfigurationError.invalid("Plugin settings exceed 32 levels of nesting") }
        switch source {
        case let bool as Bool: return .bool(bool)
        case let integer as Int64:
            guard let integer = Int(exactly: integer) else { throw ConfigurationError.invalid("Plugin setting integer is out of range") }
            return .integer(integer)
        case let number as Double where number.isFinite: return .number(number)
        case let string as String: return .string(string)
        case let array as [Any]: return .array(try array.map { try value($0, depth: depth + 1) })
        case let object as [String: Any]: return .object(try object.mapValues { try value($0, depth: depth + 1) })
        default: throw ConfigurationError.invalid("Plugin settings must be JSON-compatible; quote dates/times and use finite numbers")
        }
    }
    var settings: [String: [String: JSONValue]] = [:]
    for id in table.keys {
        // Every plugin namespace must itself be a table, never a scalar/array.
        let entries: [String: Any] = try Dictionary(table.table(forKey: id))
        settings[id] = try entries.mapValues { try value($0, depth: 0) }
    }
    return settings
}
