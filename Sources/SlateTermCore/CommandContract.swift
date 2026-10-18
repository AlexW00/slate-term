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
            || id.hasPrefix("warnings.") || id.hasPrefix("skills.") || id.hasPrefix("agents.activity.") || id.hasPrefix("welcome.") || (id.hasPrefix("plugins.") && !["plugins.reload", "plugins.panelState.reset"].contains(id)) || id.hasPrefix("window.frame.")
            || ["window.focus", "window.minimize", "window.restore", "window.fullscreen.set", "tab.detachCurrent"].contains(id)
        let independent = id.hasPrefix("notifications.") || (id.hasPrefix("layouts.") && id != "layouts.captureWindow") || (global && id != "tab.detachCurrent") || ["window.new", "settings.open", "config.reload", "command.picker", "browser.clearData", "updates.check", "updates.show"].contains(id)
        let parameters: [String: String]
        let required: [String]
        switch id {
        // Native invocation captures the current URL; API invocation requires it.
        case "browser.clearSiteData": parameters = ["url": "absolute HTTP(S) URL, required through API"]; required = []
        case "notifications.open": parameters = ["notificationId": "outstanding notification ID"]; required = ["notificationId"]
        case "appearance.set": parameters = ["mode": "light|dark|auto"]; required = ["mode"]
        case "terminal.font.set": parameters = ["size": "number[1,256]"]; required = ["size"]
        case "terminal.palette.set": parameters = ["slot": "light|dark", "name": "string"]; required = ["slot", "name"]
        case "pane.split":
            parameters = ["direction": "left|right|up|down", "target": "pane|root", "type": "pane-type", "newPaneFraction": "number(0,1)", "focus": "new|preserve", "expectedLayoutRevision": "string"]
            required = ["direction", "expectedLayoutRevision"]
        case "pane.move": parameters = ["target": "destination-pane-id (same app, any tab/window)", "direction": "left|right|up|down", "expectedLayoutRevision": "source-layout-revision", "expectedWorkspaceRevision": "string (required for cross-tab movement)"]; required = ["target", "direction", "expectedLayoutRevision"]
        case "layout.resize": parameters = ["path": "array<first|second>", "firstChildFraction": "number(0,1)", "expectedLayoutRevision": "string"]; required = ["path", "firstChildFraction", "expectedLayoutRevision"]
        case "pane.title.set": parameters = ["title": "string<=4096 UTF-8 bytes after trimming"]; required = ["title"]
        case "tab.title.set": parameters = ["title": "string<=100 characters/1024 UTF-8 bytes after trimming, without controls; empty clears"]; required = ["title"]
        case "tab.reorder": parameters = ["index": "integer>=0", "focus": "target|preserve", "expectedWorkspaceRevision": "string"]; required = ["index", "expectedWorkspaceRevision"]
        case "tab.move": parameters = ["group": "group-id", "index": "integer>=0", "focus": "target|preserve", "expectedWorkspaceRevision": "string"]; required = ["group", "expectedWorkspaceRevision"]
        case "tab.detach": parameters = ["focus": "target|preserve", "expectedWorkspaceRevision": "string"]; required = ["expectedWorkspaceRevision"]
        case "plugins.panelState.reset": parameters = ["expectedPanelId": "string", "expectedStateRevision": "string"]; required = ["expectedPanelId", "expectedStateRevision"]
        case "pane.type": parameters = ["type": "pane-type"]; required = ["type"]
        case "pane.focus": parameters = ["pane": "pane-id"]; required = ["pane"]
        case "tab.focus": parameters = ["tab": "tab-id"]; required = ["tab"]
        case "window.focus": parameters = ["windowId": "native-window-id", "activate": "boolean"]; required = ["windowId"]
        case "window.frame.set": parameters = ["windowId": "native-window-id", "x": "finite number", "y": "finite number", "width": "positive finite number", "height": "positive finite number"]; required = ["windowId", "x", "y", "width", "height"]
        case "window.minimize", "window.restore": parameters = ["windowId": "native-window-id"]; required = ["windowId"]
        case "window.fullscreen.set": parameters = ["windowId": "native-window-id", "fullscreen": "boolean"]; required = ["windowId", "fullscreen"]
        case "warnings.close.set", "warnings.type.set": parameters = ["suppressed": "boolean"]; required = ["suppressed"]
        default: parameters = [:]; required = []
        }
        return Self(requiresArguments: !required.isEmpty,
                    workspaceIndependent: independent, parameters: parameters, required: required,
                    additionalParameters: id.hasPrefix("plugin."), retry: "never-automatic")
    }
}
