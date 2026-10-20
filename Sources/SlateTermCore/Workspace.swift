import Foundation

public enum WorkspaceError: Error, Equatable, Sendable {
    case invalidIdentity(String)
    case paneNotFound(PaneID)
    case tabNotFound(TabID)
    case groupNotFound(GroupID)
    case invalidLayout(String)
    case invalidSnapshot(String)
    case exhaustedIdentities
}

public enum PaneType: Equatable, Codable, Sendable {
    case terminal
    case browser
    case privateBrowser
    case registered(String)

    public init(identifier: String) {
        switch identifier {
        case "terminal": self = .terminal
        case "browser": self = .browser
        case "private-browser": self = .privateBrowser
        default: self = .registered(identifier)
        }
    }

    public var identifier: String {
        switch self {
        case .terminal: "terminal"
        case .browser: "browser"
        case .privateBrowser: "private-browser"
        case .registered(let id): id
        }
    }

    public var isBrowser: Bool { self == .browser || self == .privateBrowser }
}

public enum PaneSplitFocus: String, Codable, Sendable { case new, preserve }

public struct Pane: Equatable, Codable, Sendable, Identifiable {
    public let id: PaneID
    public internal(set) var type: PaneType
    public internal(set) var manualTitle: String? = nil
    /// Native pane chrome belongs to the slot, not its terminal or web document.
    public internal(set) var headerVisible: Bool = true
    public internal(set) var pluginPanel: PluginPanelRecord?

    init(id: PaneID, type: PaneType) {
        self.id = id
        self.type = type
        if case .registered = type { pluginPanel = PluginPanelRecord() }
    }

    private enum CodingKeys: String, CodingKey { case id, type, manualTitle, headerVisible, pluginPanel }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(PaneID.self, forKey: .id)
        type = try values.decode(PaneType.self, forKey: .type)
        manualTitle = try values.decodeIfPresent(String.self, forKey: .manualTitle)
        headerVisible = values.contains(.headerVisible) ? try values.decode(Bool.self, forKey: .headerVisible) : true
        pluginPanel = try values.decodeIfPresent(PluginPanelRecord.self, forKey: .pluginPanel)
    }
}

public struct Tab: Equatable, Codable, Sendable, Identifiable {
    public let id: TabID
    public internal(set) var manualTitle: String? = nil
    public internal(set) var defaultTitle: String = TabTitle.defaultTitle
    public var title: String { manualTitle ?? defaultTitle }
    public internal(set) var layout: Layout
    public internal(set) var focusedPane: PaneID
    public internal(set) var zoomedPane: PaneID? = nil
    /// Most recently focused first. Non-terminal focus does not change this list.
    public internal(set) var terminalHistory: [PaneID]
    public var activeTerminal: PaneID? { terminalHistory.first }
    // The launching app supplies the fallback. Saved workspaces retain only explicit user names.
    private enum CodingKeys: String, CodingKey {
        case id, manualTitle, layout, focusedPane, zoomedPane, terminalHistory
    }
}

public struct TabGroup: Equatable, Codable, Sendable, Identifiable {
    public let id: GroupID
    public internal(set) var tabs: [TabID]
}

/// The value model owns identities and topology. AppKit renders it, never owns it.
/// Restore is the only decoding entry point so callers cannot bypass cross-reference checks.
public struct Workspace: Equatable, Sendable {
    public private(set) var panes: [Pane]
    public private(set) var tabs: [Tab]
    public private(set) var groups: [TabGroup]
    public private(set) var keyTabID: TabID?
    public private(set) var defaultTabTitle = TabTitle.defaultTitle
    private var nextPane: Int
    private var nextTab: Int
    private var nextGroup: Int

    public init() {
        panes = [Pane(id: PaneID(1), type: .terminal)]
        tabs = [Tab(id: TabID(1), layout: .pane(PaneID(1)), focusedPane: PaneID(1), terminalHistory: [PaneID(1)])]
        groups = [TabGroup(id: GroupID(1), tabs: [TabID(1)])]
        keyTabID = TabID(1)
        nextPane = 2
        nextTab = 2
        nextGroup = 2
    }

    /// Apply app identity after restoration without converting automatic titles into user overrides.
    public mutating func setDefaultTabTitle(_ title: String) throws {
        guard let title = try TabTitle.normalized(title) else {
            throw RPCFailure(code: -32602, message: "The default tab title must not be empty")
        }
        defaultTabTitle = title
        for index in tabs.indices { tabs[index].defaultTitle = title }
    }

    /// A pane's live owning tab takes precedence over current focus. Explicit pairs must agree.
    public func resolvedTab(pane: PaneID? = nil, tab: TabID? = nil) throws -> Tab {
        if let pane {
            guard let owner = tabs.first(where: { $0.layout.paneIDs.contains(pane) }) else { throw WorkspaceError.paneNotFound(pane) }
            guard tab == nil || tab == owner.id else { throw WorkspaceError.invalidLayout("Pane does not belong to the requested tab") }
            return owner
        }
        guard let result = tabs.first(where: { $0.id == (tab ?? keyTabID) }) else {
            if let tab { throw WorkspaceError.tabNotFound(tab) }
            throw RPCFailure(code: -32004, message: "There is no key tab")
        }
        return result
    }

    @discardableResult
    public mutating func split(_ target: PaneID, direction: Direction, type: PaneType = .terminal,
                               newPaneFraction: Double = 0.5, focus: PaneSplitFocus = .new) throws -> PaneID {
        try split(in: tabIndex(containing: target), target: target, direction: direction, type: type,
                  newPaneFraction: newPaneFraction, focus: focus)
    }

    @discardableResult
    public mutating func splitRoot(_ tab: TabID, direction: Direction, type: PaneType = .terminal,
                                   newPaneFraction: Double = 0.5, focus: PaneSplitFocus = .new) throws -> PaneID {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { throw WorkspaceError.tabNotFound(tab) }
        return try split(in: index, target: nil, direction: direction, type: type, newPaneFraction: newPaneFraction, focus: focus)
    }

    private mutating func split(in index: Int, target: PaneID?, direction: Direction, type: PaneType,
                                newPaneFraction: Double, focus policy: PaneSplitFocus) throws -> PaneID {
        guard newPaneFraction.isFinite, newPaneFraction > 0, newPaneFraction < 1 else {
            throw WorkspaceError.invalidLayout("New-pane fractions must be finite and between 0 and 1")
        }
        try requireAvailable(nextPane)
        let id = PaneID(nextPane)
        let original = target.map(Layout.pane) ?? tabs[index].layout
        let replacement = Layout.split(axis: direction.axis, fraction: direction.insertsBefore ? newPaneFraction : 1 - newPaneFraction,
                                       first: direction.insertsBefore ? .pane(id) : original,
                                       second: direction.insertsBefore ? original : .pane(id))
        let layout = target.map { tabs[index].layout.replacing($0, with: replacement) } ?? replacement
        _ = try layout.checkedPaneIDs()
        nextPane += 1
        panes.append(Pane(id: id, type: type))
        tabs[index].layout = layout
        tabs[index].zoomedPane = nil
        if policy == .new { focus(id, in: index) }
        else if type == .terminal { tabs[index].terminalHistory.append(id) }
        return id
    }

    /// Move an existing pane beside another pane, retaining its identity across tabs.
    /// Validate the complete replacement before committing so rejected moves are atomic.
    public mutating func move(_ pane: PaneID, beside target: PaneID, direction: Direction, focus selectTarget: Bool = true) throws {
        let index = try tabIndex(containing: pane)
        let destination = try tabIndex(containing: target)
        guard pane != target else { return }
        let followsSelectedPane = keyTabID == tabs[index].id && tabs[index].focusedPane == pane
        if index != destination {
            var next = self
            let sourceTab = tabs[index].id
            let destinationTab = tabs[destination].id
            let replacement = Layout.split(axis: direction.axis, fraction: 0.5,
                first: .pane(direction.insertsBefore ? pane : target),
                second: .pane(direction.insertsBefore ? target : pane))
            let layout = tabs[destination].layout.replacing(target, with: replacement)
            _ = try layout.checkedPaneIDs()
            if let remaining = tabs[index].layout.removing(pane) {
                _ = try remaining.checkedPaneIDs()
                next.tabs[index].layout = remaining
                next.tabs[index].terminalHistory.removeAll { $0 == pane }
                if next.tabs[index].zoomedPane == pane { next.tabs[index].zoomedPane = nil }
                if next.tabs[index].focusedPane == pane {
                    next.tabs[index].focusedPane = next.tabs[index].activeTerminal ?? remaining.paneIDs[0]
                }
            } else {
                // Retire membership, never the transferred pane record or identity counters.
                next.tabs.remove(at: index)
                for group in next.groups.indices { next.groups[group].tabs.removeAll { $0 == sourceTab } }
                next.groups.removeAll { $0.tabs.isEmpty }
            }
            let destinationIndex = next.tabs.firstIndex { $0.id == destinationTab }!
            next.tabs[destinationIndex].layout = layout
            next.tabs[destinationIndex].zoomedPane = nil
            if selectTarget || followsSelectedPane { next.focus(pane, in: destinationIndex) }
            else if panes.first(where: { $0.id == pane })?.type == .terminal {
                next.tabs[destinationIndex].terminalHistory.append(pane)
            }
            self = next
            return
        }
        let remaining = tabs[index].layout.removing(pane)!
        let replacement = Layout.split(axis: direction.axis, fraction: 0.5,
                                       first: .pane(direction.insertsBefore ? pane : target),
                                       second: .pane(direction.insertsBefore ? target : pane))
        let layout = remaining.replacing(target, with: replacement)
        _ = try layout.checkedPaneIDs()
        tabs[index].layout = layout
        tabs[index].zoomedPane = nil
        if selectTarget { focus(pane, in: index) }
    }

    /// Replace the contents of a slot without changing its layout or identity.
    public mutating func setType(_ pane: PaneID, to type: PaneType) throws {
        let tab = try tabIndex(containing: pane)
        guard let index = panes.firstIndex(where: { $0.id == pane }) else { throw WorkspaceError.paneNotFound(pane) }
        guard panes[index].type != type else { return }
        panes[index].type = type
        if case .registered = type { panes[index].pluginPanel = PluginPanelRecord() }
        else { panes[index].pluginPanel = nil }
        tabs[tab].terminalHistory.removeAll { $0 == pane }
        if type == .terminal {
            if tabs[tab].focusedPane == pane { tabs[tab].terminalHistory.insert(pane, at: 0) }
            else { tabs[tab].terminalHistory.append(pane) }
        }
    }

    /// A user-chosen title belongs to the slot, independently of its content's live title.
    public mutating func setManualTitle(_ title: String, for pane: PaneID) throws {
        guard let index = panes.firstIndex(where: { $0.id == pane }) else { throw WorkspaceError.paneNotFound(pane) }
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 4096 else { throw WorkspaceError.invalidLayout("Manual titles must not exceed 4096 UTF-8 bytes") }
        panes[index].manualTitle = text.isEmpty ? nil : text
    }

    public mutating func setManualTabTitle(_ title: String, for tab: TabID) throws {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { throw WorkspaceError.tabNotFound(tab) }
        tabs[index].manualTitle = try TabTitle.normalized(title)
    }

    public mutating func setHeaderVisible(_ visible: Bool, for pane: PaneID) throws {
        guard let index = panes.firstIndex(where: { $0.id == pane }) else { throw WorkspaceError.paneNotFound(pane) }
        panes[index].headerVisible = visible
    }

    public mutating func close(_ pane: PaneID) throws {
        let index = try tabIndex(containing: pane)
        guard let remaining = tabs[index].layout.removing(pane) else {
            try closeTab(tabs[index].id)
            return
        }
        panes.removeAll { $0.id == pane }
        tabs[index].layout = remaining
        if tabs[index].zoomedPane == pane { tabs[index].zoomedPane = nil }
        tabs[index].terminalHistory.removeAll { $0 == pane }
        if tabs[index].focusedPane == pane {
            // Prefer terminal recency, otherwise the first remaining spatial leaf.
            let previousKeyTab = keyTabID
            focus(tabs[index].activeTerminal ?? remaining.paneIDs[0], in: index)
            keyTabID = previousKeyTab
        }
    }

    public mutating func focus(_ pane: PaneID) throws {
        let index = try tabIndex(containing: pane)
        focus(pane, in: index)
    }

    public mutating func focus(_ pane: PaneID, direction: Direction) throws {
        let index = try tabIndex(containing: pane)
        if let neighbor = tabs[index].layout.neighbor(of: pane, direction: direction) { focus(neighbor, in: index) }
    }

    public mutating func toggleZoom(_ pane: PaneID) throws {
        let index = try tabIndex(containing: pane)
        let wasZoomed = tabs[index].zoomedPane != nil
        focus(pane, in: index)
        tabs[index].zoomedPane = wasZoomed ? nil : pane
    }

    public mutating func equalize(_ tab: TabID) throws {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { throw WorkspaceError.tabNotFound(tab) }
        tabs[index].layout = tabs[index].layout.equalized()
    }

    public mutating func focusTab(_ id: TabID) throws {
        guard tabs.contains(where: { $0.id == id }) else { throw WorkspaceError.tabNotFound(id) }
        keyTabID = id
    }

    @discardableResult
    public mutating func newTab(in group: GroupID? = nil, focus: Bool = true) throws -> TabID {
        if let group, !groups.contains(where: { $0.id == group }) { throw WorkspaceError.groupNotFound(group) }
        try requireAvailable(nextPane)
        try requireAvailable(nextTab)
        if group == nil { try requireAvailable(nextGroup) }
        let tab = TabID(nextTab)
        let pane = PaneID(nextPane)
        nextTab += 1
        nextPane += 1
        panes.append(Pane(id: pane, type: .terminal))
        tabs.append(Tab(id: tab, defaultTitle: defaultTabTitle, layout: .pane(pane), focusedPane: pane, terminalHistory: [pane]))
        if let index = groups.firstIndex(where: { $0.id == group }) {
            groups[index].tabs.append(tab)
        } else {
            groups.append(TabGroup(id: GroupID(nextGroup), tabs: [tab]))
            nextGroup += 1
        }
        if focus || keyTabID == nil { keyTabID = tab }
        return tab
    }

    public mutating func closeTab(_ id: TabID) throws {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { throw WorkspaceError.tabNotFound(id) }
        let removed = Set(tabs[index].layout.paneIDs)
        let siblings = groups.first(where: { $0.tabs.contains(id) })?.tabs.filter { $0 != id } ?? []
        panes.removeAll { removed.contains($0.id) }
        tabs.remove(at: index)
        for index in groups.indices { groups[index].tabs.removeAll { $0 == id } }
        groups.removeAll { $0.tabs.isEmpty }
        if keyTabID == id { keyTabID = siblings.first ?? tabs.first?.id }
    }

    @discardableResult
    public mutating func detach(_ tab: TabID) throws -> GroupID {
        guard tabs.contains(where: { $0.id == tab }), let owner = groups.first(where: { $0.tabs.contains(tab) }) else { throw WorkspaceError.tabNotFound(tab) }
        if owner.tabs.count == 1 { return owner.id }
        try requireAvailable(nextGroup)
        let group = GroupID(nextGroup)
        nextGroup += 1
        for index in groups.indices { groups[index].tabs.removeAll { $0 == tab } }
        groups.removeAll { $0.tabs.isEmpty }
        groups.append(TabGroup(id: group, tabs: [tab]))
        return group
    }

    public mutating func moveTab(_ tab: TabID, to group: GroupID, at index: Int? = nil) throws {
        guard tabs.contains(where: { $0.id == tab }) else { throw WorkspaceError.tabNotFound(tab) }
        guard let destination = groups.firstIndex(where: { $0.id == group }) else { throw WorkspaceError.groupNotFound(group) }
        if groups[destination].tabs.contains(tab), index == nil { return }
        var members = groups[destination].tabs.filter { $0 != tab }
        let insertion = index ?? members.count
        guard insertion >= 0, insertion <= members.count else { throw WorkspaceError.invalidLayout("Tab index is outside the destination's final order") }
        members.insert(tab, at: insertion)
        for index in groups.indices { groups[index].tabs.removeAll { $0 == tab } }
        groups[destination].tabs = members
        groups.removeAll { $0.tabs.isEmpty }
    }

    public mutating func reorderTab(_ tab: TabID, to index: Int) throws {
        guard let group = groups.first(where: { $0.tabs.contains(tab) }) else { throw WorkspaceError.tabNotFound(tab) }
        try moveTab(tab, to: group.id, at: index)
    }

    /// Import native tab drag/reorder/merge operations without recreating tabs or panes.
    public mutating func adoptTabGroups(_ nativeGroups: [[TabID]], retaining identities: [GroupID?]? = nil) throws {
        if let identities {
            let retained = identities.compactMap { $0 }
            guard identities.count == nativeGroups.count, Set(retained).count == retained.count,
                  Set(retained).isSubset(of: Set(groups.map(\.id))) else {
                throw WorkspaceError.invalidSnapshot("Native group identities must be distinct current groups")
            }
        }
        let ids = nativeGroups.flatMap { $0 }
        guard nativeGroups.allSatisfy({ !$0.isEmpty }), ids.count == tabs.count,
              Set(ids) == Set(tabs.map(\.id)) else {
            throw WorkspaceError.invalidSnapshot("Native groups must contain every tab exactly once")
        }
        var used = Set<GroupID>()
        var next = nextGroup
        var result: [TabGroup] = []
        for (index, members) in nativeGroups.enumerated() {
            let id: GroupID
            if let identity = identities?[index] { id = identity }
            else if identities == nil, let existing = groups.first(where: { !used.contains($0.id) && $0.tabs.contains(members[0]) }) {
                id = existing.id
            } else {
                try requireAvailable(next)
                id = GroupID(next)
                next += 1
            }
            used.insert(id)
            result.append(TabGroup(id: id, tabs: members))
        }
        if identities != nil {
            // Window enumeration order is not a group mutation. Retain creation order
            // for surviving identities and append newly discovered native groups.
            let oldOrder = Dictionary(uniqueKeysWithValues: groups.enumerated().map { ($0.element.id, $0.offset) })
            let newOrder = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, groups.count + $0.offset) })
            result.sort { (oldOrder[$0.id] ?? newOrder[$0.id]!) < (oldOrder[$1.id] ?? newOrder[$1.id]!) }
        }
        groups = result
        nextGroup = next
    }

    public mutating func resize(tab: TabID, path: [Branch], fraction: Double) throws {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { throw WorkspaceError.tabNotFound(tab) }
        guard fraction.isFinite, fraction > 0, fraction < 1 else {
            throw WorkspaceError.invalidLayout("Split fractions must be finite and between 0 and 1")
        }
        tabs[index].layout = try tabs[index].layout.resized(path: path[...], fraction: fraction)
    }

    private func tabIndex(containing pane: PaneID) throws -> Int {
        guard let index = tabs.firstIndex(where: { $0.layout.paneIDs.contains(pane) }) else {
            throw WorkspaceError.paneNotFound(pane)
        }
        return index
    }

    private mutating func focus(_ pane: PaneID, in index: Int) {
        tabs[index].focusedPane = pane
        if tabs[index].zoomedPane != nil { tabs[index].zoomedPane = pane }
        keyTabID = tabs[index].id
        if panes.first(where: { $0.id == pane })?.type == .terminal {
            tabs[index].terminalHistory.removeAll { $0 == pane }
            tabs[index].terminalHistory.insert(pane, at: 0)
        }
    }

    private func requireAvailable(_ next: Int) throws {
        guard next > 0, next < Int.max else { throw WorkspaceError.exhaustedIdentities }
    }

    public mutating func setPluginConfiguration(_ configuration: [String: JSONValue], for pane: PaneID) throws {
        guard let index = panes.firstIndex(where: { $0.id == pane }), var record = panes[index].pluginPanel else {
            throw RPCFailure(code: APIError.unavailable, message: "A registered-plugin pane is required")
        }
        try record.configure(configuration)
        var next = self
        next.panes[index].pluginPanel = record
        try next.validatePluginPanels()
        self = next
    }

    public mutating func patchPluginState(_ pane: PaneID, expectedPanelId: String, expectedRevision: String, operations: JSONValue?) throws {
        guard let index = panes.firstIndex(where: { $0.id == pane }), var record = panes[index].pluginPanel else {
            throw RPCFailure(code: APIError.unavailable, message: "A registered-plugin pane is required")
        }
        try record.patch(expectedPanelId: expectedPanelId, expectedRevision: expectedRevision, operations: operations)
        var next = self
        next.panes[index].pluginPanel = record
        try next.validatePluginPanels()
        self = next
    }

    public func validatePluginPanels() throws {
        var ids = Set<String>()
        var bytes = 0
        for pane in panes {
            if case .registered(let id) = pane.type {
                try PluginPersistence.validateID(id)
                guard let record = pane.pluginPanel, ids.insert(record.panelId).inserted else {
                    throw WorkspaceError.invalidSnapshot("Missing or duplicate plugin panel identity")
                }
                try record.validated()
                bytes += try JSONEncoder().encode(record).count
            } else if pane.pluginPanel != nil { throw WorkspaceError.invalidSnapshot("Non-plugin pane has plugin state") }
        }
        guard bytes <= PluginPersistence.workspaceBytes else { throw WorkspaceError.invalidSnapshot("Plugin panel records exceed 2 MiB per workspace") }
    }

    /// Disk encoding is not a public bulk-data API. Explicit plugin APIs read payloads.
    public func publicJSON() throws -> JSONValue {
        var fields = try JSONDecoder().decode(JSONValue.self, from: encoded()).object!
        if case .array(let panes) = fields["panes"] {
            fields["panes"] = .array(panes.map { pane in
                var object = pane.object!
                object.removeValue(forKey: "pluginPanel")
                return .object(object)
            })
        }
        return .object(fields)
    }

    public func encoded() throws -> Data {
        try validatePluginPanels()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Snapshot(schemaVersion: 2, panes: panes, tabs: tabs, groups: groups,
                                          keyTabID: keyTabID, nextPane: nextPane, nextTab: nextTab, nextGroup: nextGroup))
    }

    public static func restore(_ data: Data) throws -> Workspace {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion == 2 else { throw WorkspaceError.invalidSnapshot("Unsupported schema version") }
        let paneIDs = Set(snapshot.panes.map(\.id))
        let tabIDs = Set(snapshot.tabs.map(\.id))
        let groupIDs = Set(snapshot.groups.map(\.id))
        guard paneIDs.count == snapshot.panes.count, tabIDs.count == snapshot.tabs.count,
              groupIDs.count == snapshot.groups.count else {
            throw WorkspaceError.invalidSnapshot("Duplicate identities")
        }
        var leaves: [PaneID] = []
        for tab in snapshot.tabs {
            _ = try TabTitle.canonical(tab.manualTitle)
            let ids = try tab.layout.checkedPaneIDs()
            let terminalIDs = Set(snapshot.panes.filter { ids.contains($0.id) && $0.type == .terminal }.map(\.id))
            guard ids.contains(tab.focusedPane), tab.zoomedPane == nil || tab.zoomedPane == tab.focusedPane,
                  Set(tab.terminalHistory) == terminalIDs,
                  Set(tab.terminalHistory).count == tab.terminalHistory.count,
                  (!terminalIDs.contains(tab.focusedPane) || tab.terminalHistory.first == tab.focusedPane) else {
                throw WorkspaceError.invalidSnapshot("Invalid focus or terminal history")
            }
            leaves += ids
        }
        let groupedTabs = snapshot.groups.flatMap(\.tabs)
        guard leaves.count == paneIDs.count, Set(leaves) == paneIDs,
              groupedTabs.count == tabIDs.count, Set(groupedTabs) == tabIDs,
              snapshot.groups.allSatisfy({ !$0.tabs.isEmpty }),
              (snapshot.keyTabID.map { tabIDs.contains($0) } ?? tabIDs.isEmpty) else {
            throw WorkspaceError.invalidSnapshot("Layout, tab groups, and identities disagree")
        }
        guard snapshot.nextPane > (paneIDs.map(\.number).max() ?? 0),
              snapshot.nextTab > (tabIDs.map(\.number).max() ?? 0),
              snapshot.nextGroup > (groupIDs.map(\.number).max() ?? 0) else {
            throw WorkspaceError.invalidSnapshot("Identity counters would reuse an existing identity")
        }
        var result = Workspace()
        result.panes = snapshot.panes
        result.tabs = snapshot.tabs
        result.groups = snapshot.groups
        result.keyTabID = snapshot.keyTabID
        result.nextPane = snapshot.nextPane
        result.nextTab = snapshot.nextTab
        result.nextGroup = snapshot.nextGroup
        try result.validatePluginPanels()
        return result
    }

    private struct Snapshot: Codable {
        var schemaVersion: Int
        var panes: [Pane]
        var tabs: [Tab]
        var groups: [TabGroup]
        var keyTabID: TabID?
        var nextPane: Int
        var nextTab: Int
        var nextGroup: Int
    }
}
