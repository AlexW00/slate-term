import AppKit
import SlateTermCore

@main
@MainActor
struct DividerGate {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        for axis in [Axis.horizontal, .vertical] { try exercise(axis, app: app) }
        print("PASS owned divider input: real window dispatch, previews, descendant fractions, leaf minimum, release, Escape and detached-view cleanup")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NSError(domain: message, code: 1) }
    }

    static func pump(_ app: NSApplication, seconds: Double = 0.08) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) { app.sendEvent(event) }
            app.updateWindows()
        }
    }

    static func exercise(_ axis: Axis, app: NSApplication) throws {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1001, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Owned divider verification — \(axis.rawValue)"
        window.appearance = NSAppearance(named: axis == .horizontal ? .aqua : .darkAqua)
        defer { window.close() }
        var leaves: [NSView] = []
        func leaf(_ name: String) -> NSViewController {
            let controller = NSViewController()
            controller.view = NSView()
            controller.view.wantsLayer = true
            let label = NSTextField(labelWithString: name)
            label.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(label)
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor), label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor)])
            let pane = PaneContainer(content: controller, type: "Terminal", typeID: "terminal")
            leaves.append(pane.view)
            return pane
        }
        func add(_ child: NSViewController, to split: WorkspaceSplitController) {
            let item = NSSplitViewItem(viewController: child)
            item.minimumThickness = LayoutSizing.minimumLeafExtent
            item.holdingPriority = WorkspaceSplitController.paneHoldingPriority
            split.addSplitViewItem(item)
        }
        let child = WorkspaceSplitController(fraction: 0.25)
        child.splitView.isVertical = axis == .horizontal
        add(leaf("Pane 1"), to: child); add(leaf("Pane 2"), to: child)
        let root = WorkspaceSplitController(fraction: 0.5)
        root.splitView.isVertical = axis == .horizontal
        add(child, to: root); add(leaf("Pane 3"), to: root)
        let frame = window.frame
        window.contentViewController = root
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        pump(app)
        root.applyInitialFractions()
        pump(app)
        let layout = Layout.split(axis: axis, fraction: 0.5, first: .split(axis: axis, fraction: 0.25, first: .pane(PaneID(1)), second: .pane(PaneID(2))), second: .pane(PaneID(3)))
        var begins = 0, previews: [Double] = [], ends: [Bool] = [], ordinary = 0
        var rootResizes: [Double] = []
        var pending: Double?
        var committed = 0.5
        root.onResize = { rootResizes.append($0); ordinary += 1 }
        child.onResize = { _ in ordinary += 1 }
        root.onGestureBegin = {
            begins += 1; pending = nil
            return try? LayoutSizing.resizeRange(of: layout, in: .init(width: root.splitView.bounds.width, height: root.splitView.bounds.height), divider: root.splitView.dividerThickness)
        }
        root.onGesturePreview = { previews.append($0); pending = $0 }
        root.onGestureEnd = { cancelled in
            ends.append(cancelled)
            if !cancelled, let pending { committed = pending; root.adoptModelFraction(pending) }
            if !root.isDetaching { root.applyInitialFractions() }
        }
        func length(_ split: WorkspaceSplitController) -> Double { Double((axis == .horizontal ? split.splitView.bounds.width : split.splitView.bounds.height) - split.splitView.dividerThickness) }
        func first(_ split: WorkspaceSplitController) -> Double { Double(axis == .horizontal ? split.splitView.arrangedSubviews[0].frame.width : split.splitView.arrangedSubviews[0].frame.height) }
        func point(_ position: Double) -> NSPoint {
            let view = root.splitView, bounds = view.bounds
            let local = axis == .horizontal ? NSPoint(x: bounds.minX + position, y: bounds.midY)
                : NSPoint(x: bounds.midX, y: view.isFlipped ? bounds.minY + position : bounds.maxY - position)
            return view.convert(local, to: nil)
        }
        func post(_ type: NSEvent.EventType, _ position: Double) {
            let event = NSEvent.mouseEvent(with: type, location: point(position), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            app.postEvent(event, atStart: false); pump(app)
        }
        func down() { post(.leftMouseDown, first(root) + Double(root.splitView.dividerThickness) / 2) }
        func drag(_ fraction: Double) { post(.leftMouseDragged, length(root) * fraction + Double(root.splitView.dividerThickness) / 2) }
        func geometry() throws {
            try require(leaves.allSatisfy { $0.frame.width >= 80 && $0.frame.height >= 80 }, "Preview violated a native leaf minimum")
            try require(abs(first(child) - length(child) * 0.25) <= 1 / window.backingScaleFactor, "Preview lost the descendant model fraction")
        }
        func legacyPixel() throws {
            root.onGestureBegin = nil
            root.adoptModelFraction(0.5)
            root.applyInitialFractions(); pump(app)
            let count = rootResizes.count
            root.splitView.setPosition(first(root) + 1 / window.backingScaleFactor, ofDividerAt: 0)
            pump(app)
            try require(rootResizes.count > count, "A one-device-pixel legacy divider move was lost")
        }
        if ProcessInfo.processInfo.environment["SLATE_DIVIDER_CASE"] == "legacy-pixel" { try legacyPixel(); return }
        post(.leftMouseDown, length(root) * 0.95)
        post(.leftMouseDragged, length(root) * 0.94)
        post(.leftMouseUp, length(root) * 0.94)
        try require(begins == 0 && previews.isEmpty && ends.isEmpty, "Leaf-background input started a divider gesture")
        down()
        let hitPoint = root.splitView.convert(point(first(root) + Double(root.splitView.dividerThickness) / 2), from: nil)
        let hit = root.splitView.hitTest(hitPoint)
        try require(begins == 1 && root.isTrackingDivider, "Divider begin failed: begins=\(begins), ends=\(ends), active=\(app.isActive), key=\(window.isKeyWindow), bounds=\(root.splitView.bounds), hit=\(String(describing: hit))")
        drag(0.05)
        try geometry()
        if ProcessInfo.processInfo.environment["SLATE_CAPTURE_DIVIDERS"] == "1" {
            pump(app, seconds: 0.3)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), "artifacts/divider-preview-\(axis.rawValue).png"]
            try capture.run(); capture.waitUntilExit()
            try require(capture.terminationStatus == 0, "Owned divider capture failed")
        }
        try require(previews.count == 1 && ends.isEmpty, "Preview committed early")
        drag(0.75)
        try geometry()
        try require(previews.count == 2 && ends.isEmpty && ordinary == 0, "Preview emitted ordinary resize callbacks")
        post(.leftMouseUp, length(root) * 0.75 + Double(root.splitView.dividerThickness) / 2)
        try require(ends == [false] && !root.isTrackingDivider, "Mouse-up did not complete exactly once")
        down(); drag(0.05)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        app.postEvent(escape, atStart: false); pump(app)
        try require(ends == [false, true] && !root.isTrackingDivider, "Escape did not cancel exactly once")
        try require(abs(first(root) - length(root) * committed) <= 1 / window.backingScaleFactor, "Cancellation did not restore the model fraction")
        let count = previews.count
        drag(0.6); post(.leftMouseUp, length(root) * 0.6)
        try require(previews.count == count && ends.count == 2, "Cancelled input resumed or completed twice")
        down(); drag(0.05)
        window.contentViewController = nil
        pump(app)
        try require(ends == [false, true, true] && !root.isTrackingDivider, "Detachment did not retire the gesture")
        window.contentViewController = root
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        pump(app)
        try require(abs(first(root) - length(root) * committed) <= 1 / window.backingScaleFactor, "Reattached view retained a cancelled preview")
        post(.leftMouseUp, first(root))
        try require(ends.count == 3 && ordinary == 0, "Retired view emitted late completion/resize")
        let beforeReturn = committed
        let originalPosition = first(root)
        down(); drag(0.6); drag(originalPosition / length(root))
        post(.leftMouseUp, originalPosition + Double(root.splitView.dividerThickness) / 2)
        try require(committed == beforeReturn, "Returning to the original pixel position changed the model fraction")

        down(); drag(0.6)
        let beforeRetire = ends.count, beforeLatePreview = previews.count
        root.retireGesture(); root.applyInitialFractions()
        drag(0.55); post(.leftMouseUp, first(root))
        try require(!root.isTrackingDivider && ends.count == beforeRetire && previews.count == beforeLatePreview, "Retirement delivered late callbacks")

        let beginHandler = root.onGestureBegin
        root.onGestureBegin = { begins += 1; return nil }
        let rejectedBeginCount = begins
        down(); drag(0.6); post(.leftMouseUp, first(root))
        try require(begins == rejectedBeginCount + 1 && !root.isTrackingDivider && ends.count == beforeRetire && previews.count == beforeLatePreview, "Rejected begin acquired a gesture")
        root.onGestureBegin = beginHandler

        down(); drag(0.6)
        let other = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil); pump(app)
        try require(!root.isTrackingDivider && ends.count == beforeRetire + 1 && ends.last == true, "Key-window loss did not cancel")
        other.close(); window.makeKeyAndOrderFront(nil); pump(app)
        post(.leftMouseUp, first(root))

        down(); drag(0.6)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        try require(!root.isTrackingDivider && ends.count == beforeRetire + 2 && ends.last == true, "Application-loss observer did not cancel")
        post(.leftMouseUp, first(root))
        try geometry()
        try legacyPixel()

        root.onResize = nil; child.onResize = nil
        // Use real pane chrome, not bare NSViews: intrinsic text must not override
        // feasible model fractions, and genuine native minimum constraints are observed.
        window.setContentSize(NSSize(width: 1001, height: 700))
        pump(app)
        try require(root.applyModelFractions(layout), "Model did not match live controllers")
        let feasible = try root.constrainedLayout(matching: layout)
        try require(feasible == layout, "Feasible chrome changed the model fraction")
        if axis == .horizontal {
            let rounded = Layout.split(axis: axis, fraction: 0.3211,
                first: .split(axis: axis, fraction: 0.24995, first: .pane(PaneID(1)), second: .pane(PaneID(2))), second: .pane(PaneID(3)))
            root.applyModelFractions(rounded)
            // A legal pixel-rounded presentation: the full model projects 80.008995
            // points, but the rounded inner view projects 79.984 before its 80pt clamp.
            root.splitView.setPosition(321, ofDividerAt: 0)
            child.applyModelFractions(try rounded.node(at: [.first]))
            let observedRounded = try root.constrainedLayout(matching: rounded)
            try require(observedRounded == rounded, "Pixel rounding changed an otherwise feasible model")
        }
        window.setContentSize(NSSize(width: 500, height: 500))
        pump(app)
        root.applyModelFractions(layout)
        let constrained = try root.constrainedLayout(matching: layout)
        try require(constrained != layout, "Native minimum constraint was not represented")
        try require(leaves.allSatisfy { $0.frame.width >= 80 && $0.frame.height >= 80 }, "Native constrained leaf below minimum")
        root.applyModelFractions(constrained)
        window.setContentSize(NSSize(width: 1001, height: 700))
        pump(app)
        root.applyModelFractions(constrained)
        let widened = try root.constrainedLayout(matching: constrained)
        try require(widened == constrained, "Widening changed feasible constrained fractions")
        if axis == .horizontal {
            root.removeSplitViewItem(root.splitViewItems[1])
            let right = WorkspaceSplitController(fraction: 0.9)
            right.splitView.isVertical = false
            add(leaf("Pane 3"), to: right); add(leaf("Pane 4"), to: right)
            add(right, to: root)
            let mixed = Layout.split(axis: .horizontal, fraction: 0.3211,
                first: .split(axis: .horizontal, fraction: 0.24995, first: .pane(PaneID(1)), second: .pane(PaneID(2))),
                second: .split(axis: .vertical, fraction: 0.9, first: .pane(PaneID(3)), second: .pane(PaneID(4))))
            window.setContentSize(NSSize(width: 1001, height: 500))
            pump(app)
            root.applyModelFractions(mixed)
            root.splitView.setPosition(321, ofDividerAt: 0)
            child.applyModelFractions(try mixed.node(at: [.first]))
            let mixedObserved = try root.constrainedLayout(matching: mixed)
            let leftModel = try mixed.node(at: [.first]), leftObserved = try mixedObserved.node(at: [.first])
            let rightModel = try mixed.node(at: [.second]), rightObserved = try mixedObserved.node(at: [.second])
            try require(leftObserved == leftModel, "A genuine sibling constraint changed a rounding-only subtree")
            try require(rightObserved != rightModel, "Genuine mixed-axis constraint was lost")
        }
    }
}
