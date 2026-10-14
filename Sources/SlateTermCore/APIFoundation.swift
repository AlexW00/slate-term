import Foundation

/// Stable errors shared by native, CLI and page adapters. Safety failures never imply a retry.
public enum APIError {
    public static let conflict = -32050
    public static let unavailable = -32051
    public static let forbidden = -32052
    public static let incompatible = -32053
    public static let settingsWriteFailed = -32054
}

public struct WorkspaceChange: Sendable {
    public let topic: String
    public let tab: TabID?
    public let pane: PaneID?
    public let payload: [String: JSONValue]
}

/// Observes the authoritative value, so legacy/native mutations participate in the same ledger.
/// Rendering, terminal output and filesystem autosave are deliberately not layout revisions.
public struct WorkspaceRevisions: Sendable {
    private let epoch: String
    private var sequence: UInt64 = 0
    private var previous: Workspace
    private var layouts: [TabID: String]
    public var revision: String { "\(epoch):w:\(sequence)" }

    public init(epoch: String, workspace: Workspace) {
        self.epoch = epoch
        previous = workspace
        layouts = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, "\(epoch):\($0.id):0") })
    }

    public func layoutRevision(_ tab: TabID) -> String? { layouts[tab] }

    public func requireWorkspace(_ expected: String) throws {
        guard expected == revision else { throw RPCFailure(code: APIError.conflict, message: "Workspace changed; inspect again before retrying") }
    }

    public func requireLayout(_ expected: String, tab: TabID) throws {
        guard expected == layouts[tab] else { throw RPCFailure(code: APIError.conflict, message: "Layout changed; inspect again before retrying") }
    }

    @discardableResult
    public mutating func observe(_ workspace: Workspace) -> [WorkspaceChange] {
        guard workspace != previous else { return [] }
        sequence += 1
        let before = previous
        previous = workspace
        let oldPanes = Dictionary(uniqueKeysWithValues: before.panes.map { ($0.id, $0) })
        let newPanes = Dictionary(uniqueKeysWithValues: workspace.panes.map { ($0.id, $0) })
        let oldTabs = Dictionary(uniqueKeysWithValues: before.tabs.map { ($0.id, $0) })
        let newTabs = Dictionary(uniqueKeysWithValues: workspace.tabs.map { ($0.id, $0) })
        var changes: [WorkspaceChange] = []
        func append(_ topic: String, tab: TabID? = nil, pane: PaneID? = nil) {
            var payload: [String: JSONValue] = ["workspaceRevision": .string(revision)]
            if let tab { payload["layoutRevision"] = layouts[tab].map(JSONValue.string) ?? .null }
            changes.append(WorkspaceChange(topic: topic, tab: tab, pane: pane, payload: payload))
        }
        for tab in workspace.tabs {
            let old = oldTabs[tab.id]
            let typeChanged = tab.layout.paneIDs.contains { oldPanes[$0]?.type != newPanes[$0]?.type }
            if old?.layout != tab.layout || old?.zoomedPane != tab.zoomedPane || typeChanged {
                layouts[tab.id] = "\(epoch):\(tab.id):\(sequence)"
            }
        }
        for tab in before.tabs where newTabs[tab.id] == nil { layouts.removeValue(forKey: tab.id) }
        for tab in before.tabs where newTabs[tab.id] == nil { append("host.tab.closed", tab: tab.id) }
        for tab in workspace.tabs where oldTabs[tab.id] == nil { append("host.tab.created", tab: tab.id) }
        for pane in before.panes where newPanes[pane.id] == nil {
            append("host.pane.closed", tab: before.tabs.first { $0.layout.paneIDs.contains(pane.id) }?.id, pane: pane.id)
        }
        for pane in workspace.panes {
            let tab = workspace.tabs.first { $0.layout.paneIDs.contains(pane.id) }?.id
            guard let old = oldPanes[pane.id] else { append("host.pane.created", tab: tab, pane: pane.id); continue }
            if old.type != pane.type { append("host.pane.type.changed", tab: tab, pane: pane.id) }
            if old.manualTitle != pane.manualTitle { append("host.pane.title.changed", tab: tab, pane: pane.id) }
        }
        for tab in workspace.tabs {
            guard let old = oldTabs[tab.id] else { continue }
            if old.layout != tab.layout { append("host.layout.changed", tab: tab.id) }
            if old.focusedPane != tab.focusedPane || old.zoomedPane != tab.zoomedPane {
                append("host.focus.changed", tab: tab.id, pane: tab.focusedPane)
            }
        }
        if before.groups != workspace.groups { append("host.tabs.changed") }
        if before.keyTabID != workspace.keyTabID { append("host.focus.changed", tab: workspace.keyTabID) }
        return changes
    }
}

/// Pure routing policy, shared by all typed CLI wrappers. Environment values are hints, not provenance.
public enum APITarget {
    public static func resolve(pane: String? = nil, tab: String? = nil, active: Bool = false,
                               socket: String? = nil, instance: String? = nil, scope: String? = nil, environment: [String: String]) throws -> [String: JSONValue] {
        guard !active || (pane == nil && tab == nil) else { throw RPCFailure(code: -32602, message: "--active cannot be combined with --pane or --tab") }
        let crossApp = (socket != nil && environment["SLATE_TERM_SOCKET"] != nil && socket != environment["SLATE_TERM_SOCKET"])
            || (instance != nil && environment["SLATE_TERM_INSTANCE_ID"] != nil && instance != environment["SLATE_TERM_INSTANCE_ID"])
        if crossApp && pane == nil && tab == nil && !active {
            throw RPCFailure(code: APIError.conflict, message: "Different socket: supply an explicit --pane/--tab or --active; inherited targets belong to another app")
        }
        let inheritedPane = crossApp || active || tab != nil ? nil : environment["SLATE_TERM_PANE_ID"]
        let chosenPane = pane ?? inheritedPane
        let chosenTab = tab ?? (chosenPane == nil && !active && !crossApp ? environment["SLATE_TERM_TAB_ID"] : nil)
        var result: [String: JSONValue] = [:]
        if let chosenPane { _ = try PaneID(parsing: chosenPane); result["pane"] = .string(chosenPane) }
        if let chosenTab { _ = try TabID(parsing: chosenTab); result["tab"] = .string(chosenTab) }
        if let expected = instance ?? (crossApp ? nil : environment["SLATE_TERM_INSTANCE_ID"]) {
            guard !expected.isEmpty else { throw RPCFailure(code: -32602, message: "App instance ID is empty") }
            result["expectedInstanceId"] = .string(expected)
        }
        if !crossApp, !active, chosenPane != nil, chosenPane == environment["SLATE_TERM_PANE_ID"],
           let session = environment["SLATE_TERM_SESSION_ID"] {
            guard !session.isEmpty else { throw RPCFailure(code: -32602, message: "Inherited session ID is empty") }
            result["expectedAnchorSessionId"] = .string(session)
        }
        if let scope {
            guard ["pane", "tab", "global"].contains(scope) else { throw RPCFailure(code: -32602, message: "Unknown terminal scope") }
            result["scope"] = .string(scope)
            if pane == nil && scope != "pane" {
                result.removeValue(forKey: "expectedAnchorSessionId")
                if scope == "tab", let reference = result.removeValue(forKey: "pane") { result["contextPane"] = reference }
                if scope == "global" { result.removeValue(forKey: "pane"); result.removeValue(forKey: "tab") }
            }
        }
        return result
    }
}

/// No retained snapshots: a page is valid only while authoritative topology stays unchanged.
public struct InspectionCursor: Equatable, Codable, Sendable {
    public let revision: String
    public let scope: String
    public let offset: Int
    public let eventCursor: String
    public init(revision: String, scope: String, offset: Int, eventCursor: String) {
        self.revision = revision; self.scope = scope; self.offset = offset; self.eventCursor = eventCursor
    }
    public func encoded() throws -> String { try JSONEncoder().encode(self).base64EncodedString() }
    public static func decode(_ value: String, revision: String, scope: String) throws -> Self {
        guard value.utf8.count <= 4096, let data = Data(base64Encoded: value),
              let cursor = try? JSONDecoder().decode(Self.self, from: data), cursor.offset >= 0,
              cursor.revision == revision, cursor.scope == scope else {
            throw RPCFailure(code: APIError.conflict, message: "Inspection cursor is invalid or stale; restart enumeration")
        }
        return cursor
    }
}
