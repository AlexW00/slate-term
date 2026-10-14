import AppKit
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
        print("PASS pane move native helpers: edges, dead zone, outside, small siblings, projected/collapsed/nested validation geometry, target-local previews, resize and cleanup")
    }
}
