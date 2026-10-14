import Foundation

/// Shared lexical subset for all source-preserving writers. Full semantic validation is
/// still performed by TOMLDecoder/AppConfiguration before and after an edit. Unsupported
/// multiline/inline-table assignments fail closed, never falling back to serialization.
struct TOMLSourceLine {
    let index: Int
    let text: String
    let section: [String]
    let header: [String]?
    let arrayContext: Bool
    let path: [String]?
    let equal: String.Index?
    let comment: String.Index

    func replacingValue(with literal: String) -> String {
        guard let equal else { return text }
        let start = text.index(after: equal)
        let range = text[start..<comment]
        let leading = range.prefix { $0 == " " || $0 == "\t" }
        let trailing = range.reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
        return String(text[...equal]) + leading + literal + String(trailing) + text[comment...]
    }
}

enum TOMLSourceEditor {
    static func scan(_ lines: [String]) throws -> [TOMLSourceLine] {
        var section: [String] = []
        var arrayRoots: Set<[String]> = []
        var arrayContext = false
        var result: [TOMLSourceLine] = []
        for (index, line) in lines.enumerated() {
            let comment = try AppConfiguration.separator("#", in: line) ?? line.endIndex
            let content = String(line[..<comment]).trimmingCharacters(in: .whitespaces)
            if content.isEmpty { continue }
            if content.hasPrefix("[") {
                let array = content.hasPrefix("[[")
                guard content.hasSuffix(array ? "]]" : "]") else { throw AppConfiguration.editingSyntaxError() }
                section = try AppConfiguration.keyPath(String(content.dropFirst(array ? 2 : 1).dropLast(array ? 2 : 1)))
                if array { arrayRoots.insert(section) }
                arrayContext = section.indices.contains { arrayRoots.contains(Array(section.prefix($0 + 1))) }
                result.append(TOMLSourceLine(index: index, text: line, section: section, header: section,
                                            arrayContext: arrayContext, path: nil, equal: nil, comment: comment))
                continue
            }
            guard let equal = try AppConfiguration.separator("=", in: line) else { throw AppConfiguration.editingSyntaxError() }
            let key = try AppConfiguration.keyPath(String(line[..<equal]))
            let value = String(line[line.index(after: equal)..<comment]).trimmingCharacters(in: .whitespaces)
            guard !value.hasPrefix("{"), !value.hasPrefix("\"\"\""), !value.hasPrefix("'''") else { throw AppConfiguration.editingSyntaxError() }
            result.append(TOMLSourceLine(index: index, text: line, section: section, header: nil,
                                        arrayContext: arrayContext, path: section + key, equal: equal, comment: comment))
        }
        return result
    }

    static func insert(literal: String, at path: [String], into lines: inout [String]) throws {
        try insert(assignments: [(path, literal)], headers: [], into: &lines)
    }

    static func insert(assignments: [(path: [String], literal: String)], headers: [[String]], into lines: inout [String], maxBytes: Int? = nil) throws {
        let records = try scan(lines)
        var parents: [[String]: Int] = [:]
        for record in records where !record.arrayContext {
            if let header = record.header { parents[header] = record.index + 1 }
        }
        let rootIndex = records.first(where: { $0.header != nil })?.index ?? lines.count
        var bytes = lines.reduce(0) { $0 + $1.utf8.count + 1 } // reserves final newline
        func account(_ additionalBytes: Int) throws {
            bytes += additionalBytes
            if let maxBytes, bytes > maxBytes { throw ConfigurationError.invalid("Edited TOML exceeds the source size budget") }
        }
        try account(0)
        var insertions: [Int: [String]] = [:]
        for assignment in assignments {
            // Find a real ancestor table in O(depth), not a full-source scan per leaf.
            var depth = assignment.path.count - 1
            while depth > 0 && parents[Array(assignment.path.prefix(depth))] == nil { depth -= 1 }
            let index = parents[Array(assignment.path.prefix(depth))] ?? rootIndex
            let key = assignment.path.dropFirst(depth).map(AppConfiguration.quotedString).joined(separator: ".")
            let line = "\(key) = \(assignment.literal)"
            try account(line.utf8.count + 1)
            insertions[index, default: []].append(line)
        }
        var newHeaders: [String] = []
        for header in headers {
            let line = "[" + header.map(AppConfiguration.quotedString).joined(separator: ".") + "]"
            try account(line.utf8.count + 1)
            newHeaders.append(line)
        }
        for index in insertions.keys.sorted().reversed() { lines.insert(contentsOf: insertions[index]!, at: index) }
        lines.append(contentsOf: newHeaders)
    }
}
