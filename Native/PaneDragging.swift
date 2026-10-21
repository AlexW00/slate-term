import AppKit
import SlateTermCore

/// Only this private type participates in pane moves; terminal/file/web drags are untouched.
@MainActor
final class PaneDragHandle: NSButton, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("app.slate-term.pane-move")
    static let activityDidChange = Notification.Name("SlatePaneDragActivityDidChange")
    private static weak var activeHandle: PaneDragHandle?
    static var isMovingPane: Bool { activeHandle != nil }
    var canDrag: (() -> Bool)?
    var dragTitle: (() -> String)?
    var onDragStart: (() -> Bool)?
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
        setAccessibilityHelp("Drag to an edge of another pane in any Slate window, or press to choose a destination.")
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
            guard beginPaneDrag() else { return }
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
            let session = beginDraggingSession(with: [draggingItem], event: next, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            return
        }
    }

    /// Shared session admission also exercised by integration-only native callback fixtures.
    func beginPaneDrag() -> Bool {
        guard Self.activeHandle == nil, !isDraggingPane, canDrag?() == true, onDragStart?() != false else { return false }
        isDraggingPane = true
        Self.activeHandle = self
        NotificationCenter.default.post(name: Self.activityDidChange, object: nil)
        return true
    }
    func endPaneDrag() {
        if Self.activeHandle === self {
            Self.activeHandle = nil
            NotificationCenter.default.post(name: Self.activityDidChange, object: nil)
        }
        isDraggingPane = false
        onDragEnd?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        endPaneDrag()
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
    private let capture = PaneDropCapture()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([PaneDragHandle.pasteboardType])
        capture.destination = self
        capture.autoresizingMask = [.width, .height]
        NotificationCenter.default.addObserver(self, selector: #selector(updateDragCapture),
                                              name: PaneDragHandle.activityDidChange, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDragCapture()
    }

    @objc private func updateDragCapture() {
        guard PaneDragHandle.isMovingPane else { capture.removeFromSuperview(); return }
        // AppKit chooses WebKit's nested drag destination even when container hit testing wins.
        // Register a receiver above the content only while a pane move is active.
        capture.frame = bounds
        if capture.superview == nil { addSubview(capture, positioned: .above, relativeTo: nil) }
    }

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

    /// Show insertion intent relative to the pane under the pointer, not future window
    /// geometry over unchanged content. Removing the source can expand the final split.
    static func previewRect(for direction: Direction, in bounds: NSRect) -> NSRect {
        var rect = bounds
        switch direction {
        case .left: rect.size.width /= 2
        case .right: rect.size.width /= 2; rect.origin.x = bounds.midX
        case .up: rect.size.height /= 2; rect.origin.y = bounds.midY
        case .down: rect.size.height /= 2
        }
        return rect
    }

    func showPreview(direction: Direction, recreatesContent: Bool = false) {
        preview.frame = bounds
        preview.autoresizingMask = [.width, .height]
        preview.direction = direction
        preview.recreatesContent = recreatesContent
        if preview.superview == nil { addSubview(preview, positioned: .above, relativeTo: nil) }
        preview.needsDisplay = true
    }

    var previewFrame: NSRect? {
        preview.superview == nil ? nil : Self.previewRect(for: preview.direction, in: bounds)
    }
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

/// Receives only Slate pane moves; all validation and commits stay on the container.
@MainActor
private final class PaneDropCapture: NSView {
    weak var destination: PaneDropView?
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([PaneDragHandle.pasteboardType])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { destination?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { destination?.draggingUpdated(sender) ?? [] }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { destination?.draggingExited(sender) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { destination?.draggingEnded(sender) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { destination?.prepareForDragOperation(sender) ?? false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { destination?.performDragOperation(sender) ?? false }
}

@MainActor
private final class PaneDropPreview: NSView {
    var direction: Direction = .left
    var recreatesContent = false
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(rect: bounds).addClip()
        let destination = PaneDropView.previewRect(for: direction, in: bounds)
        // Like Ghostty, tint the entire half-pane without an inset, outline or extra seam.
        let path = NSBezierPath(rect: destination)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            NSColor.windowBackgroundColor.setFill()
            path.fill()
        }
        NSColor.controlAccentColor.withAlphaComponent(
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.4 : 0.3
        ).setFill()
        path.fill()

        let arrow: String
        let title: String
        switch direction {
        case .left, .right:
            arrow = direction == .left ? "←" : "→"
            title = direction == .left ? "Move to Left" : "Move to Right"
        case .up, .down:
            arrow = direction == .up ? "↑" : "↓"
            title = direction == .up ? "Move Above" : "Move Below"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        var text = "\(arrow)  \(recreatesContent ? "Move & Reload Plugin" : title)" as NSString
        // Keep the directional cue legible even at the minimum pane size.
        if text.size(withAttributes: attributes).width + 32 > destination.width { text = arrow as NSString }
        let size = text.size(withAttributes: attributes)
        guard destination.width >= size.width + 24, destination.height >= size.height + 20 else { return }
        let badge = NSRect(x: destination.midX - (size.width + 20) / 2,
                           y: destination.midY - (size.height + 12) / 2,
                           width: size.width + 20, height: size.height + 12)
        let badgePath = NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6)
        NSColor.windowBackgroundColor.setFill()
        badgePath.fill()
        text.draw(in: badge.insetBy(dx: 10, dy: 6), withAttributes: attributes)
    }
}
