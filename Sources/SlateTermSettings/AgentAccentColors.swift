import Foundation
import SlateTermCore
import TOMLDecoder

/// User overrides for agent families; missing entries use the built-in palette.
public enum AgentAccentColors {
    public static func validate(_ colors: [String: String]) throws -> [String: String] {
        guard colors.count <= 64 else { throw ConfigurationError.invalid("agents.colors allows at most 64 agents") }
        for (name, color) in colors {
            guard PresenceActor.isValidName(name), name == name.lowercased(), !name.contains(":") else {
                throw ConfigurationError.invalid("Agent color names must be lowercase actor names without a : suffix (1–32 characters)")
            }
            guard color.utf8.count == 7, color.first == "#", color.dropFirst().utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { throw ConfigurationError.invalid("Agent colors must use #RRGGBB") }
        }
        return colors.mapValues { $0.uppercased() }
    }

    static func parse(_ table: TOMLTable) throws -> [String: String] {
        var colors: [String: String] = [:]
        for key in table.keys { colors[key] = try table.string(forKey: key) }
        return try validate(colors)
    }

    public static func literal(_ colors: [String: String]) -> String {
        "{ " + colors.keys.sorted().map {
            AppConfiguration.quotedString($0) + " = " + AppConfiguration.quotedString(colors[$0]!)
        }.joined(separator: ", ") + " }"
    }

    /// Persist ordinary table entries so every configuration writer can read them.
    static func updating(_ lines: inout [String], literal: String) throws {
        let decoded = try TOMLTable(source: "colors = " + literal)
        guard decoded.keys.count == 1 else { throw ConfigurationError.invalid("Invalid agents.colors table") }
        var colors = try parse(decoded.table(forKey: "colors"))
        let prefix = ["agents", "colors"]
        for record in try TOMLSourceEditor.scan(lines).reversed() {
            if let path = record.path, path.starts(with: prefix) {
                if path.count == 3, let color = colors.removeValue(forKey: path[2]) {
                    lines[record.index] = record.replacingValue(with: AppConfiguration.quotedString(color))
                } else {
                    // Keep a removed override's comment as a standalone comment.
                    lines[record.index] = String(record.text[record.comment...])
                }
            }
        }
        // Keep existing headers, including an empty table after resetting all colors.
        // Insert uses the nearest table and quotes dotted agent names literally.
        try TOMLSourceEditor.insert(assignments: colors.keys.sorted().map {
            (prefix + [$0], AppConfiguration.quotedString(colors[$0]!))
        }, headers: [], into: &lines)
    }
}
