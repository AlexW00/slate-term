import Foundation

/// Shared argument/target contract for discovery and invocation through command.run.
public struct CommandContract: Codable, Sendable {
    public let requiresArguments: Bool
    public let workspaceIndependent: Bool
    public let parameters: [String: String]
    public let required: [String]
    public let additionalParameters: Bool
    public let retry: String

    public static func forCommand(_ id: String) -> Self {
        let global = id.hasPrefix("appearance.") || id.hasPrefix("terminal.font.") || id.hasPrefix("terminal.palette.")
            || id.hasPrefix("warnings.") || id.hasPrefix("skills.") || id.hasPrefix("plugins.") || id.hasPrefix("window.frame.")
            || ["window.focus", "window.minimize", "window.restore", "window.fullscreen.set", "tab.detachCurrent"].contains(id)
        let independent = id.hasPrefix("layouts.") || (global && id != "tab.detachCurrent") || ["window.new", "settings.open", "config.reload", "command.picker", "browser.clearData"].contains(id)
        let parameters: [String: String]
        let required: [String]
        switch id {
        // Native invocation captures the current URL; API invocation requires it.
        case "browser.clearSiteData": parameters = ["url": "absolute HTTP(S) URL, required through API"]; required = []
        case "appearance.set": parameters = ["mode": "light|dark|auto"]; required = ["mode"]
        case "terminal.font.set": parameters = ["size": "number[1,256]"]; required = ["size"]
        case "terminal.palette.set": parameters = ["slot": "light|dark", "name": "string"]; required = ["slot", "name"]
        case "pane.split":
            parameters = ["direction": "left|right|up|down", "target": "pane|root", "type": "pane-type", "newPaneFraction": "number(0,1)", "focus": "new|preserve", "expectedLayoutRevision": "string"]
            required = ["direction", "expectedLayoutRevision"]
        case "pane.move": parameters = ["target": "pane-id", "direction": "left|right|up|down", "expectedLayoutRevision": "string"]; required = ["target", "direction", "expectedLayoutRevision"]
        case "layout.resize": parameters = ["path": "array<first|second>", "firstChildFraction": "number(0,1)", "expectedLayoutRevision": "string"]; required = ["path", "firstChildFraction", "expectedLayoutRevision"]
        case "pane.title.set": parameters = ["title": "string<=4096 UTF-8 bytes after trimming"]; required = ["title"]
        case "tab.reorder": parameters = ["index": "integer>=0", "focus": "target|preserve", "expectedWorkspaceRevision": "string"]; required = ["index", "expectedWorkspaceRevision"]
        case "tab.move": parameters = ["group": "group-id", "index": "integer>=0", "focus": "target|preserve", "expectedWorkspaceRevision": "string"]; required = ["group", "expectedWorkspaceRevision"]
        case "tab.detach": parameters = ["focus": "target|preserve", "expectedWorkspaceRevision": "string"]; required = ["expectedWorkspaceRevision"]
        case "pane.type": parameters = ["type": "pane-type"]; required = ["type"]
        case "pane.focus": parameters = ["pane": "pane-id"]; required = ["pane"]
        case "tab.focus": parameters = ["tab": "tab-id"]; required = ["tab"]
        case "window.focus": parameters = ["windowId": "native-window-id", "activate": "boolean"]; required = ["windowId"]
        default: parameters = [:]; required = []
        }
        return Self(requiresArguments: !required.isEmpty,
                    workspaceIndependent: independent, parameters: parameters, required: required,
                    additionalParameters: id.hasPrefix("plugin."), retry: "never-automatic")
    }
}
