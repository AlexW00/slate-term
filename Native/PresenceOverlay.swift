import AppKit
import SlateTermCore

/// One agent tag as the overlay draws it. Element bounds use the overlay's top-left space.
struct PresenceOverlayItem: Equatable {
    enum Status: Equatable { case active, live(String), held, ok(String?), failed(String?) }
    let id: String
    let label: String
    let note: String?
    let rgb: UInt32
    let status: Status
    let element: NSRect?
    let pulse: Int
    let order: Int
    let originPane: String?
}

/// Paints target rings and native glass agent pills above pane content.
/// Only the pills take clicks; empty overlay space passes through to pane content.
/// Tags use explicit frames without constraints to keep pane and web layout independent.
@MainActor
final class PresenceOverlayView: NSView {
    static let fade: TimeInterval = 0.45
    private static let move: TimeInterval = 0.3
    static let tagHeight: CGFloat = 21
    private static let ringInset: CGFloat = 1.5
    private static let paneCornerRadius: CGFloat = 7

    var onActivate: ((String) -> Void)?
    /// Keep pills over content, clear of a browser's native status strip.
    var contentBottomInset: CGFloat = 0 {
        didSet { if contentBottomInset != oldValue { layoutItems(animated: false) } }
    }

    private var items: [PresenceOverlayItem] = []
    private var tags: [String: PresenceTagView] = [:]
    private var pulses: [String: Int] = [:]
    private let paneRing = PresenceRingLayer()
    private var elementRings: [String: PresenceRingLayer] = [:]
    private let overflow = PresenceTagView()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    override var acceptsFirstResponder: Bool { false }

    @available(macOS 27.0, *)
    override var cornerConfiguration: NSViewCornerConfiguration? {
        .corners(radius: .containerConcentric(Self.paneCornerRadius + Self.ringInset))
    }

    @available(macOS 27.0, *)
    override func viewDidChangeEffectiveCornerRadii() {
        super.viewDidChangeEffectiveCornerRadii()
        needsLayout = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Glows stay inside the pane instead of spilling over neighbouring panes.
        layer?.masksToBounds = true
        layer?.addSublayer(paneRing)
        overflow.alphaValue = 0
        addSubview(overflow)
        setAccessibilityElement(false)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func accessibilityChildren() -> [Any]? {
        items.compactMap { tags[$0.id] }.filter { $0.alphaValue > 0 && !$0.isLeaving }
    }

    override func layout() {
        super.layout()
        layoutItems(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyleTags()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        restyleTags()
    }

    private func restyleTags() {
        let scale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for tag in tags.values { tag.restyle(scale: scale, dark: effectiveAppearance.isDark) }
            overflow.restyle(scale: scale, dark: effectiveAppearance.isDark)
        }
    }

    @objc private func accessibilityOptionsChanged() {
        restyleTags()
    }

    func update(_ next: [PresenceOverlayItem]) {
        if next.isEmpty && items.isEmpty { return }
        let previous = Set(items.map(\.id))
        items = next.sorted { $0.order < $1.order }
        let scale = window?.backingScaleFactor ?? 2
        let dark = effectiveAppearance.isDark
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for item in items {
                let tag = tags[item.id] ?? {
                    let created = PresenceTagView()
                    created.alphaValue = 0
                    created.onActivate = { [weak self] in self?.onActivate?(item.id) }
                    addSubview(created)
                    tags[item.id] = created
                    return created
                }()
                tag.generation += 1
                tag.isLeaving = false
                tag.configure(item, scale: scale, dark: dark)
            }
        }
        for (id, tag) in tags where !items.contains(where: { $0.id == id }) && !tag.isLeaving {
            tag.isLeaving = true
            tag.generation += 1
            let generation = tag.generation
            fade(tag, to: 0) { [weak self, weak tag] in
                // A newer appearance or exit owns the tag now; leave it alone.
                guard let self, let tag, tag.generation == generation else { return }
                tag.removeFromSuperview()
                if self.tags[id] === tag { self.tags[id] = nil }
            }
        }
        layoutItems(animated: true)
        for item in items where !previous.contains(item.id) || (pulses[item.id] ?? item.pulse) < item.pulse {
            (item.element == nil ? paneRing : elementRings[item.element.map(NSStringFromRect) ?? ""])?.pulse()
        }
        pulses = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.pulse) })
    }

    private func layoutItems(animated: Bool) {
        let paneItems = items.filter { $0.element == nil }
        withoutActions {
            paneRing.frame = bounds
            paneRing.update(path: paneRingPath,
                            colors: paneItems.map { NSColor(rgb: $0.rgb) }, animated: animated)
        }
        paneRing.setVisible(!paneItems.isEmpty, animated: animated)
        // Only the highlight follows an element. Its pill stays in the pane corner.
        // Bounds identify the visible target; overlapping but different elements stay separate.
        let groups = Dictionary(grouping: items.filter { $0.element != nil }) { NSStringFromRect($0.element!) }
        for (key, ring) in elementRings where groups[key] == nil {
            elementRings[key] = nil
            ring.dismiss(animated: animated)
        }
        for (key, members) in groups {
            guard let element = members.first?.element else { continue }
            let target = element.insetBy(dx: -4, dy: -4).intersection(bounds.insetBy(dx: 1, dy: 1))
            guard !target.isNull, target.width > 2, target.height > 2 else {
                elementRings[key]?.dismiss(animated: animated)
                elementRings[key] = nil
                continue
            }
            let ring = elementRings[key] ?? {
                let created = PresenceRingLayer()
                layer?.insertSublayer(created, above: paneRing)
                elementRings[key] = created
                return created
            }()
            withoutActions {
                ring.frame = bounds
                ring.update(path: CGPath(roundedRect: target, cornerWidth: 6, cornerHeight: 6, transform: nil),
                            colors: members.map { NSColor(rgb: $0.rgb) }, animated: animated)
            }
            ring.setVisible(true, animated: animated)
        }
        let available = max(0, bounds.width - 28)
        let newest = items.max { $0.order < $1.order }?.id
        var compact = Set(items.count >= 3 || bounds.width < 200 ? items.map(\.id).filter { $0 != newest } : [])
        if bounds.width < 200, let newest { compact.insert(newest) }
        func widths() -> [String: CGFloat] {
            Dictionary(uniqueKeysWithValues: items.compactMap { item in
                tags[item.id].map { (item.id, $0.width(compact: compact.contains(item.id), maximum: available)) }
            })
        }
        var sizes = widths()
        func total(_ shown: [PresenceOverlayItem]) -> CGFloat {
            shown.reduce(0) { $0 + (sizes[$1.id] ?? 0) } + CGFloat(max(0, shown.count - 1)) * 4
        }
        if total(items) > available {
            compact.formUnion(items.map(\.id).filter { $0 != newest })
            sizes = widths()
        }
        var shown = items
        var hidden: [PresenceOverlayItem] = []
        let chipWidth: CGFloat = min(34, available)
        while shown.count > 1, total(shown) + (hidden.isEmpty ? 0 : chipWidth + 4) > available {
            guard let drop = shown.dropLast().last(where: { $0.id != newest }) ?? shown.first(where: { $0.id != newest }) else { break }
            shown.removeAll { $0.id == drop.id }
            hidden.append(drop)
        }
        if !hidden.isEmpty, let only = shown.first, shown.count == 1 {
            sizes[only.id] = max(0, min(sizes[only.id] ?? 0, available - chipWidth - 4))
        }
        var right = bounds.maxX - 14
        let y = max(bounds.minY, bounds.maxY - contentBottomInset - Self.tagHeight - 14)
        for item in shown {
            guard let tag = tags[item.id] else { continue }
            let width = sizes[item.id] ?? 0
            let frame = CGRect(x: max(bounds.minX, right - width), y: y, width: width, height: Self.tagHeight)
            tag.setCompact(compact.contains(item.id))
            right = frame.minX - 4
            move(tag, to: frame, animated: animated && tag.alphaValue > 0)
            if !tag.isLeaving { fade(tag, to: 1) }
        }
        for item in hidden { if let tag = tags[item.id] { fade(tag, to: 0) } }
        if hidden.isEmpty { fade(overflow, to: 0) }
        else {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                overflow.configureOverflow(count: hidden.count, scale: window?.backingScaleFactor ?? 2, dark: effectiveAppearance.isDark)
            }
            overflow.toolTip = hidden.map(\.label).joined(separator: ", ")
            let frame = CGRect(x: max(bounds.minX, right - chipWidth), y: y, width: chipWidth, height: Self.tagHeight)
            move(overflow, to: frame, animated: animated)
            fade(overflow, to: 1)
        }
    }

    /// Corner order follows the flipped overlay: top-left, top-right, bottom-right, bottom-left.
    private var paneRingRadii: [CGFloat] {
        let minimum = Self.paneCornerRadius
        if #available(macOS 27.0, *), let corners = effectiveCornerRadii {
            return [corners.topLeft, corners.topRight, corners.bottomRight, corners.bottomLeft]
                .map { max(minimum, $0 - Self.ringInset) }
        }
        var radii = Array(repeating: minimum, count: 4)
        guard let window, !window.styleMask.contains(.fullScreen), let content = window.contentView else { return radii }
        let frame = convert(bounds, to: content)
        let bottom = content.isFlipped ? frame.maxY : frame.minY
        let contentBottom = content.isFlipped ? content.bounds.maxY : content.bounds.minY
        // macOS 26 has 16-point window corners, without the public concentric-radius API.
        // Only panes touching an outer bottom corner inherit that radius.
        if abs(bottom - contentBottom) < 0.5 {
            if abs(frame.minX - content.bounds.minX) < 0.5 { radii[3] = 16 - Self.ringInset }
            if abs(frame.maxX - content.bounds.maxX) < 0.5 { radii[2] = 16 - Self.ringInset }
        }
        return radii
    }

    private var paneRingPath: CGPath {
        let rect = bounds.insetBy(dx: Self.ringInset, dy: Self.ringInset)
        let limit = max(0, min(rect.width, rect.height) / 2)
        let radii = paneRingRadii.map { min($0, limit) }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + radii[0], y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radii[1])
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radii[2])
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radii[3])
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radii[0])
        path.closeSubpath()
        return path
    }

    private func move(_ tag: PresenceTagView, to frame: CGRect, animated: Bool) {
        guard tag.frame != frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !Self.reduceMotion ? Self.move : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tag.animator().frame = frame
        }
    }

    private func fade(_ tag: PresenceTagView, to target: CGFloat, completion: (@MainActor () -> Void)? = nil) {
        guard tag.alphaValue != target else { completion?(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.reduceMotion ? 0 : Self.fade
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            tag.animator().alphaValue = target
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Exercise the real native control action without manufacturing a focus target.
    func clickForTesting(_ id: String) -> Bool {
        guard let tag = tags[id], tag.alphaValue > 0, !tag.isLeaving else { return false }
        tag.performClick(nil)
        return true
    }

    /// Integration probe: what a user would currently see in this pane.
    var testingState: JSONValue {
        .array(items.map { item in
            var fields: [String: JSONValue] = ["id": .string(item.id), "label": .string(item.label), "target": .string(item.element == nil ? "pane" : "element")]
            fields["color"] = .string(String(format: "#%06X", item.rgb))
            let ring = item.element.map { elementRings[NSStringFromRect($0)] } ?? paneRing
            if let ring {
                fields["ringID"] = .string(String(describing: ObjectIdentifier(ring)))
                fields["ringColors"] = .number(Double(ring.agentColors.count))
                fields["ringStops"] = .array((ring.gradient.locations ?? []).map { .number($0.doubleValue) })
                fields["ringWidth"] = .number(ring.gradient.bounds.width)
            }
            if let note = item.note { fields["note"] = .string(note) }
            if let element = item.element {
                fields["element"] = .object(["x": .number(element.minX), "y": .number(element.minY),
                                             "width": .number(element.width), "height": .number(element.height)])
            }
            switch item.status {
            case .active: fields["status"] = .string("active")
            case .live: fields["status"] = .string("live")
            case .held: fields["status"] = .string("held")
            case .ok: fields["status"] = .string("ok")
            case .failed: fields["status"] = .string("failed")
            }
            if let tag = tags[item.id] {
                fields["detail"] = .string(tag.detailText)
                if let center = tag.holdIconCenterY { fields["holdIconCenterY"] = .number(center) }
                fields["holdAnimation"] = tag.holdAnimationState
                if item.element == nil { fields["ringCornerRadii"] = .array(paneRingRadii.map { .number($0) }) }
                fields["compact"] = .bool(tag.isCompact)
                fields["shown"] = .bool(tag.alphaValue > 0)
                fields["glass"] = .bool(tag.usesGlass)
                fields["clickable"] = .bool(tag.isEnabled)
                fields["hitTarget"] = .bool(hitTest(convert(NSPoint(x: tag.frame.midX, y: tag.frame.midY), to: superview)) === tag)
                fields["outsidePassesThrough"] = .bool(hitTest(convert(NSPoint(x: 1, y: 1), to: superview)) == nil)
                fields["cornerRadius"] = .number(Self.tagHeight / 2)
                fields["frame"] = .object(["x": .number(tag.frame.minX), "y": .number(tag.frame.minY),
                                           "width": .number(tag.frame.width), "height": .number(tag.frame.height),
                                           "bottomInset": .number(bounds.maxY - tag.frame.maxY)])
            }
            return .object(fields)
        })
    }
}

/// A rounded ring in one color, or a gradient through several agents' colors, with a soft glow.
@MainActor
private final class PresenceRingLayer: CALayer {
    let gradient = CAGradientLayer()
    private(set) var agentColors: [NSColor] = []
    private let ringMask = CAShapeLayer()
    private let glow = CAShapeLayer()

    override init() {
        super.init()
        opacity = 0
        glow.fillColor = nil
        glow.lineWidth = 1.5
        glow.shadowOffset = .zero
        glow.shadowRadius = 9
        glow.shadowOpacity = 0.55
        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.black.cgColor
        ringMask.lineWidth = 1.5
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.mask = ringMask
        addSublayer(glow)
        addSublayer(gradient)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    /// Call with implicit actions disabled.
    func update(path: CGPath, colors: [NSColor], animated: Bool) {
        // Anchor the gradient to this target, not to the whole pane behind it.
        let target = path.boundingBoxOfPath.insetBy(dx: -ringMask.lineWidth / 2, dy: -ringMask.lineWidth / 2)
        gradient.frame = target
        ringMask.frame = CGRect(origin: .zero, size: target.size)
        var offset = CGAffineTransform(translationX: -target.minX, y: -target.minY)
        ringMask.path = path.copy(using: &offset)
        glow.frame = bounds
        glow.path = path
        guard !colors.isEmpty, colors != agentColors else { return }
        agentColors = colors

        // Each agent owns an equal-width band, blending between adjacent band centers.
        let stops = [0.0] + colors.indices.map { (Double($0) + 0.5) / Double(colors.count) } + [1.0]
        let resolved = [colors[0]] + colors + [colors[colors.count - 1]]
        let current = gradient.presentation() ?? gradient
        let previousColors = (current.colors as? [CGColor])?.compactMap { NSColor(cgColor: $0)?.usingColorSpace(.deviceRGB) }
        let previousStops = current.locations?.map(\.doubleValue)
        gradient.removeAnimation(forKey: "colors")
        gradient.removeAnimation(forKey: "locations")
        gradient.colors = resolved.map(\.cgColor)
        gradient.locations = stops.map { NSNumber(value: $0) }
        if animated, !PresenceOverlayView.reduceMotion,
           let previousColors, let previousStops, previousColors.count == previousStops.count, !previousColors.isEmpty {
            // Shared stops keep color arrays compatible when agents join or leave.
            // Start at the presentation values so rapid updates do not restart the fade.
            let shared = Array(Set(stops + previousStops)).sorted()
            let change = CABasicAnimation(keyPath: "colors")
            change.fromValue = shared.map { Self.sample($0, colors: previousColors, stops: previousStops).cgColor }
            change.toValue = shared.map { Self.sample($0, colors: resolved, stops: stops).cgColor }
            change.duration = 0.25
            change.timingFunction = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
            let locations = CABasicAnimation(keyPath: "locations")
            locations.fromValue = shared.map { NSNumber(value: $0) }
            locations.toValue = locations.fromValue
            locations.duration = change.duration
            gradient.add(change, forKey: "colors")
            gradient.add(locations, forKey: "locations")
        }
        // Give the glow equal contributions too, rather than favoring the newest agent.
        let rgb = colors.map { $0.usingColorSpace(.deviceRGB)! }
        let count = CGFloat(rgb.count)
        let blended = NSColor(deviceRed: rgb.reduce(0) { $0 + $1.redComponent } / count,
                              green: rgb.reduce(0) { $0 + $1.greenComponent } / count,
                              blue: rgb.reduce(0) { $0 + $1.blueComponent } / count, alpha: 1)
        for (key, value) in [("strokeColor", blended.withAlphaComponent(0.6).cgColor), ("shadowColor", blended.cgColor)] {
            let previous = (glow.presentation() ?? glow).value(forKey: key)
            glow.setValue(value, forKey: key)
            if animated, !PresenceOverlayView.reduceMotion, let previous {
                let change = CABasicAnimation(keyPath: key)
                change.fromValue = previous
                change.toValue = value
                change.duration = 0.25
                change.timingFunction = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
                glow.add(change, forKey: key)
            }
        }
    }

    private static func sample(_ position: Double, colors: [NSColor], stops: [Double]) -> NSColor {
        guard let upper = stops.firstIndex(where: { $0 > position }) else { return colors[colors.count - 1] }
        guard upper > 0 else { return colors[0] }
        let fraction = CGFloat((position - stops[upper - 1]) / (stops[upper] - stops[upper - 1]))
        let left = colors[upper - 1].usingColorSpace(.deviceRGB)!
        let right = colors[upper].usingColorSpace(.deviceRGB)!
        return NSColor(deviceRed: left.redComponent + (right.redComponent - left.redComponent) * fraction,
                       green: left.greenComponent + (right.greenComponent - left.greenComponent) * fraction,
                       blue: left.blueComponent + (right.blueComponent - left.blueComponent) * fraction, alpha: 1)
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        let target: Float = visible ? 1 : 0
        guard opacity != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated && !PresenceOverlayView.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = presentation()?.opacity ?? opacity
            fade.toValue = target
            fade.duration = PresenceOverlayView.fade
            add(fade, forKey: "fade")
        }
        opacity = target
        CATransaction.commit()
    }

    /// A brief brighter glow when a new action arrives, without replaying the entrance.
    func pulse() {
        guard !PresenceOverlayView.reduceMotion else { return }
        let radius = CABasicAnimation(keyPath: "shadowRadius")
        radius.fromValue = 18
        radius.toValue = 9
        let strength = CABasicAnimation(keyPath: "shadowOpacity")
        strength.fromValue = 1
        strength.toValue = 0.55
        let group = CAAnimationGroup()
        group.animations = [radius, strength]
        group.duration = 1.1
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glow.add(group, forKey: "pulse")
    }

    func dismiss(animated: Bool) {
        guard animated, !PresenceOverlayView.reduceMotion else { removeFromSuperlayer(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.removeFromSuperlayer() } }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = presentation()?.opacity ?? opacity
        fade.toValue = 0
        fade.duration = PresenceOverlayView.fade
        add(fade, forKey: "fade")
        opacity = 0
        CATransaction.commit()
    }
}

/// A centered activity diamond whose breathing continues through label and appearance refreshes.
@MainActor
final class PresenceHoldLayer: CAShapeLayer {
    static let animationKey = "holdBreathing"

    override init() {
        super.init()
        let diamond = CGMutablePath()
        diamond.move(to: CGPoint(x: 3.5, y: 0))
        diamond.addLine(to: CGPoint(x: 7, y: 3.5))
        diamond.addLine(to: CGPoint(x: 3.5, y: 7))
        diamond.addLine(to: CGPoint(x: 0, y: 3.5))
        diamond.closeSubpath()
        path = diamond
        isHidden = true
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    func setHolding(_ holding: Bool, reduceMotion: Bool) {
        isHidden = !holding
        guard holding, !reduceMotion else {
            removeAnimation(forKey: Self.animationKey)
            return
        }
        guard animation(forKey: Self.animationKey) == nil else { return }
        let easing = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0.45, 1, 0.45]
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.9, 1, 0.9]
        for animation in [opacity, scale] {
            animation.keyTimes = [0, 0.5, 1]
            animation.timingFunctions = [easing, easing]
            animation.duration = 2.8
        }
        let breathing = CAAnimationGroup()
        breathing.animations = [opacity, scale]
        breathing.duration = 2.8
        breathing.repeatCount = .infinity
        breathing.beginTime = convertTime(CACurrentMediaTime(), from: nil)
        add(breathing, forKey: Self.animationKey)
    }
}

/// The name tag: status icon or spinner, agent name, optional note and elapsed time or result.
/// Text is drawn with CATextLayers and measured directly, without Auto Layout.
@MainActor
private final class PresenceTagView: NSButton {
    var generation = 0
    var isLeaving = false
    private(set) var isCompact = false
    var onActivate: (() -> Void)?
    private var item: PresenceOverlayItem?
    private var overflowCount: Int?
    private var scale: CGFloat = 2
    private var dark = true

    private let glass = NSGlassEffectView()
    private let textContent = PresenceTagContentView()

    var usesGlass: Bool { glass.superview === self && glass.contentView === textContent }
    var detailText: String { detail.string as? String ?? "" }
    var holdIconCenterY: CGFloat? { holdIcon.isHidden ? nil : holdIcon.frame.midY }
    var holdAnimationState: JSONValue {
        let shown = holdIcon.presentation() ?? holdIcon
        return .object([
            "active": .bool(holdIcon.animation(forKey: PresenceHoldLayer.animationKey) != nil),
            "reduceMotion": .bool(PresenceOverlayView.reduceMotion),
            "opacity": .number(Double(shown.opacity)),
            "scale": .number(shown.transform.m11),
            "centerY": .number(shown.position.y),
        ])
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, !isLeaving, frame.contains(point) else { return nil }
        return self
    }
    override var acceptsFirstResponder: Bool { isEnabled && !isLeaving }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    @objc private func activatePresence(_ sender: Any?) {
        guard isEnabled, !isLeaving else { return }
        onActivate?()
    }

    private let icon = CATextLayer()
    private let holdIcon = PresenceHoldLayer()
    private let spinner = CAShapeLayer()
    private let nameText = CATextLayer()
    private let note = CATextLayer()
    private let detail = CATextLayer()

    private static let nameFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
    private static let noteFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private static let iconFont = NSFont.systemFont(ofSize: 9, weight: .bold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // Keep the outer silhouette rounded even while the native glass resizes.
        layer?.cornerRadius = PresenceOverlayView.tagHeight / 2
        glass.autoresizingMask = [.width, .height]
        glass.style = .regular
        glass.cornerRadius = PresenceOverlayView.tagHeight / 2
        title = ""
        isBordered = false
        isEnabled = false
        target = self
        action = #selector(activatePresence(_:))
        focusRingType = .exterior
        textContent.wantsLayer = true
        glass.contentView = textContent
        addSubview(glass)
        setAccessibilityElement(false)
        for (text, font) in [(icon, Self.iconFont), (nameText, Self.nameFont), (note, Self.noteFont), (detail, Self.detailFont)] {
            text.font = font
            text.fontSize = font.pointSize
            text.truncationMode = .end
            text.alignmentMode = .left
            textContent.layer?.addSublayer(text)
        }
        spinner.fillColor = nil
        spinner.lineWidth = 1.5
        spinner.lineCap = .round
        spinner.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 9, height: 9), transform: nil)
        spinner.strokeEnd = 0.75
        spinner.isHidden = true
        textContent.layer?.addSublayer(spinner)
        textContent.layer?.addSublayer(holdIcon)
    }
    required init?(coder: NSCoder) { nil }

    /// Call inside the overlay's effective appearance.
    func configure(_ next: PresenceOverlayItem, scale: CGFloat, dark: Bool) {
        let swapped = item != nil && item?.note != next.note
        item = next
        isEnabled = next.originPane != nil
        setAccessibilityElement(true)
        setAccessibilityLabel("\(next.label)\(next.note.map { ": \($0)" } ?? "")")
        toolTip = next.originPane.map { "Focus \(next.label) in \($0)" } ?? "No live Slate terminal origin"
        overflowCount = nil
        restyle(scale: scale, dark: dark)
        if swapped, !PresenceOverlayView.reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.3
            note.add(fade, forKey: "swap")
        }
    }

    func configureOverflow(count: Int, scale: CGFloat, dark: Bool) {
        item = nil
        overflowCount = count
        isEnabled = false
        restyle(scale: scale, dark: dark)
    }

    func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        isCompact = compact
        relayoutContents()
    }

    /// Call inside the overlay's effective appearance.
    func restyle(scale: CGFloat, dark: Bool) {
        self.scale = scale
        self.dark = dark
        let agent = item.map { NSColor(rgb: $0.rgb) } ?? .secondaryLabelColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Text layers keep their status hues, so anchor the glass tint to the app's
        // appearance rather than letting bright page content wash out the foreground.
        let base = NSColor.windowBackgroundColor
        let tint = item == nil ? base : base.blended(withFraction: 0.22, of: agent) ?? base
        glass.tintColor = tint.withAlphaComponent(0.8)
        for text in [icon, nameText, note, detail] { text.contentsScale = scale }
        nameText.foregroundColor = (dark ? agent : agent.blended(withFraction: 0.35, of: .black) ?? agent).cgColor
        note.foregroundColor = NSColor.labelColor.cgColor
        var symbol = ""
        var text = ""
        var spinning = false
        var holding = false
        var statusColor = agent
        if let count = overflowCount {
            nameText.string = "+\(count)"
            nameText.foregroundColor = NSColor.secondaryLabelColor.cgColor
            note.string = ""
            symbol = ""
        } else if let item {
            nameText.string = item.label
            note.string = item.note ?? ""
            switch item.status {
            case .active, .held: holding = true
            case .live(let elapsed): spinning = true; text = elapsed
            case .ok(let value): symbol = "✓"; text = value ?? ""; statusColor = .labelColor
            case .failed(let value):
                symbol = "✕"; text = value ?? ""
                statusColor = NSColor.systemRed.blended(withFraction: dark ? 0.35 : 0.15, of: dark ? .white : .black) ?? .systemRed
            }
        }
        icon.string = symbol
        icon.foregroundColor = statusColor.cgColor
        detail.string = text
        detail.foregroundColor = (text.isEmpty || statusColor == agent ? NSColor.secondaryLabelColor : statusColor).cgColor
        spinner.strokeColor = agent.cgColor
        spinner.isHidden = !spinning
        holdIcon.fillColor = statusColor.cgColor
        holdIcon.setHolding(holding, reduceMotion: PresenceOverlayView.reduceMotion)
        icon.isHidden = spinning || holding || symbol.isEmpty
        if spinning, spinner.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = PresenceOverlayView.reduceMotion ? 2.4 : 0.8
            spin.repeatCount = .infinity
            spinner.add(spin, forKey: "spin")
        } else if !spinning {
            spinner.removeAnimation(forKey: "spin")
        }
        CATransaction.commit()
        relayoutContents()
    }

    func width(compact: Bool, maximum: CGFloat) -> CGFloat {
        min(maximum, ceil(segments(compact: compact).reduce(14) { $0 + $1.width } + CGFloat(max(0, segments(compact: compact).count - 1)) * 5))
    }

    private func segments(compact: Bool) -> [(layer: CALayer, width: CGFloat)] {
        var parts: [(CALayer, CGFloat)] = []
        if !spinner.isHidden { parts.append((spinner, 9)) }
        else if !holdIcon.isHidden { parts.append((holdIcon, 7)) }
        else if !icon.isHidden { parts.append((icon, Self.measure(icon.string as? String ?? "", Self.iconFont))) }
        parts.append((nameText, Self.measure(nameText.string as? String ?? "", Self.nameFont)))
        if !compact, let text = note.string as? String, !text.isEmpty { parts.append((note, Self.measure(text, Self.noteFont))) }
        if !compact, let text = detail.string as? String, !text.isEmpty { parts.append((detail, Self.measure(text, Self.detailFont))) }
        return parts
    }

    override func layout() {
        super.layout()
        relayoutContents()
    }

    private func relayoutContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.frame = bounds
        textContent.frame = glass.bounds
        let parts = segments(compact: isCompact)
        let shownLayers = Set(parts.map { ObjectIdentifier($0.layer) })
        for text in [icon, nameText, note, detail] where !shownLayers.contains(ObjectIdentifier(text)) { text.frame = .zero }
        var x: CGFloat = 7
        let limit = bounds.width - 7
        for (layer, natural) in parts {
            let width = max(0, min(natural, limit - x))
            if layer === spinner || layer === holdIcon {
                // Center the shape itself, independent of a font's baseline and glyph bearings.
                layer.frame = CGRect(x: x, y: (bounds.height - natural) / 2, width: natural, height: natural)
            } else {
                let lineHeight: CGFloat = layer === icon ? 11 : 13
                layer.frame = CGRect(x: x, y: (bounds.height - lineHeight) / 2, width: width, height: lineHeight)
            }
            x += width + 5
        }
        CATransaction.commit()
    }

    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// Match the overlay's top-left coordinates when hosting the text layers inside glass.
private final class PresenceTagContentView: NSView {
    override var isFlipped: Bool { true }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
