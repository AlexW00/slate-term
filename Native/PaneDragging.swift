import AppKit
import SlateTermCore

/// Only this private type participates in pane moves; terminal/file/web drags are untouched.
@MainActor
final class PaneDragHandle: NSButton, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("app.slate-term.pane-move")
    var canDrag: (() -> Bool)?
    var dragTitle: (() -> String)?
    var onDragEnd: (() -> Void)?
    private(set) var isDraggingPane = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryPushIn)
        image = NSImage(size: NSSize(width: 10, height: 14), flipped: false) { _ in
            NSColor.labelColor.setFill()
            for x in [2.5, 7.5] {
                for y in [2.0, 7.0, 12.0] {
                    NSBezierPath(ovalIn: NSRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill()
                }
            }
            return true
        }
        image?.isTemplate = true
        contentTintColor = .secondaryLabelColor
        toolTip = "Move Pane — drag to another pane’s edge, or click for options"
        setAccessibilityLabel("Move Pane")
        setAccessibilityHelp("Drag to an edge of another pane in this tab, or press to choose a destination.")
    }
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        let origin = event.locationInWindow
        highlight(true)
        defer { highlight(false) }
        // A click still opens the accessible move menu; don't start a drag on a tremor.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { performClick(nil) }
                return
            }
            guard hypot(next.locationInWindow.x - origin.x, next.locationInWindow.y - origin.y) >= 5 else { continue }
            guard canDrag?() == true else { return }
            let item = NSPasteboardItem()
            item.setString("pane", forType: Self.pasteboardType)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            let size = NSSize(width: 200, height: 28)
            let title = dragTitle?() ?? "Move Pane"
            let preview = NSImage(size: size, flipped: false) { rect in
                NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                (title as NSString).draw(in: rect.insetBy(dx: 9, dy: 6), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
                ])
                return true
            }
            let point = convert(next.locationInWindow, from: nil)
            draggingItem.setDraggingFrame(NSRect(x: point.x - 10, y: point.y - 14, width: size.width, height: size.height), contents: preview)
            isDraggingPane = true
            let session = beginDraggingSession(with: [draggingItem], event: next, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            return
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingPane = false
        onDragEnd?()
    }
}

/// Registered on the container, above all content types in the destination hierarchy.
@MainActor
final class PaneDropView: NSView {
    var canMove: ((PaneDragHandle, Direction) -> Bool)?
    var onMove: ((PaneDragHandle, Direction) -> Bool)?
    var onPreview: ((PaneDragHandle, Direction) -> Void)?
    var onClearPreviews: (() -> Void)?
    private let preview = PaneDropPreview()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([PaneDragHandle.pasteboardType])
    }
    required init?(coder: NSCoder) { nil }

    static func direction(at point: NSPoint, in bounds: NSRect) -> Direction? {
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return nil }
        // The middle is deliberately inert. At corners, use the nearest normalized edge.
        let edges: [(Direction, CGFloat)] = [
            (.left, (point.x - bounds.minX) / bounds.width),
            (.right, (bounds.maxX - point.x) / bounds.width),
            (.up, (bounds.maxY - point.y) / bounds.height),
            (.down, (point.y - bounds.minY) / bounds.height),
        ]
        guard let edge = edges.min(by: { $0.1 < $1.1 }), edge.1 <= 0.25 else { return nil }
        // Size validation belongs to the proposed layout: removing a sibling can expand this pane.
        return edge.0
    }

    func updatePreview(source: PaneDragHandle, at point: NSPoint) -> Direction? {
        guard let direction = Self.direction(at: point, in: bounds), canMove?(source, direction) == true else {
            onClearPreviews?()
            return nil
        }
        onPreview?(source, direction)
        return direction
    }

    /// Each retained pane draws its portion of the predicted window-space destination.
    /// This can span the old source and target without adding subviews to NSSplitView.
    func showPreview(windowRect: NSRect) {
        let rect = convert(windowRect, from: nil).insetBy(dx: 3, dy: 3)
        guard rect.intersects(bounds) else { clearPreview(); return }
        preview.frame = bounds
        preview.destination = rect
        if preview.superview == nil { addSubview(preview, positioned: .above, relativeTo: nil) }
        preview.needsDisplay = true
    }

    var previewFrame: NSRect? { preview.superview == nil ? nil : preview.destination.intersection(bounds) }
    func clearPreview() { preview.removeFromSuperview() }

    private func destination(_ sender: any NSDraggingInfo) -> (PaneDragHandle, Direction)? {
        guard let source = sender.draggingSource as? PaneDragHandle, source.isDraggingPane,
              sender.draggingSourceOperationMask.contains(.move),
              sender.draggingPasteboard.availableType(from: [PaneDragHandle.pasteboardType]) != nil,
              let direction = updatePreview(source: source, at: convert(sender.draggingLocation, from: nil)) else {
            onClearPreviews?()
            return nil
        }
        return (source, direction)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { destination(sender) == nil ? [] : .move }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onClearPreviews?() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { onClearPreviews?() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { destination(sender) != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { onClearPreviews?() }
        guard let (source, direction) = destination(sender) else { return false }
        return onMove?(source, direction) ?? false
    }
}

@MainActor
private final class PaneDropPreview: NSView {
    var destination = NSRect.zero
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(rect: bounds).addClip()
        let path = NSBezierPath(roundedRect: destination, xRadius: 5, yRadius: 5)
        NSColor.controlAccentColor.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0.35 : 0.18).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
