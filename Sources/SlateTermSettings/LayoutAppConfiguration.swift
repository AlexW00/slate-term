import Foundation
import SlateTermCore
import TOMLDecoder

/// Reads shared settings without writing them. Only explicit local values override the parent.
public enum LayoutAppConfiguration {
    public struct Loaded: Sendable {
        public let configuration: AppConfiguration
        public let parentError: String?
    }

    public static func load(parentURL: URL, overridesURL: URL, overridesSource: String? = nil,
                            validateParent: (AppConfiguration) throws -> Void = { _ in }) throws -> Loaded {
        var parent = ""
        var diagnostic: String?
        do {
            parent = try source(at: parentURL)
            try validateParent(AppConfiguration.parse(parent))
        } catch {
            parent = ""
            diagnostic = "Parent configuration could not be loaded; defaults and local overrides are in use. \(error)"
        }
        let overrides = try overridesSource ?? source(at: overridesURL)
        return try Loaded(configuration: parse(parentSource: parent, overridesSource: overrides), parentError: diagnostic)
    }

    public static func parse(parentSource: String, overridesSource: String) throws -> AppConfiguration {
        // Validate the parent independently so an override cannot hide a malformed shared setting.
        _ = try AppConfiguration.parse(parentSource)
        let parent = try table(parentSource)
        let overrides = try table(overridesSource)
        let merged = try merge(parent, overrides, path: [])
        return try AppConfiguration.parse(render(merged))
    }

    /// Validates against inherited values while editing only the local source.
    public static func updating(source: String, values: [String: String],
                                loadEffective: (String) throws -> AppConfiguration) throws -> String {
        let before = try loadEffective(source)
        guard !values.isEmpty else { return source }
        var lines = source.components(separatedBy: "\n")
        for (key, literal) in values.sorted(by: { $0.key < $1.key }) {
            let path = try settingPath(key)
            guard !literal.contains("\n"), !literal.contains("\r") else {
                throw ConfigurationError.invalid("Settings values must be single-line TOML literals")
            }
            var found = false
            for record in try TOMLSourceEditor.scan(lines) {
                guard var existing = record.path, existing.count == 2 else { continue }
                if existing[0] == "keybind" { existing[1] = try KeyChord.parse(existing[1]).description }
                if existing == path {
                    lines[record.index] = record.replacingValue(with: literal)
                    found = true
                }
            }
            if !found { try TOMLSourceEditor.insert(literal: literal, at: path, into: &lines) }
        }
        let result = lines.joined(separator: "\n")
        let after = try loadEffective(result)
        let allowed = Set(values.keys.map { $0.hasPrefix("keybind.") ? "keybind" : $0 })
        guard after.changedKeys(from: before).allSatisfy(allowed.contains) else { throw AppConfiguration.editingSyntaxError() }
        return result.hasSuffix("\n") ? result : result + "\n"
    }

    /// Plugin deletes remove local values, revealing any inherited value at the same path.
    public static func updatingPluginSettings(source: String, pluginID: String, operations: [JSONValue],
                                              loadEffective: (String) throws -> AppConfiguration) throws -> String {
        try PluginSettingsPatch.updating(source: source, pluginID: pluginID, operations: operations) { localSource in
            var configuration = try loadEffective(localSource)
            let document = try TOMLTable(source: localSource)
            configuration.plugins = document.keys.contains("plugins")
                ? try parsePluginSettings(document.table(forKey: "plugins")) : [:]
            return configuration
        }
    }

    /// The returned keys describe explicit application overrides, including values equal to defaults.
    public static func overriddenSettingKeys(source: String) throws -> [String] {
        let values = try table(source)
        var result: [String] = []
        for section in values.keys.sorted() where section != "plugins" {
            guard let fields = values[section] as? [String: Any] else { continue }
            for name in fields.keys.sorted() {
                let key = section == "keybind" ? try KeyChord.parse(name).description : name
                result.append(section + "." + key)
            }
        }
        return result.sorted()
    }

    /// Removes local assignments without rewriting unrelated supported TOML or comments.
    /// As with the existing writers, inline tables and multiline source require direct editing.
    public static func resetOverrides(keys: [String], source: String) throws -> String {
        guard !keys.isEmpty, keys.count <= 128, Set(keys).count == keys.count else {
            throw ConfigurationError.invalid("Reset requires 1 to 128 distinct setting keys")
        }
        let paths = try keys.map(settingPath)
        _ = try table(source)
        var lines = source.components(separatedBy: "\n")
        let removed = try TOMLSourceEditor.scan(lines).filter { record in
            guard var path = record.path, path.count == 2 else { return false }
            if path[0] == "keybind" { path[1] = try KeyChord.parse(path[1]).description }
            return paths.contains(path)
        }.map(\.index)
        guard !removed.isEmpty else { return source }
        let indices = Set(removed)
        lines = lines.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        let result = lines.joined(separator: "\n")
        _ = try table(result)
        return result.hasSuffix("\n") ? result : result + "\n"
    }

    private static func settingPath(_ key: String) throws -> [String] {
        guard let dot = key.firstIndex(of: ".") else {
            throw ConfigurationError.invalid("Settings keys must include their section: \(key)")
        }
        let section = String(key[..<dot]), name = String(key[key.index(after: dot)...])
        if section == "keybind" {
            let canonical = try KeyChord.parse(name).description
            return [section, canonical]
        }
        guard AutomationContracts.settingsDefinitions["ConfigurationPatch"]?.object?["properties"]?.object?[key] != nil else {
            throw ConfigurationError.invalid("Unsupported application setting: \(key)")
        }
        return [section, name]
    }

    private static func source(at url: URL) throws -> String {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576, let source = String(data: data, encoding: .utf8) else {
                throw ConfigurationError.invalid("Configuration must be UTF-8 and at most 1 MiB")
            }
            return source
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return "" }
    }

    private static func table(_ source: String) throws -> [String: Any] {
        guard source.utf8.count <= 1_048_576 else { throw ConfigurationError.invalid("Configuration exceeds 1 MiB") }
        var result = try Dictionary(TOMLTable(source: source))
        if let bindings = result["keybind"] as? [String: Any] {
            var canonical: [String: Any] = [:]
            for (key, value) in bindings {
                let chord = try KeyChord.parse(key).description
                guard canonical[chord] == nil else { throw ConfigurationError.invalid("Duplicate keybinding: \(chord)") }
                canonical[chord] = value
            }
            result["keybind"] = canonical
        }
        return result
    }

    private static func merge(_ parent: [String: Any], _ overrides: [String: Any], path: [String]) throws -> [String: Any] {
        guard path.count <= 34 else { throw ConfigurationError.invalid("Plugin settings exceed 32 levels of nesting") }
        var result = parent
        for (key, value) in overrides {
            if let fields = value as? [String: Any], let inherited = result[key] as? [String: Any] {
                result[key] = try merge(inherited, fields, path: path + [key])
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// This temporary representation is parsed, never persisted over either source file.
    private static func render(_ fields: [String: Any]) throws -> String {
        try fields.keys.sorted().map { AppConfiguration.quotedString($0) + " = " + (try literal(fields[$0]!, depth: 0)) }.joined(separator: "\n")
    }

    private static func literal(_ value: Any, depth: Int) throws -> String {
        guard depth <= 36 else { throw ConfigurationError.invalid("Configuration nesting exceeds its limit") }
        switch value {
        case let flag as Bool: return flag ? "true" : "false"
        case let integer as Int64: return String(integer)
        case let number as Double where number.isFinite: return String(number)
        case let text as String: return AppConfiguration.quotedString(text)
        case let array as [Any]:
            return "[" + (try array.map { try literal($0, depth: depth + 1) }).joined(separator: ", ") + "]"
        case let fields as [String: Any]:
            return "{" + (try fields.keys.sorted().map {
                AppConfiguration.quotedString($0) + " = " + (try literal(fields[$0]!, depth: depth + 1))
            }).joined(separator: ", ") + "}"
        default: throw ConfigurationError.invalid("Settings must be finite JSON-compatible TOML; quote dates and times")
        }
    }
}
