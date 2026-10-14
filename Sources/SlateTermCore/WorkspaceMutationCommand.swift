import Foundation

/// Shared, model-only command adapter. The native host additionally enforces revisions,
/// renderable minimum geometry, registered content availability and resource preparation.
public enum WorkspaceMutationCommand {
    public static let ids: Set<String> = ["pane.split", "pane.move", "layout.resize", "pane.title.set", "pane.title.clear",
                                         "tab.reorder", "tab.detach", "tab.move", "tab.detachCurrent"]
    public static let layoutGuarded: Set<String> = ["pane.split", "pane.move", "layout.resize"]
    public static let workspaceGuarded: Set<String> = ["tab.reorder", "tab.detach", "tab.move"]

    public static func execute(_ id: String, params: [String: JSONValue], workspace: inout Workspace) throws -> JSONValue? {
        guard ids.contains(id) else { return nil }
        let allowed = Set(CommandContract.forCommand(id).parameters.keys).union(APIGuards.names).union(["id", "pane", "tab", "force"])
        guard Set(params.keys).isSubset(of: allowed) else { throw invalid("Unknown parameters: \(Set(params.keys).subtracting(allowed).sorted().joined(separator: ", "))") }
        if let force = params["force"], case .bool = force {} else if params["force"] != nil { throw invalid("force must be a boolean") }
        func string(_ key: String, default fallback: String? = nil) throws -> String {
            guard let value = params[key] else { if let fallback { return fallback }; throw invalid("\(key) is required") }
            guard let result = value.string else { throw invalid("\(key) must be a string") }
            return result
        }
        func number(_ key: String, default fallback: Double? = nil) throws -> Double {
            guard let value = params[key] else { if let fallback { return fallback }; throw invalid("\(key) is required") }
            switch value {
            case .integer(let number): return Double(number)
            case .number(let number) where number.isFinite: return number
            default: throw invalid("\(key) must be a finite number")
            }
        }
        func index() throws -> Int {
            guard case .integer(let value) = params["index"] else { throw invalid("index must be an integer") }
            return value
        }
        let pane = try params["pane"].map { _ in try PaneID(parsing: string("pane")) }
        let tab = try workspace.resolvedTab(pane: pane, tab: params["tab"].map { _ in try TabID(parsing: string("tab")) })
        let targetPane = pane ?? tab.focusedPane
        func direction() throws -> Direction {
            guard let direction = try Direction(rawValue: string("direction")) else { throw invalid("direction must be left, right, up or down") }
            return direction
        }
        // Use a value candidate so even multi-step commands leave counters/focus intact on failure.
        var next = workspace
        var result: [String: JSONValue] = ["tabId": .string(tab.id.description)]
        switch id {
        case "pane.split":
            let target = try string("target", default: "pane")
            guard ["pane", "root"].contains(target) else { throw invalid("target must be pane or root") }
            let typeName = try string("type", default: "terminal")
            guard !typeName.isEmpty else { throw invalid("type must not be empty") }
            let type: PaneType = typeName == "terminal" ? .terminal : typeName == "browser" ? .browser : .registered(typeName)
            guard let focus = try PaneSplitFocus(rawValue: string("focus", default: "new")) else { throw invalid("focus must be new or preserve") }
            let fraction = try number("newPaneFraction", default: 0.5)
            let created = try target == "root"
                ? next.splitRoot(tab.id, direction: direction(), type: type, newPaneFraction: fraction, focus: focus)
                : next.split(targetPane, direction: direction(), type: type, newPaneFraction: fraction, focus: focus)
            result["paneId"] = .string(created.description)
        case "pane.move":
            guard tab.zoomedPane == nil else { throw RPCFailure(code: APIError.unavailable, message: "Unzoom the tab before moving a pane") }
            let target = try PaneID(parsing: string("target"))
            try next.move(targetPane, beside: target, direction: direction())
            result["paneId"] = .string(targetPane.description)
        case "layout.resize":
            guard tab.zoomedPane == nil else { throw RPCFailure(code: APIError.unavailable, message: "Unzoom the tab before resizing its layout") }
            guard case .array(let raw) = params["path"], raw.count <= 64 else { throw invalid("path must be an array of at most 64 first/second branches") }
            let path = try raw.map { value -> Branch in
                guard let name = value.string, let branch = Branch(rawValue: name) else { throw invalid("path branches must be first or second") }
                return branch
            }
            try next.resize(tab: tab.id, path: path, fraction: number("firstChildFraction"))
        case "pane.title.set", "pane.title.clear":
            try next.setManualTitle(id == "pane.title.clear" ? "" : string("title"), for: targetPane)
            result["paneId"] = .string(targetPane.description)
        case "tab.reorder", "tab.move", "tab.detach", "tab.detachCurrent":
            let focus = try string("focus", default: id == "tab.detachCurrent" ? "target" : "preserve")
            guard ["target", "preserve"].contains(focus) else { throw invalid("focus must be target or preserve") }
            if id == "tab.reorder" { try next.reorderTab(tab.id, to: index()) }
            else if id == "tab.move" {
                let group = try GroupID(parsing: string("group"))
                try next.moveTab(tab.id, to: group, at: params["index"] == nil ? nil : index())
            } else { _ = try next.detach(tab.id) }
            if focus == "target" { try next.focusTab(tab.id) }
            result["groupId"] = next.groups.first(where: { $0.tabs.contains(tab.id) }).map { .string($0.id.description) }
        default: return nil
        }
        workspace = next
        return .object(result)
    }

    private static func invalid(_ message: String) -> RPCFailure { RPCFailure(code: -32602, message: message) }
}
