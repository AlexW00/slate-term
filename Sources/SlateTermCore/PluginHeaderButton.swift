import Foundation

/// A native pane-header contribution backed by one of its owner's commands.
public struct PluginHeaderButton: Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let command: String
    public let paneTypes: [String]

    private enum Keys: String, CodingKey { case id, title, symbol, command, paneTypes }
    public init(from decoder: any Decoder) throws {
        try requirePluginKeys(decoder, allowed: ["id", "title", "symbol", "command", "paneTypes"])
        let values = try decoder.container(keyedBy: Keys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        symbol = try values.decode(String.self, forKey: .symbol)
        command = try values.decode(String.self, forKey: .command)
        paneTypes = try values.decodeIfPresent([String].self, forKey: .paneTypes) ?? ["*"]
        func identifier(_ value: String, local: Bool = false) -> Bool {
            !value.isEmpty && value.utf8.count <= 64 && value.range(of: local ? "^[a-z][a-z0-9-]*$" : "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$", options: .regularExpression) == value.startIndex..<value.endIndex
        }
        guard identifier(id, local: true), identifier(command, local: true), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 100, !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !symbol.isEmpty, symbol.utf8.count <= 128,
              symbol.range(of: "^[a-z0-9]+(?:[.-][a-z0-9]+)*$", options: .regularExpression) == symbol.startIndex..<symbol.endIndex,
              !paneTypes.isEmpty, paneTypes.count <= 32, Set(paneTypes).count == paneTypes.count,
              paneTypes == ["*"] || paneTypes.allSatisfy({ identifier($0) }) else {
            throw RPCFailure(code: -32602, message: "Invalid plugin header button identity, title, symbol, command or paneTypes")
        }
    }

    public func matches(paneType: String) -> Bool { paneTypes == ["*"] || paneTypes.contains(paneType) }
    public func namespacedID(plugin: String) -> String { "plugin.\(plugin).header.\(id)" }
}
