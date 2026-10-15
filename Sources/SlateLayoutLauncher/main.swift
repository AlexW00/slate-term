import AppKit

@MainActor
final class LauncherDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let text = info["SlateLayoutID"] as? String, let id = UUID(uuidString: text),
              let applicationID = info["SlateApplicationID"] as? String,
              let path = info["SlateApplicationPath"] as? String else {
            fail("The launcher metadata is invalid. Create a new launcher from Saved Layouts."); return
        }
        let original = URL(fileURLWithPath: path)
        let application = Bundle(url: original)?.bundleIdentifier == applicationID ? original : NSWorkspace.shared.urlForApplication(withBundleIdentifier: applicationID)
        guard let application else { fail("Install Slate Terminal to open this layout."); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(string: "slate-term://layout/\(id.uuidString)")!], withApplicationAt: application, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error { self.fail(error.localizedDescription) }
                else { NSApp.terminate(nil) }
            }
        }
    }
    private func fail(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Could not open saved layout"; alert.informativeText = message
        alert.runModal(); NSApp.terminate(nil)
    }
}
let app = NSApplication.shared
let delegate = LauncherDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
withExtendedLifetime(delegate) {}
