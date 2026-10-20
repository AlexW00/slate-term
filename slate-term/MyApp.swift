import AppKit

@_cdecl("SlateRuntimeMain")
@MainActor
public func SlateRuntimeMain(_ abiVersion: UInt32) -> Int32 {
    guard abiVersion == 1 else { return 64 }
    do { ApplicationLaunchContext.current = try .resolve() }
    catch { fputs("Invalid application identity: \(error)\n", stderr); return 65 }
    SlateTermApplication.main()
    return 0
}

struct SlateTermApplication {
    @MainActor static func main() {
        let integration = ProcessInfo.processInfo.environment["SLATE_TERM_INTEGRATION"] == "1"
        if integration { fputs("Integration startup: creating NSApplication\n", stderr) }
        let app = NSApplication.shared
        if integration { fputs("Integration startup: NSApplication ready\n", stderr) }
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        // Window-free cleanup of a fixture-owned named store, in the same bundle namespace.
        // Never enabled in ordinary launches; the fixture stops its app before invoking this.
        if ProcessInfo.processInfo.environment["SLATE_TERM_INTEGRATION"] == "1",
           CommandLine.arguments.dropFirst() == ["--remove-test-browser-profile"],
           let root = ProcessInfo.processInfo.environment["SLATE_TERM_STATE_DIR"] {
            app.delegate = nil
            app.setActivationPolicy(.prohibited)
            Task {
                do {
                    try await BrowserData.removeTestProfile(directory: (ApplicationLaunchContext.current.descriptor?.base ?? URL(fileURLWithPath: root)).appendingPathComponent("state"))
                    exit(0)
                } catch {
                    fputs("Test browser profile cleanup failed: \(error)\n", stderr)
                    exit(1)
                }
            }
            app.run()
            return
        }
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private var host: WorkspaceHost?
    private var pendingLayoutURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            NSWindow.allowsAutomaticWindowTabbing = false
            let resources = RuntimeBundle.bundle.resourceURL!.appendingPathComponent("ghostty").path
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
            let integration = ProcessInfo.processInfo.environment["SLATE_TERM_INTEGRATION"] == "1"
            if integration { fputs("Integration startup: creating workspace host\n", stderr) }
            let host = try WorkspaceHost()
            self.host = host
            if integration { fputs("Integration startup: starting workspace host\n", stderr) }
            try host.start()
            if integration { fputs("Integration startup: workspace ready\n", stderr) }
            for url in pendingLayoutURLs { host.openLayoutURL(url) }
            pendingLayoutURLs.removeAll()
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            fputs("\(ApplicationLaunchContext.current.displayName) startup failed: \(error)\n", stderr)
            if ProcessInfo.processInfo.environment["SLATE_TERM_INTEGRATION"] != "1" {
                let alert = NSAlert()
                alert.messageText = "\(ApplicationLaunchContext.current.displayName) could not start"
                alert.informativeText = String(describing: error)
                if let failure = error as? LayoutAppRestorationFailure {
                    alert.messageText = "\(ApplicationLaunchContext.current.displayName) couldn’t restore its session"
                    alert.addButton(withTitle: "Quit")
                    alert.addButton(withTitle: "Show in Finder")
                    if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([failure.file]) }
                } else { alert.runModal() }
            }
            host?.close()
            exit(1)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let host { urls.forEach(host.openLayoutURL) }
        else { pendingLayoutURLs.append(contentsOf: urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let host else { return .terminateNow }
        if host.isTerminating { return .terminateLater }
        guard host.confirmTermination() else { return .terminateCancel }
        host.prepareForTermination { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) { host?.setApplicationFocused(true) }
    func applicationDidResignActive(_ notification: Notification) { host?.setApplicationFocused(false) }
    func applicationWillTerminate(_ notification: Notification) { host?.close() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        host?.showWorkspaceWindow()
        return false
    }
}
