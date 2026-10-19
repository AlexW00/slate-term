import AppKit

/// Sparse native regression gate: only these owned windows receive scripted input.
@main
@MainActor
struct TabOverview {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            try require(Date() < deadline, "\(message) (key: \(NSApp.keyWindow.map { NSStringFromClass(type(of: $0)) } ?? "nil"), active: \(NSApp.isActive))")
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    static func nativeView(_ className: String, in view: NSView) -> NSView? {
        // Only discover AppKit's native chrome; dispatch uses public menu/event APIs.
        if NSStringFromClass(type(of: view)) == className { return view }
        return view.subviews.lazy.compactMap { nativeView(className, in: $0) }.first
    }

    static func overviewMenu(in window: WorkspaceWindow, target: WorkspaceWindow? = nil) throws -> (NSMenu, Int) {
        guard let frame = window.contentView?.superview, let bar = nativeView("NSTabBar", in: frame) else {
            throw Failure(description: "Native tab bar not found")
        }
        let location = bar.convert(NSPoint(x: bar.bounds.width * 0.75, y: bar.bounds.midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        var view = frame.hitTest(location)
        while let candidate = view {
            if let menu = candidate.menu(for: event),
               let index = menu.items.firstIndex(where: { $0.action == #selector(NSWindow.toggleTabOverview(_:)) }) {
                menu.update()
                try require(menu.items[index].isEnabled, "Native overview menu item is disabled")
                try require(menu.items[index].target === (target ?? window), "Native overview menu targets another window")
                return (menu, index)
            }
            view = candidate.superview
        }
        throw Failure(description: "Native Show All Tabs menu item not found")
    }

    static func trackedRenameItem(in menu: NSMenu, window: WorkspaceWindow) throws -> NSMenuItem {
        let close: @MainActor () -> Void = { menu.cancelTracking() }
        let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
            MainActor.assumeIsolated { close() }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        menu.popUp(positioning: nil, at: NSPoint(x: 150, y: 250), in: window.contentView)
        menu.update()
        guard let rename = menu.items.first(where: { $0.title == "Rename Tab…" }) else {
            throw Failure(description: "Tracked native tab menu has no Rename Tab item")
        }
        try require(menu.items.filter { $0.title == "Rename Tab…" }.count == 1, "Duplicate rename items")
        return rename
    }

    static func key(_ characters: String, code: UInt16, in picker: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: picker.windowNumber,
                                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        NSApp.sendEvent(event)
    }

    static func run() async throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        let windows = (1...2).map { index in
            let window = WorkspaceWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Owned Tab Overview \(index)"
            window.isReleasedWhenClosed = false
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "slate-tab-overview-fixture"
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let label = NSTextField(labelWithString: window.title)
            label.frame = NSRect(x: 40, y: 180, width: 400, height: 40)
            content.addSubview(label)
            window.contentView = content
            return window
        }
        defer {
            windows.first?.tabGroup?.isOverviewVisible = false
            windows.forEach { $0.close() }
        }
        let first = windows[0], second = windows[1]
        var renamed: [WorkspaceWindow] = []
        first.renameTabHandler = { renamed.append(first) }
        second.renameTabHandler = { renamed.append(second) }
        defer { windows.forEach { $0.renameTabHandler = nil } }
        try require(!first.canShowAllTabs, "Single-tab overview should be unavailable")
        first.addTabbedWindow(second, ordered: .above)
        second.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await eventually("Fixture did not acquire key focus") { NSApp.isActive && second.isKeyWindow }
        guard let group = second.tabGroup else { throw Failure(description: "Native tab group missing") }
        try require(group.windows.count == 2 && group.selectedWindow === second, "Unexpected initial group")
        second.fullscreenTransitionPending = true
        try require(!first.canShowAllTabs && !second.canShowAllTabs, "Background target bypassed the selected tab transition")
        second.fullscreenTransitionPending = false
        try require(second.canShowAllTabs, "Multiple-tab overview should be available")
        try second.showAllTabs()
        try await eventually("Shared show action did not open overview") { group.isOverviewVisible }
        try await Task.sleep(for: .milliseconds(700))
        try first.showAllTabs()
        try require(group.isOverviewVisible, "Repeated show must not close overview")
        group.isOverviewVisible = false
        try await eventually("Overview did not close after shared action") { second.isKeyWindow }
        let (menu, index) = try overviewMenu(in: second)

        menu.performActionForItem(at: index)
        try await eventually("Show All Tabs did not open the native overview") { group.isOverviewVisible }
        try await eventually("Native picker did not become key") {
            NSApp.keyWindow.map { NSStringFromClass(type(of: $0)) == "NSTabPickerWindow" } == true
        }
        try require(group.selectedWindow === second && group.windows.count == 2, "Opening changed native selection/membership")

        // The picker becomes key before its opening animation completes. Allow
        // native presentation to settle before sending the next user gesture.
        try await Task.sleep(for: .milliseconds(700))
        // The same action must also close the overview, not just force it visible.
        menu.performActionForItem(at: index)
        try await eventually("Overview action did not toggle closed") { !group.isOverviewVisible }
        try require(group.selectedWindow === second, "Toggling closed changed selection")
        try await eventually("Toggling closed did not restore key focus") { second.isKeyWindow }

        menu.performActionForItem(at: index)
        try await eventually("Overview did not reopen for Escape") {
            group.isOverviewVisible && NSApp.keyWindow !== second && NSApp.keyWindow != nil
        }
        try await Task.sleep(for: .milliseconds(700))
        key("\u{1b}", code: 53, in: NSApp.keyWindow!)
        try await eventually("Escape did not exit the native overview") { !group.isOverviewVisible && second.isKeyWindow }
        try require(group.selectedWindow === second, "Escape changed selection")

        menu.performActionForItem(at: index)
        try await eventually("Overview did not reopen for tab selection") {
            group.isOverviewVisible && NSApp.keyWindow !== second && NSApp.keyWindow != nil
        }
        try await Task.sleep(for: .milliseconds(700))
        let picker = NSApp.keyWindow!
        guard let content = picker.contentView,
              let tile = nativeView("NSVisualTabPickerTileContainerView", in: content) else {
            throw Failure(description: "Native overview thumbnail not found")
        }
        let point = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: picker.windowNumber,
                                          context: nil, eventNumber: 2, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
        }
        try await eventually("Native overview selection did not activate the first tab") {
            !group.isOverviewVisible && group.selectedWindow === first && first.isKeyWindow
        }
        try require(group.windows.count == 2 && first.tabGroup === group && second.tabGroup === group,
                    "Overview changed native tab membership")
        // Right-clicking a background tab must preserve selection until Rename is chosen.
        let (backgroundMenu, _) = try overviewMenu(in: first, target: second)
        let backgroundRename = try trackedRenameItem(in: backgroundMenu, window: first)
        try require(backgroundRename.target === second && backgroundRename.isEnabled, "Rename targets the wrong background tab")
        try require(group.selectedWindow === first && renamed.isEmpty, "Opening the menu renamed or selected a tab")
        backgroundMenu.performActionForItem(at: backgroundMenu.index(of: backgroundRename))
        try await eventually("Background rename did not select its own tab") { group.selectedWindow === second && second.isKeyWindow }
        try require(renamed.count == 1 && renamed[0] === second, "Rename did not dispatch to the clicked tab")

        let (selectedMenu, _) = try overviewMenu(in: second)
        let selectedRename = try trackedRenameItem(in: selectedMenu, window: second)
        try require(selectedRename.target === second && selectedRename.isEnabled, "Selected tab rename unavailable")
        _ = try trackedRenameItem(in: selectedMenu, window: second)
        selectedMenu.performActionForItem(at: selectedMenu.index(of: selectedRename))
        try require(renamed.count == 2 && renamed.last === second, "Selected rename dispatched incorrectly")

        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        second.beginSheet(sheet, completionHandler: nil)
        selectedMenu.update()
        try require(!second.canShowAllTabs && !first.canShowAllTabs, "Overview enabled while a sheet is attached")
        try require(!selectedRename.isEnabled, "Rename enabled while a sheet is attached")
        second.endSheet(sheet)
        sheet.orderOut(nil)
        print("PASS native tab context menu rename for selected/background tabs, repeat opening and sheet validation")
        print("PASS native Show All Tabs menu dispatch, toggle close, Escape, reopen and thumbnail tab selection")
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                fputs("FAIL tab overview: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
