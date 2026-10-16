import AppKit

@MainActor
final class WorkspaceWindow: NSWindow {
    let identity = "window-" + UUID().uuidString
    var keybindingHandler: ((NSEvent) -> Bool)?

    override func toggleTabOverview(_ sender: Any?) {
        // AppKit's native action can be a no-op on macOS 27 even though the
        // group's overview works. Use the public visibility setter directly.
        guard let group = tabGroup else { return }
        group.isOverviewVisible.toggle()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keybindingHandler?(event) == true { return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keybindingHandler?(event) == true { return true }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
