import AppKit

@main
struct SlateTermApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
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
            let resources = Bundle.main.resourceURL!.appendingPathComponent("ghostty").path
            setenv("GHOSTTY_RESOURCES_DIR", resources, 1)
            let host = try WorkspaceHost()
            self.host = host
            try host.start()
            for url in pendingLayoutURLs { host.openLayoutURL(url) }
            pendingLayoutURLs.removeAll()
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            fputs("Slate Terminal startup failed: \(error)\n", stderr)
            if ProcessInfo.processInfo.environment["SLATE_TERM_INTEGRATION"] != "1" {
                let alert = NSAlert()
                alert.messageText = "Slate Terminal could not start"
                alert.informativeText = String(describing: error)
                alert.runModal()
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
        host?.confirmTermination() == false ? .terminateCancel : .terminateNow
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
