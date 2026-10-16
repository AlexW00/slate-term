import Foundation

public struct WorkspaceCommand: Sendable, Codable {
    public let id: String
    public let title: String
    public let key: String
    public let shift: Bool
    public let alt: Bool
    public let control: Bool
    public let contract: CommandContract

    public init(id: String, title: String, key: String, shift: Bool, alt: Bool = false, control: Bool = false) {
        self.id = id
        self.title = title
        self.key = key
        self.shift = shift
        self.alt = alt
        self.control = control
        self.contract = .forCommand(id)
    }

    private enum CodingKeys: String, CodingKey { case id, title, key, shift, alt, control, contract }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        key = try values.decode(String.self, forKey: .key)
        shift = try values.decode(Bool.self, forKey: .shift)
        alt = try values.decodeIfPresent(Bool.self, forKey: .alt) ?? false
        control = try values.decodeIfPresent(Bool.self, forKey: .control) ?? false
        contract = try values.decodeIfPresent(CommandContract.self, forKey: .contract) ?? .forCommand(id)
    }
}

public enum CommandRegistry {
    public static let commands: [WorkspaceCommand] = [
        .init(id: "command.picker", title: "Search Commands…", key: "k", shift: false),
        .init(id: "settings.open", title: "Open Settings", key: ",", shift: false),
        .init(id: "notifications.next", title: "Jump to Next Notification", key: "", shift: false),
        .init(id: "notifications.open", title: "Open Notification Source", key: "", shift: false),
        .init(id: "notifications.settings", title: "Notification Settings…", key: "", shift: false),
        .init(id: "layouts.edit", title: "Layout Settings…", key: "", shift: false),
        .init(id: "layouts.openWindow", title: "Open Layout in New Window…", key: "", shift: false),
        .init(id: "layouts.captureWindow", title: "Save a Window as a Layout…", key: "", shift: false),
        .init(id: "layouts.launcher", title: "Create Spotlight Launcher…", key: "", shift: false),
        .init(id: "layouts.folder", title: "Open Layouts Folder", key: "", shift: false),
        .init(id: "tab.new", title: "New Tab", key: "t", shift: false),
        .init(id: "window.new", title: "New Window", key: "n", shift: false),
        .init(id: "split.right", title: "Split Right", key: "d", shift: false),
        .init(id: "split.down", title: "Split Down", key: "d", shift: true),
        .init(id: "split.left", title: "Split Left", key: "d", shift: false, alt: true),
        .init(id: "split.up", title: "Split Up", key: "d", shift: true, alt: true),
        .init(id: "focus.left", title: "Focus Left", key: "left", shift: false, alt: true),
        .init(id: "focus.right", title: "Focus Right", key: "right", shift: false, alt: true),
        .init(id: "focus.up", title: "Focus Above", key: "up", shift: false, alt: true),
        .init(id: "focus.down", title: "Focus Below", key: "down", shift: false, alt: true),
        .init(id: "pane.zoom", title: "Maximize / Restore Pane Size", key: "return", shift: true),
        .init(id: "layout.equalize", title: "Equalize Panes", key: "e", shift: true),
        .init(id: "pane.split", title: "Split Pane or Tab Root", key: "", shift: false),
        .init(id: "pane.move", title: "Move Pane", key: "", shift: false),
        .init(id: "pane.move.chooseDestination", title: "Move Pane…", key: "", shift: false),
        .init(id: "layout.resize", title: "Resize Split", key: "", shift: false),
        .init(id: "pane.header.show", title: "Show Pane Bar", key: "", shift: false),
        .init(id: "pane.header.hide", title: "Hide Pane Bar", key: "", shift: false),
        .init(id: "pane.header.toggle", title: "Toggle Pane Bar", key: "", shift: false),
        .init(id: "pane.rename", title: "Rename Pane…", key: "", shift: false),
        .init(id: "pane.title.set", title: "Set Pane Title", key: "", shift: false),
        .init(id: "pane.title.clear", title: "Clear Pane Title", key: "", shift: false),
        .init(id: "tab.rename", title: "Rename Tab…", key: "", shift: false),
        .init(id: "tab.title.set", title: "Set Tab Title", key: "", shift: false),
        .init(id: "tab.title.clear", title: "Reset Tab Name", key: "", shift: false),
        .init(id: "tab.reorder", title: "Reorder Tab", key: "", shift: false),
        .init(id: "tab.move", title: "Move Tab to Group", key: "", shift: false),
        .init(id: "tab.detach", title: "Detach Tab", key: "", shift: false),
        .init(id: "tab.detachCurrent", title: "Move Tab to New Window", key: "n", shift: false, control: true),
        .init(id: "window.focus", title: "Focus Native Window", key: "", shift: false),
        .init(id: "window.frame.set", title: "Set Native Window Frame", key: "", shift: false),
        .init(id: "window.minimize", title: "Minimize Native Window", key: "", shift: false),
        .init(id: "window.restore", title: "Restore Native Window", key: "", shift: false),
        .init(id: "window.fullscreen.set", title: "Set Native Window Fullscreen", key: "", shift: false),
        .init(id: "pane.type", title: "Change Pane Type", key: "", shift: false),
        .init(id: "pane.copyID", title: "Copy Pane ID", key: "", shift: false),
        .init(id: "pane.close", title: "Close Pane", key: "w", shift: false),
        .init(id: "pane.focus", title: "Focus Pane", key: "", shift: false),
        .init(id: "tab.close", title: "Close Tab", key: "w", shift: true),
        .init(id: "tab.next", title: "Next Tab", key: "]", shift: true),
        .init(id: "tab.previous", title: "Previous Tab", key: "[", shift: true),
        .init(id: "tab.select1", title: "Select Tab 1", key: "1", shift: false),
        .init(id: "tab.select2", title: "Select Tab 2", key: "2", shift: false),
        .init(id: "tab.select3", title: "Select Tab 3", key: "3", shift: false),
        .init(id: "tab.select4", title: "Select Tab 4", key: "4", shift: false),
        .init(id: "tab.select5", title: "Select Tab 5", key: "5", shift: false),
        .init(id: "tab.select6", title: "Select Tab 6", key: "6", shift: false),
        .init(id: "tab.select7", title: "Select Tab 7", key: "7", shift: false),
        .init(id: "tab.select8", title: "Select Tab 8", key: "8", shift: false),
        .init(id: "tab.select9", title: "Select Tab 9", key: "9", shift: false),
        .init(id: "tab.focus", title: "Focus Tab", key: "", shift: false),
        .init(id: "browser.back", title: "Go Back", key: "[", shift: false),
        .init(id: "browser.forward", title: "Go Forward", key: "]", shift: false),
        .init(id: "browser.focusAddress", title: "Focus Address Bar", key: "l", shift: false),
        .init(id: "plugins.reload", title: "Reload Plugin", key: "", shift: false),
        .init(id: "browser.reload", title: "Reload Page", key: "r", shift: false),
        .init(id: "browser.clearData", title: "Clear Browser Data…", key: "", shift: false),
        .init(id: "browser.clearSiteData", title: "Clear This Site’s Data…", key: "", shift: false),
        .init(id: "config.reload", title: "Reload Configuration", key: "r", shift: true),
        .init(id: "appearance.set", title: "Set Appearance", key: "", shift: false),
        .init(id: "appearance.light", title: "Use Light Appearance", key: "", shift: false),
        .init(id: "appearance.dark", title: "Use Dark Appearance", key: "", shift: false),
        .init(id: "appearance.auto", title: "Follow System Appearance", key: "", shift: false),
        .init(id: "terminal.palette.set", title: "Set Terminal Palette", key: "", shift: false),
        .init(id: "terminal.font.set", title: "Set Application Terminal Font Size", key: "", shift: false),
        .init(id: "terminal.font.increase", title: "Increase Application Terminal Font Size", key: "", shift: false),
        .init(id: "terminal.font.decrease", title: "Decrease Application Terminal Font Size", key: "", shift: false),
        .init(id: "terminal.font.reset", title: "Reset Application Terminal Font Size", key: "", shift: false),
        .init(id: "warnings.close.set", title: "Set Close Warning Suppression", key: "", shift: false),
        .init(id: "warnings.type.set", title: "Set Pane Type Warning Suppression", key: "", shift: false),
        .init(id: "warnings.close.reset", title: "Re-enable Close Warnings", key: "", shift: false),
        .init(id: "warnings.type.reset", title: "Re-enable Pane Type Warnings", key: "", shift: false),
        .init(id: "welcome.read", title: "Mark Welcome Message as Read", key: "", shift: false),
        .init(id: "welcome.unread", title: "Mark Welcome Message as Unread", key: "", shift: false),
        .init(id: "welcome.reset", title: "Reset Welcome Message (Mark Unread)", key: "", shift: false),
        .init(id: "skills.settings", title: "Install Agent Skill…", key: "", shift: false),
        .init(id: "skills.reveal", title: "Open Agent Skill Folder", key: "", shift: false),
        .init(id: "agents.activity.show", title: "Show Agent Activity", key: "", shift: false),
        .init(id: "agents.activity.hide", title: "Hide Agent Activity", key: "", shift: false),
        .init(id: "agents.activity.toggle", title: "Toggle Agent Activity", key: "", shift: false),
    ]

    public static func execute(_ id: String, params: [String: JSONValue], workspace: inout Workspace) throws -> JSONValue {
        guard commands.contains(where: { $0.id == id }) else {
            throw RPCFailure(code: -32601, message: "Unknown command: \(id)")
        }
        if let result = try WorkspaceMutationCommand.execute(id, params: params, workspace: &workspace) { return result }
        func pane() throws -> PaneID {
            if let value = params["pane"] {
                _ = try tab()
                return try PaneID(parsing: requireString(value, name: "pane"))
            }
            if let tabValue = params["tab"] {
                let tab = try TabID(parsing: requireString(tabValue, name: "tab"))
                guard let pane = workspace.tabs.first(where: { $0.id == tab })?.focusedPane else {
                    throw WorkspaceError.tabNotFound(tab)
                }
                return pane
            }
            guard let pane = workspace.tabs.first(where: { $0.id == workspace.keyTabID })?.focusedPane else {
                throw RPCFailure(code: -32004, message: "There is no focused pane")
            }
            return pane
        }
        func tab() throws -> TabID {
            try workspace.resolvedTab(
                pane: params["pane"].map { try PaneID(parsing: requireString($0, name: "pane")) },
                tab: params["tab"].map { try TabID(parsing: requireString($0, name: "tab")) }).id
        }
        switch id {
        case "split.left", "split.right", "split.up", "split.down":
            let direction = Direction(rawValue: String(id.dropFirst("split.".count)))!
            let target = try pane()
            let result = try workspace.split(target, direction: direction)
            return .object(["paneId": .string(result.description)])
        case "focus.left", "focus.right", "focus.up", "focus.down":
            try workspace.focus(pane(), direction: Direction(rawValue: String(id.dropFirst("focus.".count)))!)
        case "pane.zoom": try workspace.toggleZoom(pane())
        case "layout.equalize": try workspace.equalize(tab())
        case "pane.type":
            guard let value = params["type"] else { throw RPCFailure(code: -32602, message: "type is required") }
            let name = try requireString(value, name: "type")
            guard !name.isEmpty else { throw RPCFailure(code: -32602, message: "type must not be empty") }
            let type = PaneType(identifier: name)
            try workspace.setType(pane(), to: type)
        case "pane.close":
            let target = try pane()
            try workspace.close(target)
        case "pane.focus":
            let target = try pane()
            try workspace.focus(target)
        case "tab.new":
            let existing = params["tab"] == nil && workspace.keyTabID == nil ? nil : try tab()
            let group = workspace.groups.first { $0.tabs.contains(where: { $0 == existing }) }?.id
            if let existing, group == nil { throw WorkspaceError.tabNotFound(existing) }
            return .object(["tabId": .string(try workspace.newTab(in: group).description)])
        case "window.new":
            return .object(["tabId": .string(try workspace.newTab().description)])
        case "tab.close":
            let target = try tab()
            try workspace.closeTab(target)
        case "tab.next", "tab.previous", "tab.select1", "tab.select2", "tab.select3", "tab.select4", "tab.select5", "tab.select6", "tab.select7", "tab.select8", "tab.select9":
            let current = try tab()
            guard let siblings = workspace.groups.first(where: { $0.tabs.contains(current) })?.tabs,
                  let index = siblings.firstIndex(of: current) else { throw WorkspaceError.tabNotFound(current) }
            let targetIndex: Int
            if id == "tab.next" { targetIndex = (index + 1) % siblings.count }
            else if id == "tab.previous" { targetIndex = (index + siblings.count - 1) % siblings.count }
            else { targetIndex = Int(id.dropFirst("tab.select".count))! - 1 }
            if siblings.indices.contains(targetIndex) { try workspace.focusTab(siblings[targetIndex]) }
        case "tab.focus":
            let target = try tab()
            try workspace.focusTab(target)
        default: throw RPCFailure(code: -32601, message: "Command requires an application handler: \(id)")
        }
        return .object([:])
    }

    private static func requireString(_ value: JSONValue, name: String) throws -> String {
        guard let string = value.string else { throw RPCFailure(code: -32602, message: "\(name) must be a string") }
        return string
    }
}
