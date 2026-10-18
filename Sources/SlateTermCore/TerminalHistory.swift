import Foundation

/// A tail of retained terminal text, not an output-byte stream or command stdout.
public struct TerminalHistoryRequest: Sendable {
    public static let maximumBytes = 128 * 1024
    public static let maximumLines = 10_000
    public let maxBytes: Int
    public let maxLines: Int

    public init(_ params: [String: JSONValue]) throws {
        func limit(_ name: String, default value: Int, maximum: Int) throws -> Int {
            guard let input = params[name] else { return value }
            guard case .integer(let count) = input, (1...maximum).contains(count) else {
                throw RPCFailure(code: -32602, message: "\(name) must be an integer in 1...\(maximum)")
            }
            return count
        }
        maxBytes = try limit("maxBytes", default: Self.maximumBytes, maximum: Self.maximumBytes)
        maxLines = try limit("maxLines", default: 2_000, maximum: Self.maximumLines)
    }

    public func result(text: String, byteTruncated: Bool) -> TerminalHistoryResult {
        // The engine has already bounded bytes at a Unicode scalar boundary. Keep
        // newline-delimited logical lines; a trailing newline terminates the last
        // line rather than creating an extra empty line for this limit.
        var end = text.endIndex
        if end != text.startIndex, text[text.index(before: end)] == "\n" { end = text.index(before: end) }
        var start = end
        var lines = end == text.startIndex ? (text.isEmpty ? 0 : 1) : 1
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous] == "\n" {
                if lines == maxLines { break }
                lines += 1
            }
            start = previous
        }
        return TerminalHistoryResult(text: String(text[start...]), truncated: byteTruncated || start != text.startIndex, lineCount: lines)
    }
}

public struct TerminalHistoryResult: Encodable, Sendable {
    public let text: String
    public let truncated: Bool
    public let lineCount: Int
}

public struct TerminalSearchRequest: Sendable {
    public enum Action: String, CaseIterable, Sendable { case get, set, next, previous, end }
    public let action: Action
    public let query: String?
    public init(_ params: [String: JSONValue]) throws {
        guard let action = Action(rawValue: params["action"]?.string ?? "get"),
              params["action"] == nil || params["action"]?.string != nil else {
            throw RPCFailure(code: -32602, message: "Search action must be get, set, next, previous, or end")
        }
        if action == .set {
            guard let query = params["query"]?.string, query.utf8.count <= 4_096, !query.utf8.contains(0) else {
                throw RPCFailure(code: -32602, message: "Search query must be a string of at most 4096 UTF-8 bytes without NUL")
            }
            self.query = query
        } else {
            guard params["query"] == nil else { throw RPCFailure(code: -32602, message: "query is only valid with action set") }
            query = nil
        }
        self.action = action
    }
}
