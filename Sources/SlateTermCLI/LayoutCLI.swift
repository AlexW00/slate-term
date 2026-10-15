import ArgumentParser
import Foundation
import SlateTermCore

struct Tabs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect, create, close, focus or safely rearrange native tabs.")
    enum Action: String, ExpressibleByArgument { case list, new, close, focus, reorder, detach, move }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    @Option(help: "Destination group ID for move.") var group: String?
    @Option(help: "Zero-based final index; move appends when omitted.") var index: Int?
    @Option(help: "target or preserve (default) for rearrangement.") var focusPolicy: String?
    func run() throws {
        var params = try target.params(connection: connection)
        let mutation = [Action.reorder, .detach, .move].contains(action)
        if mutation {
            guard target.expectedWorkspaceRevision != nil else { throw ValidationError("Tab rearrangement requires --expected-workspace-revision") }
            if let focusPolicy { params["focus"] = .string(focusPolicy) }
            if let index { params["index"] = .integer(index) }
            if let group { params["group"] = .string(group) }
            if action == .move, group == nil { throw ValidationError("move requires --group") }
            if action == .reorder, index == nil { throw ValidationError("reorder requires --index") }
            if action != .move && group != nil { throw ValidationError("--group is only valid for move") }
            if action == .detach && index != nil { throw ValidationError("detach does not take --index") }
        } else if group != nil || index != nil || focusPolicy != nil { throw ValidationError("Rearrangement options require reorder, detach or move") }
        if action == .list { try connection.call("tabs.list", params: params) }
        else {
            params["id"] = .string("tab.\(action.rawValue)")
            try connection.call("command.run", params: params)
        }
    }
}

struct Panes: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect panes; split, move, title or control their contents.")
    enum Action: String, ExpressibleByArgument {
        case list, inspect, split, move, close, focus, send, capture, type
        case setTitle = "set-title", clearTitle = "clear-title"
        case showHeader = "show-header", hideHeader = "hide-header", toggleHeader = "toggle-header"
    }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    @Flag var left = false
    @Flag var right = false
    @Flag var up = false
    @Flag var down = false
    @Flag(help: "Split the entire tab root instead of a leaf.") var root = false
    @Option(help: "Fraction assigned to the new pane, independent of edge.") var newPaneFraction: Double?
    @Option(help: "new (default) or preserve for split focus.") var focusPolicy: String?
    @Option(help: "Destination pane ID for move.") var destination: String?
    @Option(help: "Manual pane title, at most 4096 UTF-8 bytes after trimming.") var title: String?
    @Option(help: "Literal input text for send. No shell escaping is added.") var text: String?
    @Option(help: "Content type for type/atomic split: terminal, browser or a registered panel.") var type: String?
    @Option(help: "Require this terminal session for send/capture.") var sessionId: String?
    func run() throws {
        var params = try target.params(connection: connection)
        let directions = [(left, "left"), (right, "right"), (up, "up"), (down, "down")].filter(\.0)
        if action != .split && (root || newPaneFraction != nil || focusPolicy != nil) { throw ValidationError("Root/fraction/focus options require split") }
        if action != .move && destination != nil { throw ValidationError("--destination requires move") }
        if action != .setTitle && title != nil { throw ValidationError("--title requires set-title") }
        if action != .send && text != nil { throw ValidationError("--text requires send") }
        if action != .split && action != .move && !directions.isEmpty { throw ValidationError("Direction flags require split or move") }
        if action != .split && action != .type && type != nil { throw ValidationError("--type requires split or type") }
        if let sessionId {
            guard action == .send || action == .capture else { throw ValidationError("session-id is only valid for send/capture") }
            params["sessionId"] = .string(sessionId)
            params.removeValue(forKey: "expectedAnchorSessionId")
        }
        switch action {
        case .inspect: try connection.call("pane.inspect", params: params)
        case .type:
            guard let type else { throw ValidationError("type requires --type") }
            params["id"] = .string("pane.type"); params["type"] = .string(type)
            try connection.call("command.run", params: params)
        case .list: try connection.call("panes.list", params: params)
        case .capture: try connection.call("panes.capture", params: params)
        case .send:
            guard let text else { throw ValidationError("send requires --text") }
            params["text"] = .string(text)
            try connection.call("panes.send", params: params)
        case .split, .move:
            guard directions.count == 1 else { throw ValidationError("Choose exactly one of --left, --right, --up, --down") }
            let advanced = root || newPaneFraction != nil || focusPolicy != nil || type != nil || action == .move
            if advanced {
                guard target.expectedLayoutRevision != nil else { throw ValidationError("Atomic split/move options require --expected-layout-revision") }
                params["id"] = .string(action == .split ? "pane.split" : "pane.move")
                params["direction"] = .string(directions[0].1)
                if action == .move {
                    guard let destination else { throw ValidationError("move requires --destination") }
                    params["target"] = .string(destination)
                } else {
                    params["target"] = .string(root ? "root" : "pane")
                    if let type { params["type"] = .string(type) }
                    if let newPaneFraction { params["newPaneFraction"] = .number(newPaneFraction) }
                    if let focusPolicy { params["focus"] = .string(focusPolicy) }
                }
            } else { params["id"] = .string("split.\(directions[0].1)") }
            try connection.call("command.run", params: params)
        case .setTitle, .clearTitle:
            params["id"] = .string(action == .setTitle ? "pane.title.set" : "pane.title.clear")
            if action == .setTitle {
                guard let title else { throw ValidationError("set-title requires --title") }
                params["title"] = .string(title)
            }
            try connection.call("command.run", params: params)
        case .showHeader, .hideHeader, .toggleHeader:
            let id = action == .showHeader ? "pane.header.show" : action == .hideHeader ? "pane.header.hide" : "pane.header.toggle"
            params["id"] = .string(id)
            try connection.call("command.run", params: params)
        case .close, .focus:
            params["id"] = .string("pane.\(action.rawValue)")
            try connection.call("command.run", params: params)
        }
    }
}

struct LayoutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "layout", abstract: "Read a layout or resize a revision-guarded split.")
    enum Action: String, ExpressibleByArgument { case get, resize }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    @Option(help: "Dot-separated first/second branches; empty addresses the root.") var path: String = ""
    @Option(help: "Fraction of space assigned to the first child, excluding the divider.") var firstChildFraction: Double?
    func run() throws {
        var params = try target.params(connection: connection)
        if action == .get {
            guard path.isEmpty, firstChildFraction == nil else { throw ValidationError("Resize options require layout resize") }
            try connection.call("layout.get", params: params)
        } else {
            guard let firstChildFraction, target.expectedLayoutRevision != nil else { throw ValidationError("resize requires --first-child-fraction and --expected-layout-revision") }
            params["id"] = .string("layout.resize")
            params["path"] = .array(path.isEmpty ? [] : path.components(separatedBy: ".").map(JSONValue.string))
            params["firstChildFraction"] = .number(firstChildFraction)
            try connection.call("command.run", params: params)
        }
    }
}

struct WindowsCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "windows", abstract: "Inspect or focus app-owned native windows by stable lifetime ID.")
    enum Action: String, ExpressibleByArgument { case list, get, focus }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @Option var windowId: String?
    @Option(help: "Window page size, 1...64 (default 32).") var limit: Int?
    @Option(help: "Opaque revision-bound nextCursor from window.list.") var cursor: String?
    @Option var expectedWorkspaceRevision: String?
    @Flag(help: "Also activate the application when focusing.") var activate = false
    func run() throws {
        var params: [String: JSONValue] = [:]
        if let expectedWorkspaceRevision { params["expectedWorkspaceRevision"] = .string(expectedWorkspaceRevision) }
        if action != .focus && activate { throw ValidationError("--activate requires windows focus") }
        if action != .list && (limit != nil || cursor != nil) { throw ValidationError("Pagination options require windows list") }
        if action == .list {
            guard windowId == nil else { throw ValidationError("list does not take --window-id") }
            if let limit { params["limit"] = .integer(limit) }
            if let cursor { params["cursor"] = .string(cursor) }
            try connection.call("window.list", params: params)
        } else {
            guard let windowId else { throw ValidationError("get/focus require --window-id from windows list") }
            params["windowId"] = .string(windowId)
            if action == .get { try connection.call("window.get", params: params) }
            else {
                params["id"] = .string("window.focus"); params["activate"] = .bool(activate)
                try connection.call("command.run", params: params)
            }
        }
    }
}
