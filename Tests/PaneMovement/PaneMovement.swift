import AppKit
import WebKit
import SlateTermCore

@main
struct PaneMovementGate {
    @MainActor static func main() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw NSError(domain: message, code: 1) }
        }
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
        for (point, direction) in [(NSPoint(x: 10, y: 150), Direction.left),
                                   (NSPoint(x: 390, y: 150), .right),
                                   (NSPoint(x: 200, y: 290), .up),
                                   (NSPoint(x: 200, y: 10), .down)] {
            try require(PaneDropView.direction(at: point, in: bounds) == direction, "Wrong edge")
        }
        try require(PaneDropView.direction(at: NSPoint(x: 200, y: 150), in: bounds) == nil, "Center accepts a move")
        try require(PaneDropView.direction(at: NSPoint(x: -1, y: 150), in: bounds) == nil, "Outside accepts a move")
        try require(PaneDropView.direction(at: .zero, in: .zero) == nil, "Empty pane accepts a move")
        let small = NSRect(x: 0, y: 0, width: 150, height: 200)
        try require(PaneDropView.direction(at: NSPoint(x: 5, y: 100), in: small) == .left, "Small sibling swap must reach proposed-layout validation")

        var workspace = Workspace()
        let source = try workspace.split(PaneID(1), direction: .right)
        try workspace.move(source, beside: PaneID(1), direction: .left)
        let frames = PaneMoveGeometry.frames(for: workspace.tabs[0].layout,
                                            in: NSRect(x: 0, y: 0, width: 301, height: 200), divider: 1)
        try require(frames[source] == NSRect(x: 0, y: 0, width: 150, height: 200), "Collapsed sibling geometry is wrong")
        try require(frames[PaneID(1)] == NSRect(x: 151, y: 0, width: 150, height: 200), "Target geometry is wrong")
        try workspace.move(source, beside: PaneID(1), direction: .up)
        let vertical = PaneMoveGeometry.frames(for: workspace.tabs[0].layout, in: bounds, divider: 2)
        try require(vertical[source] == NSRect(x: 0, y: 151, width: 400, height: 149), "Top uses wrong coordinates")
        try require(vertical[PaneID(1)] == NSRect(x: 0, y: 0, width: 400, height: 149), "Bottom uses wrong coordinates")
        let nested = try workspace.split(PaneID(1), direction: .right)
        let nestedFrames = PaneMoveGeometry.frames(for: workspace.tabs[0].layout, in: bounds, divider: 2)
        try require(nestedFrames[nested] == NSRect(x: 201, y: 0, width: 199, height: 149), "Nested geometry is wrong")

        let drop = PaneDropView(frame: bounds)
        let handle = PaneDragHandle(frame: NSRect(x: 0, y: 0, width: 20, height: 22))
        var starts = 0
        var ends = 0
        handle.canDrag = { false }
        handle.onDragStart = { starts += 1; return true }
        handle.onDragEnd = { ends += 1 }
        try require(!handle.beginPaneDrag() && starts == 0, "Disabled source admitted a drag")
        handle.canDrag = { true }
        handle.onDragStart = { starts += 1; return false }
        try require(!handle.beginPaneDrag() && !handle.isDraggingPane, "Rejected context became active")
        handle.onDragStart = { starts += 1; return true }
        try require(handle.beginPaneDrag() && handle.isDraggingPane, "Live context did not activate")
        try require(!handle.beginPaneDrag() && starts == 2, "Duplicate session recaptured identity")
        handle.endPaneDrag()
        try require(!handle.isDraggingPane && ends == 1, "Drag completion retained active context")
        // WebKit registers its own drag destination below the pane chrome.
        // Exercise hit testing, which direct destination callbacks bypass.
        _ = NSApplication.shared
        let web = WKWebView(frame: bounds)
        drop.addSubview(web)
        let edgePoints = [NSPoint(x: 10, y: 150), NSPoint(x: 390, y: 150),
                          NSPoint(x: 200, y: 290), NSPoint(x: 200, y: 10)]
        for point in edgePoints {
            let hit = drop.hitTest(point)
            try require(hit === web || hit?.isDescendant(of: web) == true, "Idle pane intercepted web input")
        }
        let sibling = PaneDropView(frame: bounds)
        let siblingContent = NSView(frame: bounds)
        sibling.addSubview(siblingContent)
        try require(handle.beginPaneDrag(), "Routing fixture could not begin drag")
        try require(sibling.subviews.last !== siblingContent &&
                    sibling.hitTest(NSPoint(x: 10, y: 150)) === sibling.subviews.last,
                    "Sibling window missed native drag receiver")
        let otherHandle = PaneDragHandle(frame: .zero)
        otherHandle.canDrag = { true }
        try require(!otherHandle.beginPaneDrag(), "Another source replaced a live pane drag")
        otherHandle.endPaneDrag()
        for point in edgePoints + [NSPoint(x: 200, y: 150)] {
            let receiver = drop.subviews.last
            try require(receiver !== web && receiver?.registeredDraggedTypes == [PaneDragHandle.pasteboardType],
                        "No native drag receiver above WebKit")
            try require(drop.hitTest(point) === receiver, "Web content intercepted pane drag")
        }
        try require(drop.hitTest(NSPoint(x: -1, y: 150)) == nil, "Pane drag intercepted outside input")
        drop.setFrameSize(NSSize(width: 500, height: 350))
        try require(drop.subviews.last?.frame == drop.bounds, "Native drag receiver missed pane resize")
        drop.frame = bounds
        handle.endPaneDrag()
        try require(drop.subviews == [web] && sibling.subviews == [siblingContent],
                    "Completed drag retained its native receiver")
        for point in edgePoints {
            let hit = drop.hitTest(point)
            try require(hit === web || hit?.isDescendant(of: web) == true, "Completed drag blocked web input")
        }
        web.removeFromSuperview()
        // Preview geometry stays local even when source removal will expand the target.
        let offsetBounds = NSRect(x: 20, y: 30, width: 400, height: 300)
        for (direction, expected) in [
            (Direction.left, NSRect(x: 20, y: 30, width: 200, height: 300)),
            (.right, NSRect(x: 220, y: 30, width: 200, height: 300)),
            (.up, NSRect(x: 20, y: 180, width: 400, height: 150)),
            (.down, NSRect(x: 20, y: 30, width: 400, height: 150)),
        ] {
            try require(PaneDropView.previewRect(for: direction, in: offsetBounds) == expected, "Preview is not target-local")
            drop.showPreview(direction: direction)
            try require(drop.previewFrame == PaneDropView.previewRect(for: direction, in: bounds), "Wrong visible preview")
            try require(drop.subviews.count == 1, "Preview accumulated overlays")
            try require(drop.subviews[0].hitTest(NSPoint(x: 10, y: 10)) == nil, "Preview intercepts input")
        }
        drop.setFrameSize(NSSize(width: 160, height: 80))
        drop.showPreview(direction: .right)
        try require(drop.previewFrame == NSRect(x: 80, y: 0, width: 80, height: 80), "Preview did not follow resize")
        drop.clearPreview()
        try require(drop.previewFrame == nil && drop.subviews.isEmpty, "Preview not removed")
        drop.frame = bounds
        var cleared = false
        var previewed: Direction?
        drop.canMove = { source, _ in source === handle }
        drop.onClearPreviews = { cleared = true; drop.clearPreview() }
        drop.onPreview = { _, direction in previewed = direction; drop.showPreview(direction: direction) }
        try require(drop.updatePreview(source: handle, at: NSPoint(x: 10, y: 150)) == .left, "Valid preview rejected")
        try require(previewed == .left && drop.previewFrame != nil, "Preview callback not invoked")
        try require(drop.updatePreview(source: handle, at: NSPoint(x: 200, y: 150)) == nil && cleared, "Center did not clear preview")
        try require(drop.previewFrame == nil, "Center left a stale overlay")
        cleared = false
        drop.showPreview(direction: .left)
        drop.canMove = { _, _ in false }
        try require(drop.updatePreview(source: handle, at: NSPoint(x: 10, y: 150)) == nil && cleared, "Stale source did not clear preview")
        try require(drop.previewFrame == nil, "Invalid source left a stale overlay")
        print("PASS pane move native helpers: WebKit drag routing and input restoration, exclusive drag ownership, edges, dead zone, outside, small siblings, projected/collapsed/nested validation geometry, target-local previews, resize and cleanup")
    }
}
