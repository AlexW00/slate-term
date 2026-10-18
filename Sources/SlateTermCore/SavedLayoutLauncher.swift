import Foundation

public struct SavedLayoutLauncherOptions: Equatable, Sendable {
    public static let icons = ["slate", "terminal", "folder", "hammer", "globe", "chevron.left.forwardslash.chevron.right", "server.rack", "book", "star"]
    public static let iconNames = ["Slate", "Terminal", "Folder", "Build", "Web", "Code", "Server", "Book", "Star"]
    public let name: String
    public let icon: String

    public init(name: String, icon: String = "slate") throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.count <= 100, name.utf8.count <= 240,
              !name.contains("/"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RPCFailure(code: -32602, message: "Enter a launcher name of 1–100 characters without slashes, colons or control characters")
        }
        guard Self.icons.contains(icon) else { throw RPCFailure(code: -32602, message: "Choose a supported launcher icon") }
        self.name = name
        self.icon = icon
    }
}
