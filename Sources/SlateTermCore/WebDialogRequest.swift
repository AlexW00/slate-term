import Foundation

/// A response targets the exact pending dialog, even before document readiness.
public struct WebDialogRequest: Sendable {
    public enum Action: String, Sendable {
        case accept
        case dismiss
    }

    public let dialogID: String
    public let action: Action
    public let text: String?

    public init(params: [String: JSONValue]) throws {
        let allowed: Set<String> = ["pane", "tab", "dialogId", "action", "text"]
        guard Set(params.keys).isSubset(of: allowed) else {
            throw RPCFailure(code: -32602, message: "Unknown dialog response parameter")
        }
        guard let id = params["dialogId"]?.string, !id.isEmpty, id.utf8.count <= 128,
              id.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              }) else {
            throw RPCFailure(code: -32602, message: "A pending dialogId is required")
        }
        guard let actionValue = params["action"]?.string, let action = Action(rawValue: actionValue) else {
            throw RPCFailure(code: -32602, message: "Dialog action must be accept or dismiss")
        }
        if let value = params["text"] {
            guard action == .accept, let text = value.string, text.utf8.count <= 65_536 else {
                throw RPCFailure(code: -32602, message: "Prompt text requires accept and at most 65536 UTF-8 bytes")
            }
            self.text = text
        } else {
            text = nil
        }
        dialogID = id
        self.action = action
    }
}
