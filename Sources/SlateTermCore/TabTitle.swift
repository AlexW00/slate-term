import Foundation

/// Live tab names and saved overrides share limits; recipe editor labels remain separate.
public enum TabTitle {
    public static let defaultTitle = "Slate Terminal"
    public static let maximumCharacters = 100
    public static let maximumBytes = 1024

    public static func normalized(_ input: String) throws -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= maximumCharacters, text.utf8.count <= maximumBytes,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RPCFailure(code: -32602, message: "Tab names must be at most 100 characters / 1024 UTF-8 bytes without control characters")
        }
        return text.isEmpty ? nil : text
    }

    /// Stored input must already be canonical; loading never silently rewrites a user's file.
    public static func canonical(_ input: String?) throws -> String? {
        guard let input else { return nil }
        guard try normalized(input) == input else {
            throw RPCFailure(code: -32602, message: "Stored tab names must be nonempty and trimmed")
        }
        return input
    }
}
