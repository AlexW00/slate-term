import Foundation

public struct CommandSearchItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let keywords: String
    public init(id: String, title: String, detail: String, keywords: String = "") {
        self.id = id; self.title = title; self.detail = detail; self.keywords = keywords
    }
}

/// Stable token matching with a modest subsequence fallback for abbreviated queries.
/// Titles outrank metadata; punctuation and diacritics aren't required for discovery.
public enum CommandSearch {
    public static func results(_ items: [CommandSearchItem], query: String) -> [CommandSearchItem] {
        let tokens = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return items }
        return items.enumerated().compactMap { index, item -> (Int, Int, CommandSearchItem)? in
            let title = normalized(item.title)
            let metadata = normalized(item.detail + " " + item.id + " " + item.keywords)
            var total = 0
            for token in tokens {
                if title == token { total += 100 }
                else if title.hasPrefix(token) { total += 80 }
                else if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(token) }) { total += 65 }
                else if title.contains(token) { total += 50 }
                else if metadata.contains(token) { total += 30 }
                else if token.count >= 2, isSubsequence(token, of: title) { total += 10 }
                else { return nil }
            }
            return (total, index, item)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map { $0.2 }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func isSubsequence(_ query: String, of value: String) -> Bool {
        var index = query.startIndex
        for character in value where index != query.endIndex {
            if character == query[index] { index = query.index(after: index) }
        }
        return index == query.endIndex
    }
}
