import Foundation
import TOMLDecoder

extension AppConfiguration {
    /// Updates individual settings while preserving unrelated text and inline comments.
    /// Keys use `section.name`; values are single-line TOML literals.
    public static func updating(source: String, values: [String: String]) throws -> String {
        _ = try parse(source)
        var lines = source.components(separatedBy: "\n")
        for (path, literal) in values.sorted(by: { $0.key < $1.key }) {
            guard let dot = path.firstIndex(of: ".") else {
                throw ConfigurationError.invalid("Settings keys must include their section: \(path)")
            }
            let section = String(path[..<dot])
            let name = String(path[path.index(after: dot)...])
            guard !literal.contains("\n"), !literal.contains("\r") else {
                throw ConfigurationError.invalid("Settings values must be single-line TOML literals")
            }
            var currentSection: [String] = []
            var sectionInsertion: Int?
            var rootInsertion = 0
            var found = false
            for index in lines.indices {
                let line = lines[index]
                let comment = try separator("#", in: line) ?? line.endIndex
                let content = String(line[..<comment]).trimmingCharacters(in: .whitespaces)
                if content.isEmpty { continue }
                if content.hasPrefix("[") {
                    guard content.hasSuffix("]"), !content.hasPrefix("[[") else { throw editingSyntaxError() }
                    currentSection = try keyPath(String(content.dropFirst().dropLast()))
                    if currentSection == [section] { sectionInsertion = index + 1 }
                    continue
                }
                guard let equal = try separator("=", in: line) else { throw editingSyntaxError() }
                let key = try keyPath(String(line[..<equal]))
                let valueStart = line.index(after: equal)
                let value = String(line[valueStart..<comment]).trimmingCharacters(in: .whitespaces)
                // These forms need a full syntax tree to preserve their contents safely.
                guard !value.hasPrefix("{"), !value.hasPrefix("\"\"\""), !value.hasPrefix("'''") else {
                    throw editingSyntaxError()
                }
                if currentSection.isEmpty { rootInsertion = index + 1 }
                let existingPath = currentSection + key
                let sameBinding = section == "keybind" && existingPath.count == 2
                    && existingPath[0] == "keybind"
                    && (try? KeyChord.parse(existingPath[1])) == (try? KeyChord.parse(name))
                if existingPath == [section, name] || sameBinding {
                    let valueRange = line[valueStart..<comment]
                    let leading = valueRange.prefix(while: { $0 == " " || $0 == "\t" })
                    let trailing = valueRange.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed()
                    lines[index] = String(line[...equal]) + leading + literal + String(trailing) + line[comment...]
                    found = true
                }
            }
            if !found {
                if let insertion = sectionInsertion {
                    lines.insert("\(quotedString(name)) = \(literal)", at: insertion)
                } else {
                    // Root dotted keys also work when the section already uses dotted assignments.
                    lines.insert("\(quotedString(section)).\(quotedString(name)) = \(literal)", at: rootInsertion)
                }
            }
        }
        let result = lines.joined(separator: "\n")
        _ = try parse(result)
        return result.hasSuffix("\n") ? result : result + "\n"
    }

    public static func quotedString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5c: result += "\\\\"
            case 0...0x1f, 0x7f: result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func keyPath(_ source: String) throws -> [String] {
        var remainder = source
        var result: [String] = []
        while true {
            let dot = try separator(".", in: remainder) ?? remainder.endIndex
            let segment = String(remainder[..<dot]).trimmingCharacters(in: .whitespaces)
            let decoded = try TOMLDecoder().decode([String: String].self, from: "\(segment) = ''")
            guard let key = decoded.keys.first, decoded.count == 1 else { throw editingSyntaxError() }
            result.append(key)
            if dot == remainder.endIndex { return result }
            remainder = String(remainder[remainder.index(after: dot)...])
        }
    }

    private static func separator(_ separator: Character, in source: String) throws -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in source.indices {
            let character = source[index]
            if escaped { escaped = false; continue }
            if let current = quote {
                if current == "\"", character == "\\" { escaped = true }
                else if character == current { quote = nil }
            } else if character == separator {
                return index
            } else if character == "\"" || character == "'" {
                quote = character
            }
        }
        guard quote == nil else { throw editingSyntaxError() }
        return nil
    }

    private static func editingSyntaxError() -> ConfigurationError {
        .invalid("This configuration uses inline tables or multiline syntax. Edit the configuration file directly, or use ordinary [section] tables to edit it in Settings.")
    }
}
