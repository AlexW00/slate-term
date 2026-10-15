import AppKit
import SlateTermCore

/// AppKit still lays out and draws the split. Explicit mouse phases avoid a nested
/// tracking loop, so cancellation or a competing operation can retire the old view.
@MainActor
private final class WorkspaceDividerView: NSSplitView {
    var explicitGestures: () -> Bool = { false }
    var onBegin: (() -> Bool)?
    var onPreview: ((Double) -> Void)?
    var onEnd: ((Bool) -> Void)?
    var onAttach: (() -> Void)?
    private(set) var tracking = false
    private(set) var detaching = false
    private var ownsMouseSequence = false
    private var grabOffset: CGFloat = 0
    private var escapeMonitor: Any?
    private var observations: [NSObjectProtocol] = []
    var dividerHitRegion: (bounds: NSRect, frames: [NSRect], rect: NSRect)?

    override func mouseDown(with event: NSEvent) {
        guard explicitGestures() else { super.mouseDown(with: event); return }
        // A leaf may forward an unhandled mouse-down through its responder chain.
        // Only the actual effective divider region supplied by AppKit may start a drag.
        guard let region = dividerHitRegion, region.bounds == bounds,
              region.frames == arrangedSubviews.map(\.frame),
              region.rect.contains(convert(event.locationInWindow, from: nil)) else { return }
        ownsMouseSequence = true
        guard let window, arrangedSubviews.count == 2, onBegin?() == true else { NSSound.beep(); return }
        tracking = true
        let first = arrangedSubviews[0].frame
        grabOffset = coordinate(event) - (isVertical ? first.width : first.height)
        (isVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.tracking, event.window === self.window, event.keyCode == 53 else { return false }
                self.finish(cancelled: true)
                return true
            }
            return consumed ? nil : event
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject), (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(cancelled: true) }
            })
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard ownsMouseSequence else { super.mouseDragged(with: event); return }
        guard tracking else { return }
        let length = (isVertical ? bounds.width : bounds.height) - dividerThickness
        guard length.isFinite, length > 0 else { finish(cancelled: true); return }
        onPreview?(Double((coordinate(event) - grabOffset) / length))
    }

    override func mouseUp(with event: NSEvent) {
        guard ownsMouseSequence else { super.mouseUp(with: event); return }
        ownsMouseSequence = false
        finish(cancelled: false)
    }

    private func coordinate(_ event: NSEvent) -> CGFloat {
        let point = convert(event.locationInWindow, from: nil)
        return isVertical ? point.x - bounds.minX : (isFlipped ? point.y - bounds.minY : bounds.maxY - point.y)
    }

    func finish(cancelled: Bool, notify: Bool = true) {
        guard tracking else { return }
        tracking = false
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        NSCursor.pop()
        if notify { onEnd?(cancelled) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        detaching = newWindow == nil
        if detaching { finish(cancelled: true) }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { detaching = false; onAttach?() }
    }
}

@MainActor
final class WorkspaceSplitController: NSSplitViewController {
    static let paneHoldingPriority = NSLayoutConstraint.Priority(rawValue: 251)
    let generation = UUID()
    var onResize: ((Double) -> Void)?
    var onPresentationResize: (() -> Void)?
    var onGestureBegin: (() -> ClosedRange<Double>?)?
    var onGesturePreview: ((Double) -> Void)?
    var onGestureEnd: ((Bool) -> Void)?
    private let dividerInput = WorkspaceDividerView()
    private var modelFraction: Double
    private var previewRange: ClosedRange<Double>?
    private var initialPresentedFraction: Double?
    private var previewBounds: NSRect?
    private var previewScale: CGFloat?
    private var initialized = false
    private var applying = false
    private var lastGeometry: (length: Double, first: Double)?
    private var lastBounds: NSRect?
    private var lastScale: CGFloat?
    private var appliedBounds: NSRect?
    private var appliedScale: CGFloat?
    var presentationChangedSinceApplication: Bool {
        appliedBounds != splitView.bounds || appliedScale != view.window?.backingScaleFactor
    }
    private(set) var appliedGeometry: JSONValue = .null
    var isTrackingDivider: Bool { dividerInput.tracking }
    var isDetaching: Bool { dividerInput.detaching }

    init(fraction: Double) {
        modelFraction = fraction
        super.init(nibName: nil, bundle: nil)
        dividerInput.dividerStyle = .thin
        splitView = dividerInput
        dividerInput.explicitGestures = { [weak self] in self?.onGestureBegin != nil }
        dividerInput.onBegin = { [weak self] in
            guard let self, self.initialized, let range = self.onGestureBegin?() else { return false }
            let split = self.splitView
            guard let first = split.arrangedSubviews.first else { return false }
            let length = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
            guard length.isFinite, length > 0 else { return false }
            self.initialPresentedFraction = Double((split.isVertical ? first.frame.width : first.frame.height) / length)
            self.previewRange = range
            self.previewBounds = split.bounds
            self.previewScale = self.view.window?.backingScaleFactor
            return true
        }
        dividerInput.onPreview = { [weak self] in self?.preview($0) }
        dividerInput.onEnd = { [weak self] cancelled in
            guard let self else { return }
            self.previewRange = nil
            self.initialPresentedFraction = nil
            self.previewBounds = nil; self.previewScale = nil
            self.onGestureEnd?(cancelled)
        }
        dividerInput.onAttach = { [weak self] in
            guard let self, self.initialized else { return }
            self.applyInitialFractions()
        }
    }
    required init?(coder: NSCoder) { nil }

    func adoptModelFraction(_ fraction: Double) { modelFraction = fraction }

    /// Retire input first; the host decides whether to commit or restore the current model.
    func retireGesture() {
        previewRange = nil
        initialPresentedFraction = nil
        previewBounds = nil; previewScale = nil
        dividerInput.finish(cancelled: true, notify: false)
    }

    func cancelGesture() { dividerInput.finish(cancelled: true) }

    @discardableResult
    func applyModelFractions(_ layout: Layout) -> Bool {
        var updates: [(WorkspaceSplitController, Double)] = []
        func collect(_ layout: Layout, controller: NSViewController) -> Bool {
            switch layout {
            case .pane: return !(controller is WorkspaceSplitController)
            case .split(let axis, let fraction, let first, let second):
                guard let split = controller as? WorkspaceSplitController, split.splitViewItems.count == 2,
                      split.splitView.isVertical == (axis == .horizontal) else { return false }
                updates.append((split, fraction))
                return collect(first, controller: split.splitViewItems[0].viewController)
                    && collect(second, controller: split.splitViewItems[1].viewController)
            }
        }
        guard collect(layout, controller: self) else { return false }
        updates.forEach { $0.0.adoptModelFraction($0.1) }
        applyInitialFractions()
        return true
    }

    private func preview(_ proposed: Double) {
        guard proposed.isFinite, let range = previewRange else { return }
        guard previewBounds == splitView.bounds, previewScale == view.window?.backingScaleFactor else { cancelGesture(); return }
        let length = Double((splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness)
        let scale = Double(view.window?.backingScaleFactor ?? 1)
        guard length > 0, scale > 0 else { dividerInput.finish(cancelled: true); return }
        // Returning to the original rendered position must not import its pixel-rounding
        // error into the model. The tolerance is numerical noise, not a physical drag step.
        if let initialPresentedFraction, abs(proposed - initialPresentedFraction) * length < 1e-9, range.contains(modelFraction) {
            applyFractions(rootFraction: modelFraction)
            onGesturePreview?(modelFraction)
            return
        }
        // Clamp inward to device pixels so rounding cannot cross a subtree's minimum.
        let minimum = ceil(range.lowerBound * length * scale) / scale
        let maximum = floor(range.upperBound * length * scale) / scale
        guard minimum <= maximum else { dividerInput.finish(cancelled: true); return }
        let position = min(max(proposed * length, minimum), maximum)
        let fraction = min(max(position / length, range.lowerBound), range.upperBound)
        applyFractions(rootFraction: fraction)
        onGesturePreview?(fraction)
    }

    func applyInitialFractions() { applyFractions(rootFraction: modelFraction) }

    private func applyFractions(rootFraction: Double) {
        func tree(_ controller: WorkspaceSplitController) -> [WorkspaceSplitController] {
            [controller] + controller.children.compactMap { $0 as? WorkspaceSplitController }.flatMap(tree)
        }
        let controllers = tree(self)
        // Suppress the whole subtree before the parent's setPosition causes child resize
        // callbacks. Descendants retain model fractions, never incidental autoresize ratios.
        controllers.forEach { $0.applying = true }
        defer { controllers.forEach { $0.applying = false } }
        func apply(_ controller: WorkspaceSplitController, fraction: Double) {
            let split = controller.splitView
            guard split.arrangedSubviews.count == 2 else { return }
            let length = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
            guard length.isFinite, length > 0 else { return }
            split.setPosition(length * fraction, ofDividerAt: 0)
            controller.view.layoutSubtreeIfNeeded()
            controller.appliedGeometry = .object(["length": .number(length), "fraction": .number(fraction), "firstWidth": .number(split.arrangedSubviews[0].frame.width)])
            for child in controller.children.compactMap({ $0 as? WorkspaceSplitController }) { apply(child, fraction: child.modelFraction) }
            controller.initialized = true
        }
        apply(self, fraction: rootFraction)
        for controller in controllers {
            let split = controller.splitView
            if let first = split.arrangedSubviews.first {
                controller.lastGeometry = (Double((split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness),
                                           Double(split.isVertical ? first.frame.width : first.frame.height))
                controller.lastBounds = split.bounds
                controller.lastScale = controller.view.window?.backingScaleFactor
                controller.appliedBounds = split.bounds
                controller.appliedScale = controller.lastScale
            }
        }
    }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        let effective = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        if dividerIndex == 0 {
            dividerInput.dividerHitRegion = (splitView.bounds, splitView.arrangedSubviews.map(\.frame), effective)
        }
        return effective
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        let presentationChanged = lastBounds != splitView.bounds || lastScale != view.window?.backingScaleFactor
        super.splitViewDidResizeSubviews(notification)
        if isTrackingDivider, previewBounds != splitView.bounds || previewScale != view.window?.backingScaleFactor { cancelGesture() }
        guard initialized, !applying, !isTrackingDivider, let first = splitView.arrangedSubviews.first else { return }
        var ancestor = parent
        while let current = ancestor {
            if (current as? WorkspaceSplitController)?.isTrackingDivider == true { return }
            ancestor = current.parent
        }
        let length = (splitView.isVertical ? splitView.bounds.width : splitView.bounds.height) - splitView.dividerThickness
        let firstLength = splitView.isVertical ? first.frame.width : first.frame.height
        guard length.isFinite, firstLength.isFinite, length > 0, firstLength > 0, firstLength < length else { return }
        let previous = lastGeometry
        lastGeometry = (Double(length), Double(firstLength))
        lastBounds = splitView.bounds
        lastScale = view.window?.backingScaleFactor
        if presentationChanged, let onPresentationResize { onPresentationResize(); return }
        if let previous {
            let lengthChanged = abs(previous.length - length) > 1e-9
            guard lengthChanged || abs(previous.first - firstLength) > 1e-9 else { return }
            // A new presentation extent can round the same model fraction. A divider
            // moving within an unchanged extent is different: retain even one pixel.
            let tolerance = 1 / (view.window?.backingScaleFactor ?? 1)
            if lengthChanged && abs(firstLength - length * modelFraction) <= tolerance { return }
        }
        onResize?(Double(firstLength / length))
    }
}
