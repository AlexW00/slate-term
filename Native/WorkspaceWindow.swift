import AppKit
import SlateTermCore

@MainActor
final class WorkspaceWindow: NSWindow {
    let identity = "window-" + UUID().uuidString
    var keybindingHandler: ((NSEvent) -> Bool)?
    var renameTabHandler: (() -> Void)? {
        didSet {
            NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
            if renameTabHandler != nil {
                NotificationCenter.default.addObserver(self, selector: #selector(tabMenuWillTrack(_:)),
                                                      name: NSMenu.didBeginTrackingNotification, object: nil)
            }
        }
    }
    var fullscreenTransitionPending = false
    var fullscreenTransition = "idle"
    var presentationRevision = UUID().uuidString
    var presentationSample: [String: JSONValue]?

    @objc private func tabMenuWillTrack(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              menu.items.contains(where: { $0.action == #selector(NSWindow.moveTabToNewWindow(_:)) && $0.target === self }),
              !menu.items.contains(where: { $0.action == #selector(renameTabFromMenu(_:)) }) else { return }
        let item = NSMenuItem(title: "Rename Tab…", action: #selector(renameTabFromMenu(_:)), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    private var canRenameTabFromMenu: Bool {
        let selected = tabGroup?.selectedWindow ?? self
        return renameTabHandler != nil && selected.isVisible && !selected.isMiniaturized
            && selected.attachedSheet == nil && attachedSheet == nil && NSApp.modalWindow == nil
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(renameTabFromMenu(_:)) { return canRenameTabFromMenu }
        return super.validateMenuItem(menuItem)
    }

    @objc private func renameTabFromMenu(_ sender: Any?) {
        guard canRenameTabFromMenu else { return }
        makeKeyAndOrderFront(nil)
        renameTabHandler?()
    }

    override func toggleFullScreen(_ sender: Any?) {
        guard !fullscreenTransitionPending else { return }
        fullscreenTransitionPending = true
        fullscreenTransition = styleMask.contains(.fullScreen) ? "exiting" : "entering"
        super.toggleFullScreen(sender)
    }

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
