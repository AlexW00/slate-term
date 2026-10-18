import AppKit
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    func captureRestoration() -> WorkspaceRestoration {
        var result = WorkspaceRestoration()
        for pane in workspace.panes {
            let key = pane.id.description
            if pane.type == .terminal,
               let directory = shellSessions[pane.id]?.report?.workingDirectory ?? terminals[pane.id]?.context.workingDirectory ?? terminals[pane.id]?.startingDirectory,
               WorkspaceRestoration.allowsDirectory(directory) {
                result.directories[key] = directory
            } else if pane.type == .browser, let browser = leaves[pane.id] as? BrowserPane,
                      let url = browser.restorationURL, WorkspaceRestoration.allowsBrowserURL(url) {
                result.browserURLs[key] = url
            }
        }
        windowedRestorationFrames = windowedRestorationFrames.filter { key, _ in workspace.groups.contains { $0.id.description == key } }
        for group in workspace.groups {
            guard let anchor = group.tabs.compactMap({ windows[$0] }).first else { continue }
            let window = anchor.tabGroup?.selectedWindow ?? anchor
            // Keep the last windowed frame across full-screen transitions and quit.
            guard !window.styleMask.contains(.fullScreen), !fullScreenTransitions.contains(ObjectIdentifier(window)) else { continue }
            let frame = WorkspaceRestoration.Frame(window.frame)
            if frame.isValid { windowedRestorationFrames[group.id.description] = frame }
        }
        result.windowFrames = windowedRestorationFrames
        return result
    }

    func restorationDirectory(_ saved: String?) -> String? {
        guard let saved else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: saved, isDirectory: &directory), directory.boolValue,
              FileManager.default.isExecutableFile(atPath: saved) else { return NSHomeDirectory() }
        return saved
    }

    func restorationFrame(_ saved: WorkspaceRestoration.Frame) -> NSRect {
        let screens = ([NSScreen.main].compactMap { $0 } + NSScreen.screens.filter { $0 !== NSScreen.main })
            .map { WorkspaceRestoration.Frame($0.visibleFrame) }
        let frame = saved.fitted(to: screens)
        return NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }
}

private extension WorkspaceRestoration.Frame {
    init(_ rect: NSRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
}
