import Foundation

/// Declarative starting configuration, separate from plugin preferences and live storage.
public struct SavedLayoutField: Equatable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case text, directory, url, multiline, boolean, choice }
    public let id: String
    public let label: String
    public let kind: Kind
    public let required: Bool
    public let defaultValue: JSONValue?
    public let options: [String]

    public init(id: String, label: String, kind: Kind, required: Bool = false, defaultValue: JSONValue? = nil, options: [String] = []) {
        self.id = id; self.label = label; self.kind = kind; self.required = required
        self.defaultValue = defaultValue; self.options = options
    }

    private enum CodingKeys: String, CodingKey { case id, label, kind, required, defaultValue, options }
    public init(from decoder: any Decoder) throws {
        try requirePluginKeys(decoder, allowed: ["id", "label", "kind", "required", "defaultValue", "options"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        kind = try c.decode(Kind.self, forKey: .kind)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        defaultValue = try c.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        guard id.range(of: "^[a-zA-Z][a-zA-Z0-9_]{0,63}$", options: .regularExpression) != nil,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 100, label.utf8.count <= 1024,
              !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              options.count <= 32, Set(options).count == options.count,
              options.allSatisfy({ !$0.isEmpty && $0.count <= 100 && $0.utf8.count <= 1024 }),
              kind == .choice ? !options.isEmpty : options.isEmpty else {
            throw RPCFailure(code: -32602, message: "Invalid layout field schema: \(id)")
        }
        if let defaultValue, let problem = problem(defaultValue) { throw RPCFailure(code: -32602, message: problem) }
    }

    public func problem(_ value: JSONValue?) -> String? {
        guard let value = value ?? defaultValue else { return required ? "\(label) is required" : nil }
        if kind == .boolean {
            if case .bool = value { return nil }
            return "\(label) must be a boolean"
        }
        guard let text = value.string, text.utf8.count <= 16_384, !text.utf8.contains(0) else { return "\(label) must be text of at most 16384 UTF-8 bytes" }
        if text.isEmpty { return required ? "\(label) is required" : nil }
        if kind == .choice, !options.contains(text) { return "Choose a valid \(label)" }
        if kind == .directory, !text.hasPrefix("/"), !text.hasPrefix("~/") { return "\(label) must be an absolute path or start with ~/" }
        if kind == .url, text != "about:blank" {
            guard let url = URL(string: text, encodingInvalidCharacters: false), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil else { return "\(label) must be an HTTP or HTTPS URL without credentials" }
        }
        return nil
    }
}

public struct SavedLayoutPaneType: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let fields: [SavedLayoutField]
    public var defaults: [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: fields.compactMap { field in field.defaultValue.map { (field.id, $0) } })
    }
    public static func available(plugins: [PluginRegistration]) -> [Self] {
        [Self(id: "terminal", title: "Terminal", fields: [
            .init(id: "directory", label: "Starting Folder", kind: .directory),
            .init(id: "command", label: "Startup Command", kind: .multiline)
        ]), Self(id: "browser", title: "Browser", fields: [.init(id: "url", label: "Starting URL", kind: .url)])]
        + plugins.filter(\.hasPanel).map { Self(id: $0.id, title: $0.title, fields: $0.layoutFields) }
    }
}

extension SavedLayoutDefinition {
    public func problems(types: [SavedLayoutPaneType]) -> [String] {
        var result: [String] = []
        for pane in tabs.flatMap(\.panes) {
            guard let type = types.first(where: { $0.id == pane.type }) else {
                result.append("Missing plugin: \(pane.type)"); continue
            }
            for field in type.fields {
                if let problem = field.problem(pane.configuration[field.id]) {
                    result.append("\(pane.title.isEmpty ? pane.id.description : pane.title): \(problem)")
                    if result.count >= 128 { return result + ["Further diagnostics omitted; fix these fields and validate again."] }
                }
            }
        }
        return result
    }

    public mutating func splitPane(_ pane: PaneID, axis: Axis) throws -> PaneID {
        guard let index = tabs.firstIndex(where: { $0.layout.paneIDs.contains(pane) }), tabs[index].panes.count < 8 else {
            throw RPCFailure(code: -32602, message: "Select a pane in a tab with fewer than eight panes")
        }
        let used = Set(tabs.flatMap(\.panes).map(\.id))
        let newID = (1...65).map(PaneID.init).first { !used.contains($0) }!
        var next = self
        next.tabs[index].layout = next.tabs[index].layout.replacing(pane, with: .split(axis: axis, fraction: 0.5, first: .pane(pane), second: .pane(newID)))
        next.tabs[index].panes.append(SavedLayoutPane(id: newID))
        self = try next.validated()
        return newID
    }

    /// Collapses the parent split; the last pane in a tab cannot be removed.
    public mutating func removePane(_ pane: PaneID) throws -> PaneID {
        guard let index = tabs.firstIndex(where: { $0.layout.paneIDs.contains(pane) }),
              let remaining = tabs[index].layout.removing(pane) else {
            throw RPCFailure(code: -32602, message: "The last pane in a tab cannot be removed")
        }
        var next = self
        next.tabs[index].layout = remaining
        next.tabs[index].panes.removeAll { $0.id == pane }
        self = try next.validated()
        return remaining.paneIDs[0]
    }
}
