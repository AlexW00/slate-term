import Foundation

/// One source of truth for discovery and invocation policy, including indirect command.run.
public struct CommandContract: Codable, Sendable {
    public let pluginAccessible: Bool
    public let requiresArguments: Bool
    public let workspaceIndependent: Bool
    public let parameters: [String: String]
    public let required: [String]
    public let additionalParameters: Bool
    public let retry: String

    public static func forCommand(_ id: String) -> Self {
        // config.reload is an explicit compatibility exception: existing registered
        // pages could invoke it before settings-write APIs existed. New writes stay administrative.
        let administrative = id.hasPrefix("appearance.") || id.hasPrefix("terminal.font.") || id.hasPrefix("terminal.palette.")
            || id.hasPrefix("warnings.") || id.hasPrefix("plugins.") || id.hasPrefix("window.frame.")
            || ["window.focus", "window.minimize", "window.restore", "window.fullscreen.set"].contains(id)
        let independent = administrative || ["window.new", "settings.open", "config.reload", "command.picker"].contains(id)
        let parameters: [String: String]
        let required: [String]
        switch id {
        case "appearance.set": parameters = ["mode": "light|dark|auto"]; required = ["mode"]
        case "terminal.font.set": parameters = ["size": "number[1,256]"]; required = ["size"]
        case "terminal.palette.set": parameters = ["slot": "light|dark", "name": "string"]; required = ["slot", "name"]
        case "pane.type": parameters = ["type": "pane-type"]; required = ["type"]
        case "pane.focus": parameters = ["pane": "pane-id"]; required = ["pane"]
        case "tab.focus": parameters = ["tab": "tab-id"]; required = ["tab"]
        default: parameters = [:]; required = []
        }
        return Self(pluginAccessible: !administrative, requiresArguments: !required.isEmpty,
                    workspaceIndependent: independent, parameters: parameters, required: required,
                    additionalParameters: id.hasPrefix("plugin."), retry: "never-automatic")
    }
}
