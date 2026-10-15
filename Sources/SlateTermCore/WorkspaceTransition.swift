import Foundation

/// Explicit model/revision candidate and bounded semantic facts. Preparing this value has no
/// native, journal or filesystem effects. The host must preflight publication and resources,
/// then commit it without suspension; persistence is a separate outcome.
public struct WorkspaceTransition: Sendable {
    public let workspace: Workspace
    public let revisions: WorkspaceRevisions
    public let changes: [WorkspaceChange]
    public let result: JSONValue
    public let changed: Bool
    public let beforeWorkspaceRevision: String
    private let previousWorkspace: Workspace

    /// Revalidate immediately before assignment, after provisional resource preparation.
    public func requireCurrentBase(workspace: Workspace, revisions: WorkspaceRevisions) throws {
        guard workspace == previousWorkspace, revisions.revision == beforeWorkspaceRevision,
              revisions.represents(workspace) else { throw Self.staleRevisionLedger() }
    }

    /// Non-command entry points still declare their semantic action. These labels are not
    /// provenance: the host separately binds the real native/socket/page origin.
    public enum Observation: String, Sendable {
        case nativeFocus = "native.focus", nativeTabs = "native.tabs", nativeResize = "native.resize"
        case startup = "native.startup", windowFocus = "window.focus", pluginRemoval = "plugins.unregister"
        case savedLayoutOpen = "layouts.open"
    }

    public init(observing next: Workspace, from previous: Workspace, revisions: WorkspaceRevisions,
                action: Observation) throws {
        try self.init(previous: previous, next: next, revisions: revisions, action: action.rawValue,
                      result: .object([:]), split: nil, move: nil)
    }

    /// Execute the authoritative model adapter once. Only explicitly selected validated fields
    /// become facts; arbitrary input dictionaries (including titles) are never retained or copied.
    public static func command(_ id: String, parameters: [String: JSONValue], workspace: Workspace,
                               revisions: WorkspaceRevisions) throws -> Self {
        guard revisions.represents(workspace) else { throw staleRevisionLedger() }
        var next = workspace
        let result = try CommandRegistry.execute(id, params: parameters, workspace: &next)
        func anchor() throws -> PaneID {
            let pane = try parameters["pane"].flatMap(\.string).map(PaneID.init(parsing:))
            let tab = try parameters["tab"].flatMap(\.string).map(TabID.init(parsing:))
            return try pane ?? workspace.resolvedTab(pane: pane, tab: tab).focusedPane
        }
        var action = id
        var split: Split?
        var move: Move?
        if id == "pane.split" || id.hasPrefix("split.") {
            action = "pane.split"
            let advanced = id == "pane.split"
            guard let created = result.object?["paneId"]?.string else { throw staleRevisionLedger() }
            let fraction: Double
            switch advanced ? parameters["newPaneFraction"] : nil {
            case .number(let value): fraction = value
            case .integer(let value): fraction = Double(value)
            default: fraction = 0.5
            }
            split = Split(pane: try PaneID(parsing: created), anchor: try anchor(),
                          target: advanced ? parameters["target"]?.string ?? "pane" : "pane",
                          direction: advanced ? parameters["direction"]!.string! : String(id.dropFirst("split.".count)),
                          fraction: fraction, focus: advanced ? parameters["focus"]?.string ?? "new" : "new")
        } else if id == "pane.move" {
            move = Move(pane: try anchor(), destination: try PaneID(parsing: parameters["target"]!.string!),
                        direction: parameters["direction"]!.string!)
        } else if id.hasPrefix("focus.") { action = "pane.focus" }
        else if id == "tab.next" || id == "tab.previous" || id.hasPrefix("tab.select") { action = "tab.focus" }
        else if id == "tab.detachCurrent" { action = "tab.detach" }
        return try Self(previous: workspace, next: next, revisions: revisions, action: action,
                        result: result, split: split, move: move)
    }

    private init(previous: Workspace, next: Workspace, revisions beforeRevisions: WorkspaceRevisions,
                 action: String, result: JSONValue, split: Split?, move: Move?) throws {
        guard beforeRevisions.represents(previous) else { throw Self.staleRevisionLedger() }
        workspace = next
        previousWorkspace = previous
        beforeWorkspaceRevision = beforeRevisions.revision
        self.result = result
        changed = previous != next
        var ledger = beforeRevisions
        let compatibility = ledger.observe(next)
        revisions = ledger
        guard changed else { changes = []; return }
        var facts: [WorkspaceChange] = []
        func append(_ topic: String, tab: TabID? = nil, pane: PaneID? = nil, extra: [String: JSONValue] = [:]) {
            var payload = extra
            payload["actionKind"] = .string(action)
            payload["beforeWorkspaceRevision"] = .string(beforeRevisions.revision)
            payload["workspaceRevision"] = .string(ledger.revision)
            if let tab {
                payload["tabId"] = .string(tab.description)
                payload["beforeLayoutRevision"] = beforeRevisions.layoutRevision(tab).map(JSONValue.string) ?? .null
                payload["layoutRevision"] = ledger.layoutRevision(tab).map(JSONValue.string) ?? .null
            }
            if let pane { payload["paneId"] = .string(pane.description) }
            facts.append(WorkspaceChange(topic: topic, tab: tab, pane: pane, payload: payload))
        }
        let panes = Dictionary(uniqueKeysWithValues: next.panes.map { ($0.id, $0) })
        // Closures precede owning-tab closure; creation reverses that dependency.
        for topic in ["host.pane.closed", "host.tab.closed", "host.tab.created", "host.pane.created", "host.pane.type.changed", "host.pane.title.changed"] {
            for fact in compatibility where fact.topic == topic {
                var extra: [String: JSONValue] = [:]
                if let pane = fact.pane.flatMap({ panes[$0] }) {
                    if topic == "host.pane.created" || topic == "host.pane.type.changed" { extra["type"] = .string(Self.typeName(pane.type)) }
                    if topic == "host.pane.title.changed" { extra["hasManualTitle"] = .bool(pane.manualTitle != nil) }
                    if topic == "host.pane.created", let split, split.pane == pane.id {
                        extra.merge(["anchor": .string(split.anchor.description), "targetKind": .string(split.target),
                                     "direction": .string(split.direction), "newPaneFraction": .number(split.fraction),
                                     "focus": .string(split.focus)]) { _, new in new }
                    }
                }
                append(fact.topic, tab: fact.tab, pane: fact.pane, extra: extra)
            }
        }
        if let move, let tab = next.tabs.first(where: { $0.layout.paneIDs.contains(move.pane) }),
           previous.tabs.first(where: { $0.id == tab.id })?.layout != tab.layout {
            append("host.pane.moved", tab: tab.id, pane: move.pane,
                   extra: ["destinationPaneId": .string(move.destination.description), "direction": .string(move.direction)])
        }
        // A path is a resize only while the same two pane partitions still identify its split.
        // Creation, collapse and relocation must not masquerade as a divider resize.
        func resized(_ before: Layout, _ after: Layout, tab: TabID, path: [Branch]) {
            guard case .split(let oldAxis, let oldFraction, let oldFirst, let oldSecond) = before,
                  case .split(let axis, let fraction, let first, let second) = after else { return }
            if oldAxis == axis, Set(oldFirst.paneIDs) == Set(first.paneIDs), Set(oldSecond.paneIDs) == Set(second.paneIDs), oldFraction != fraction {
                append("host.layout.resized", tab: tab, extra: ["path": .array(path.map { .string($0.rawValue) }),
                        "beforeFraction": .number(oldFraction), "afterFraction": .number(fraction)])
            }
            resized(oldFirst, first, tab: tab, path: path + [.first])
            resized(oldSecond, second, tab: tab, path: path + [.second])
        }
        for tab in next.tabs {
            if let old = previous.tabs.first(where: { $0.id == tab.id }) { resized(old.layout, tab.layout, tab: tab.id, path: []) }
        }
        let oldPositions = Self.positions(previous)
        let newPositions = Self.positions(next)
        for moved in [true, false] {
            for tab in next.tabs {
                guard let before = oldPositions[tab.id], let after = newPositions[tab.id],
                      (before.group != after.group) == moved,
                      before.group != after.group || before.index != after.index else { continue }
                var extra: [String: JSONValue] = ["beforeIndex": .integer(before.index), "afterIndex": .integer(after.index)]
                if moved {
                    extra["beforeGroupId"] = .string(before.group.description)
                    extra["afterGroupId"] = .string(after.group.description)
                } else { extra["groupId"] = .string(after.group.description) }
                append(moved ? "host.tab.moved" : "host.tab.reordered", tab: tab.id, extra: extra)
            }
        }
        for fact in compatibility where ["host.layout.changed", "host.focus.changed", "host.tabs.changed"].contains(fact.topic) {
            append(fact.topic, tab: fact.tab, pane: fact.pane)
        }
        append("host.workspace.changed", extra: ["keyTabId": next.keyTabID.map { .string($0.description) } ?? .null])
        changes = facts
    }

    private struct Split {
        let pane: PaneID
        let anchor: PaneID
        let target: String
        let direction: String
        let fraction: Double
        let focus: String
    }
    private struct Move { let pane: PaneID; let destination: PaneID; let direction: String }
    private struct Position { let group: GroupID; let index: Int }
    private static func positions(_ workspace: Workspace) -> [TabID: Position] {
        Dictionary(uniqueKeysWithValues: workspace.groups.flatMap { group in
            group.tabs.enumerated().map { ($0.element, Position(group: group.id, index: $0.offset)) }
        })
    }
    private static func typeName(_ type: PaneType) -> String {
        switch type { case .terminal: "terminal"; case .browser: "browser"; case .registered(let id): id }
    }
    private static func staleRevisionLedger() -> RPCFailure {
        RPCFailure(code: APIError.conflict, message: "Workspace and revision ledger disagree; commit native observations before preparing another operation")
    }
}
