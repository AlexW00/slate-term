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

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Glows stay inside the pane instead of spilling over neighbouring panes.
        layer?.masksToBounds = true
        layer?.addSublayer(paneRing)
        overflow.alphaValue = 0
        addSubview(overflow)
        setAccessibilityElement(false)
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
            (item.element == nil ? paneRing : elementRings[item.id])?.pulse()
        }
        pulses = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.pulse) })
    }

    private func layoutItems(animated: Bool) {
        let paneItems = items.filter { $0.element == nil }
        withoutActions {
            paneRing.frame = bounds
            paneRing.update(path: CGPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 7, cornerHeight: 7, transform: nil),
                            colors: paneItems.map { NSColor(rgb: $0.rgb) })
        }
        paneRing.setVisible(!paneItems.isEmpty, animated: animated)
        // Only the highlight follows an element. Its pill stays in the pane corner.
        let elementItems = items.filter { $0.element != nil }
        for (id, ring) in elementRings where !elementItems.contains(where: { $0.id == id }) {
            elementRings[id] = nil
            ring.dismiss(animated: animated)
        }
        for item in elementItems {
            guard let element = item.element else { continue }
            let target = element.insetBy(dx: -4, dy: -4).intersection(bounds.insetBy(dx: 1, dy: 1))
            guard !target.isNull, target.width > 2, target.height > 2 else {
                elementRings[item.id]?.dismiss(animated: animated)
                elementRings[item.id] = nil
                continue
            }
            let ring = elementRings[item.id] ?? {
                let created = PresenceRingLayer()
                layer?.insertSublayer(created, above: paneRing)
                elementRings[item.id] = created
                return created
            }()
            withoutActions {
                ring.frame = bounds
                ring.update(path: CGPath(roundedRect: target, cornerWidth: 6, cornerHeight: 6, transform: nil), colors: [NSColor(rgb: item.rgb)])
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
    private let gradient = CAGradientLayer()
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
    func update(path: CGPath, colors: [NSColor]) {
        gradient.frame = bounds
        ringMask.frame = bounds
        glow.frame = bounds
        ringMask.path = path
        glow.path = path
        guard let last = colors.last else { return }
        let resolved = colors.map(\.cgColor)
        gradient.colors = resolved.count == 1 ? [resolved[0], resolved[0]] : resolved
        glow.strokeColor = last.withAlphaComponent(0.6).cgColor
        glow.shadowColor = last.cgColor
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
        var symbol = "●"
        var text = ""
        var spinning = false
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
            case .active: break
            case .live(let elapsed): spinning = true; text = elapsed
            case .held: symbol = "◆"; text = "held"
            case .ok(let value): symbol = "✓"; text = value ?? ""; statusColor = .systemGreen
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
        icon.isHidden = spinning || symbol.isEmpty
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
            if layer === spinner {
                layer.frame = CGRect(x: x, y: (bounds.height - 9) / 2, width: 9, height: 9)
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
