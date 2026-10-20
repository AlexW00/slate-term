import Foundation

public struct SavedLayoutDefinition: Equatable, Codable, Sendable {
    public var version: Int
    public var id: UUID
    public var name: String
    public var tabs: [SavedLayoutTab]

    public init(version: Int = 1, id: UUID = UUID(), name: String, tabs: [SavedLayoutTab]) {
        self.version = version
        self.id = id
        self.name = name
        self.tabs = tabs
    }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 262_144 else { throw invalidSavedLayout("Saved layout exceeds 256 KiB") }
        do {
            // Bound opaque JSON before handing recursive values to Codable.
            let object = try JSONSerialization.jsonObject(with: data)
            try checkJSONDepth(object)
            return try JSONDecoder().decode(Self.self, from: data).validated()
        } catch let error as RPCFailure { throw error }
        catch let error as DecodingError { throw savedDecodingFailure(error) }
        catch WorkspaceError.invalidIdentity(let value) { throw invalidSavedLayout("Invalid template pane ID: \(value)") }
        catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            throw invalidSavedLayout("Invalid saved layout JSON: \(detail)")
        }
    }

    public func validated() throws -> Self {
        guard version == 1 else { throw invalidSavedLayout("Unsupported saved layout version: \(version)") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalidSavedLayout("Layout name is required") }
        try checkSavedText(name, field: "Layout name")
        guard (1...8).contains(tabs.count) else { throw invalidSavedLayout("A saved layout needs 1...8 tabs") }
        var identities = Set<PaneID>()
        for tab in tabs {
            _ = try TabTitle.canonical(tab.manualTitle)
            guard !tab.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalidSavedLayout("Tab name is required") }
            try checkSavedText(tab.name, field: "Tab name")
            guard (1...8).contains(tab.panes.count) else { throw invalidSavedLayout("Each tab needs 1...8 panes") }
            let leaves = try savedLeaves(tab.layout)
            let recipes = tab.panes.map(\.id)
            guard leaves.count == recipes.count, Set(leaves).count == leaves.count,
                  Set(leaves) == Set(recipes) else {
                throw invalidSavedLayout("Each pane recipe must appear exactly once in its tab's layout")
            }
            for pane in tab.panes {
                guard identities.insert(pane.id).inserted else { throw invalidSavedLayout("Duplicate template pane ID: \(pane.id)") }
                try pane.checkConfiguration()
            }
        }
        do {
            guard try JSONEncoder().encode(self).count <= 262_144 else { throw invalidSavedLayout("Saved layout exceeds 256 KiB") }
        } catch let error as RPCFailure { throw error }
        catch { throw invalidSavedLayout("Saved layout cannot be encoded: \(error.localizedDescription)") }
        return self
    }

    public static func blank(name: String = "Untitled Layout") -> Self {
        Self(name: name, tabs: [SavedLayoutTab(name: "Tab 1", layout: .pane(PaneID(1)),
                                             panes: [SavedLayoutPane(id: PaneID(1), type: "terminal")])])
    }

    public func opening(in workspace: Workspace, focus: Bool = true) throws -> SavedLayoutOpening {
        _ = try validated()
        var result = workspace
        var mapping: [PaneID: SavedLayoutPane] = [:]
        do {
            let firstTab = try result.newTab()
            let groupID = result.groups.first(where: { $0.tabs.contains(firstTab) })!.id
            for (index, tab) in tabs.enumerated() {
                let tabID = index == 0 ? firstTab : try result.newTab(in: groupID)
                try result.setManualTabTitle(tab.manualTitle ?? "", for: tabID)
                let seed = result.tabs.first(where: { $0.id == tabID })!.focusedPane
                let recipes = Dictionary(uniqueKeysWithValues: tab.panes.map { ($0.id, $0) })
                try buildSavedTree(tab.layout, seed: seed, tab: tabID, path: [], recipes: recipes,
                                   workspace: &result, mapping: &mapping)
            }
            try result.focusTab(focus ? firstTab : workspace.keyTabID ?? firstTab)
            return SavedLayoutOpening(workspace: result, groupID: groupID, panes: mapping)
        } catch let error as RPCFailure { throw error }
        catch { throw invalidSavedLayout("Could not open saved layout: \(error)") }
    }

    /// Rebuild the whole app from its recipe while retaining monotonic runtime identities.
    public func restoring(in workspace: Workspace) throws -> SavedLayoutOpening {
        let opening = try opening(in: workspace)
        var result = opening.workspace
        for tab in workspace.tabs { try result.closeTab(tab.id) }
        return SavedLayoutOpening(workspace: result, groupID: opening.groupID, panes: opening.panes)
    }

    private enum CodingKeys: String, CodingKey { case version, id, name, tabs }
    public init(from decoder: any Decoder) throws {
        try requireSavedKeys(decoder, allowed: ["version", "id", "name", "tabs"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        tabs = try values.decode([SavedLayoutTab].self, forKey: .tabs)
    }
}

public struct SavedLayoutTab: Equatable, Codable, Sendable {
    public var name: String
    public var manualTitle: String?
    public var layout: Layout
    public var panes: [SavedLayoutPane]

    public init(name: String, layout: Layout, panes: [SavedLayoutPane], manualTitle: String? = nil) {
        self.name = name
        self.manualTitle = manualTitle
        self.layout = layout
        self.panes = panes
    }

    private enum CodingKeys: String, CodingKey { case name, manualTitle, layout, panes }
    public init(from decoder: any Decoder) throws {
        try requireSavedKeys(decoder, allowed: ["name", "manualTitle", "layout", "panes"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        manualTitle = try TabTitle.canonical(values.decodeIfPresent(String.self, forKey: .manualTitle))
        layout = try values.decode(SavedLayoutTree.self, forKey: .layout).layout
        panes = try values.decode([SavedLayoutPane].self, forKey: .panes)
    }
}

public struct SavedLayoutPane: Equatable, Codable, Sendable {
    public var id: PaneID
    public var type: String
    public var title: String
    public var headerVisible: Bool
    public var configuration: [String: JSONValue]

    public init(id: PaneID, type: String = "terminal", title: String = "", headerVisible: Bool = true, configuration: [String: JSONValue] = [:]) {
        self.id = id
        self.type = type
        self.title = title
        self.headerVisible = headerVisible
        self.configuration = configuration
    }

    fileprivate func checkConfiguration() throws {
        try checkSavedText(title, field: "Pane title")
        switch type {
        case "terminal":
            try checkBuiltInKeys(["directory", "command"])
            if let directory = configuration["directory"]?.string {
                guard !directory.utf8.contains(0), directory.isEmpty || directory.hasPrefix("/") || directory.hasPrefix("~/") else {
                    throw invalidSavedLayout("Terminal directory must be absolute or start with ~/")
                }
            }
            if let command = configuration["command"]?.string {
                guard command.utf8.count <= 16_384, !command.utf8.contains(0) else {
                    throw invalidSavedLayout("Terminal command must be at most 16384 UTF-8 bytes without NUL")
                }
            }
        case "browser", "private-browser":
            try checkBuiltInKeys(["url"])
            if let text = configuration["url"]?.string, !text.isEmpty {
                _ = try BrowserURL.parse(text)
            }
        default:
            guard type.utf8.count <= 64,
                  type.range(of: "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$", options: .regularExpression) == type.startIndex..<type.endIndex else {
                throw invalidSavedLayout("Invalid plugin pane type: \(type)")
            }
            try checkSavedJSON(.object(configuration))
            try PluginPersistence.validateConfiguration(configuration)
        }
    }

    private func checkBuiltInKeys(_ allowed: Set<String>) throws {
        for (key, value) in configuration {
            guard allowed.contains(key) else { throw invalidSavedLayout("Unknown \(type) configuration field: \(key)") }
            guard value.string != nil else { throw invalidSavedLayout("\(type) configuration \(key) must be a string") }
        }
    }

    private enum CodingKeys: String, CodingKey { case id, type, title, headerVisible, configuration }
    public init(from decoder: any Decoder) throws {
        try requireSavedKeys(decoder, allowed: ["id", "type", "title", "headerVisible", "configuration"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(PaneID.self, forKey: .id)
        type = try values.decode(String.self, forKey: .type)
        title = values.contains(.title) ? try values.decode(String.self, forKey: .title) : ""
        headerVisible = values.contains(.headerVisible) ? try values.decode(Bool.self, forKey: .headerVisible) : true
        configuration = values.contains(.configuration) ? try values.decode([String: JSONValue].self, forKey: .configuration) : [:]
    }
}

public struct SavedLayoutOpening: Equatable, Sendable {
    public let workspace: Workspace
    public let groupID: GroupID
    /// Keys are fresh runtime IDs; recipes retain their template IDs.
    public let panes: [PaneID: SavedLayoutPane]

    public init(workspace: Workspace, groupID: GroupID, panes: [PaneID: SavedLayoutPane]) {
        self.workspace = workspace
        self.groupID = groupID
        self.panes = panes
    }
}

private func buildSavedTree(_ layout: Layout, seed: PaneID, tab: TabID, path: [Branch],
                            recipes: [PaneID: SavedLayoutPane], workspace: inout Workspace,
                            mapping: inout [PaneID: SavedLayoutPane]) throws {
    switch layout {
    case .pane(let template):
        let recipe = recipes[template]!
        let type = PaneType(identifier: recipe.type)
        try workspace.setType(seed, to: type)
        if case .registered = type { try workspace.setPluginConfiguration(recipe.configuration, for: seed) }
        try workspace.setManualTitle(recipe.title, for: seed)
        try workspace.setHeaderVisible(recipe.headerVisible, for: seed)
        mapping[seed] = recipe
    case .split(let axis, let fraction, let first, let second):
        let other = try workspace.split(seed, direction: axis == .horizontal ? .right : .down)
        try workspace.resize(tab: tab, path: path, fraction: fraction)
        try buildSavedTree(first, seed: seed, tab: tab, path: path + [.first], recipes: recipes, workspace: &workspace, mapping: &mapping)
        try buildSavedTree(second, seed: other, tab: tab, path: path + [.second], recipes: recipes, workspace: &workspace, mapping: &mapping)
    }
}

private func savedLeaves(_ layout: Layout, depth: Int = 0) throws -> [PaneID] {
    guard depth <= 8 else { throw invalidSavedLayout("Saved layout tree depth exceeds 8") }
    switch layout {
    case .pane(let id): return [id]
    case .split(_, let fraction, let first, let second):
        guard fraction.isFinite, (0.1...0.9).contains(fraction) else {
            throw invalidSavedLayout("Saved split fractions must be finite and between 0.1 and 0.9")
        }
        return try savedLeaves(first, depth: depth + 1) + savedLeaves(second, depth: depth + 1)
    }
}

private func checkSavedText(_ text: String, field: String) throws {
    guard text.count <= 100, text.utf8.count <= 1024, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
        throw invalidSavedLayout("\(field) must be at most 100 characters / 1024 UTF-8 bytes without control characters")
    }
}

private func checkSavedJSON(_ value: JSONValue, depth: Int = 0) throws {
    guard depth <= 32 else { throw invalidSavedLayout("Plugin configuration JSON depth exceeds 32") }
    switch value {
    case .number(let number):
        guard number.isFinite else { throw invalidSavedLayout("Plugin configuration numbers must be finite") }
    case .array(let values): for child in values { try checkSavedJSON(child, depth: depth + 1) }
    case .object(let values): for child in values.values { try checkSavedJSON(child, depth: depth + 1) }
    default: break
    }
}

private func checkJSONDepth(_ value: Any, depth: Int = 0) throws {
    guard depth <= 40 else { throw invalidSavedLayout("Saved layout JSON nesting exceeds its limit") }
    if let values = value as? [String: Any] {
        for child in values.values { try checkJSONDepth(child, depth: depth + 1) }
    } else if let values = value as? [Any] {
        for child in values { try checkJSONDepth(child, depth: depth + 1) }
    }
}

/// Layout's general decoder is permissive; saved recipes must not discard tree fields.
private struct SavedLayoutTree: Decodable {
    let layout: Layout
    private enum Keys: String, CodingKey { case kind, pane, axis, fraction, first, second }
    init(from decoder: any Decoder) throws {
        let depth = decoder.codingPath.filter { ["first", "second"].contains($0.stringValue) }.count
        guard depth <= 8 else { throw invalidSavedLayout("Saved layout tree depth exceeds 8") }
        let values = try decoder.container(keyedBy: Keys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "pane":
            try requireSavedKeys(decoder, allowed: ["kind", "pane"])
            layout = .pane(try values.decode(PaneID.self, forKey: .pane))
        case "split":
            try requireSavedKeys(decoder, allowed: ["kind", "axis", "fraction", "first", "second"])
            layout = .split(axis: try values.decode(Axis.self, forKey: .axis),
                            fraction: try values.decode(Double.self, forKey: .fraction),
                            first: try values.decode(Self.self, forKey: .first).layout,
                            second: try values.decode(Self.self, forKey: .second).layout)
        default: throw invalidSavedLayout("Unknown saved layout tree kind")
        }
    }
}

private struct SavedLayoutKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireSavedKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: SavedLayoutKey.self)
    if let unknown = values.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
        throw invalidSavedLayout("Unknown saved layout field: \(unknown.stringValue)")
    }
}

private func savedDecodingFailure(_ error: DecodingError) -> RPCFailure {
    let context: DecodingError.Context
    let detail: String
    switch error {
    case .keyNotFound(let key, let value): context = value; detail = "Missing required field: \(key.stringValue)"
    case .typeMismatch(_, let value), .valueNotFound(_, let value), .dataCorrupted(let value):
        context = value; detail = value.debugDescription
    @unknown default: return invalidSavedLayout("Invalid saved layout data")
    }
    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
    return invalidSavedLayout("Invalid saved layout\(path.isEmpty ? "" : " at " + path): \(detail)")
}

private func invalidSavedLayout(_ message: String) -> RPCFailure { RPCFailure(code: -32602, message: message) }
