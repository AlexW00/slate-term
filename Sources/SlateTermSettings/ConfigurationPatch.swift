import Foundation
import SlateTermCore

/// Typed API boundary; source-preserving editing and validation stay shared with native Settings.
public enum ConfigurationPatch {
    public static func literals(_ values: [String: JSONValue]) throws -> [String: String] {
        guard values.count <= 128, try JSONEncoder().encode(values).count <= 65536 else {
            throw ConfigurationError.invalid("Configuration patch exceeds 128 keys or 64 KiB")
        }
        var result: [String: String] = [:]
        for (key, value) in values {
            guard let section = key.split(separator: ".").first,
                  ["appearance", "terminal", "browser", "layout", "keybind", "notifications"].contains(String(section)) else {
                throw ConfigurationError.invalid("Application settings require a supported section; use plugins.settings.patch for plugin namespaces")
            }
            switch value {
            case .string(let text): result[key] = AppConfiguration.quotedString(text)
            case .bool(let flag): result[key] = flag ? "true" : "false"
            case .integer(let number): result[key] = String(number)
            case .number(let number) where number.isFinite: result[key] = String(number)
            default: throw ConfigurationError.invalid("Application settings must be finite scalar values; null is not a TOML value")
            }
        }
        return result
    }

    public static func updating(source: String, values: [String: JSONValue]) throws -> String {
        let literals = try literals(values)
        _ = try AppConfiguration.parse(source)
        if literals.isEmpty { return source }
        return try AppConfiguration.updating(source: source, values: literals)
    }
}
