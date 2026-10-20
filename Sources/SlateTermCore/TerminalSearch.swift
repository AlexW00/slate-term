import Foundation

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
