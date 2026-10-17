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
}

/// Paints agent frames and tags above pane content. Like the inactive shade, it never
/// takes clicks or focus. Everything below this view is a plain CALayer, so updates never
/// mark view layout dirty, which web automation readiness checks would reject.
@MainActor
final class PresenceOverlayView: NSView {
    static let fade: TimeInterval = 0.45
    private static let move: TimeInterval = 0.3
    static let tagHeight: CGFloat = 21

    /// Distance from the top edge to the bottom of the pane header.
    var headerInset: CGFloat = 28 { didSet { if headerInset != oldValue { layoutItems(animated: false) } } }
    /// Where pane tags hang from when pane chrome continues below the header, such as a browser toolbar.
    var contentTop: CGFloat? { didSet { if contentTop != oldValue { layoutItems(animated: false) } } }
    private var tagTop: CGFloat { max(headerInset, contentTop ?? 0) }

    private var items: [PresenceOverlayItem] = []
    private var tags: [String: PresenceTagLayer] = [:]
    private var pulses: [String: Int] = [:]
    private let paneRing = PresenceRingLayer()
    private var elementRings: [String: PresenceRingLayer] = [:]
    private let overflow = PresenceTagLayer()

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Glows stay inside the pane instead of spilling over neighbouring panes.
        layer?.masksToBounds = true
        layer?.addSublayer(paneRing)
        overflow.opacity = 0
        layer?.addSublayer(overflow)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    override func accessibilityChildren() -> [Any]? { [] }

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
                    let created = PresenceTagLayer()
                    created.opacity = 0
                    layer?.addSublayer(created)
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
                tag.removeFromSuperlayer()
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
        var pending: [(PresenceTagLayer, CGRect?)] = []
        withoutActions {
            paneRing.frame = bounds
            paneRing.update(path: CGPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 7, cornerHeight: 7, transform: nil),
                            colors: paneItems.map { NSColor(rgb: $0.rgb) })
        }
        paneRing.setVisible(!paneItems.isEmpty, animated: animated)

        // Pane tags hang from the header's bottom edge at the top right. The first
        // arrival sits in the corner and later ones line up to its left.
        let available = max(0, bounds.width - 24)
        let newest = paneItems.max { $0.order < $1.order }?.id
        var compact = Set(paneItems.count >= 3 || bounds.width < 200 ? paneItems.map(\.id).filter { $0 != newest } : [])
        if bounds.width < 200, let newest { compact.insert(newest) }
        func widths() -> [String: CGFloat] {
            Dictionary(uniqueKeysWithValues: paneItems.compactMap { item in
                tags[item.id].map { (item.id, $0.width(compact: compact.contains(item.id), maximum: available)) }
            })
        }
        var sizes = widths()
        func total(_ shown: [PresenceOverlayItem]) -> CGFloat {
            shown.reduce(0) { $0 + (sizes[$1.id] ?? 0) } + CGFloat(max(0, shown.count - 1)) * 4
        }
        if total(paneItems) > available {
            compact.formUnion(paneItems.map(\.id).filter { $0 != newest })
            sizes = widths()
        }
        // Keep the corner tags and the newest; fold the rest into a "+N" chip.
        var shown = paneItems
        var hidden: [PresenceOverlayItem] = []
        let chipWidth: CGFloat = 34
        while shown.count > 1, total(shown) + chipWidth + 4 > available || (total(shown) > available) {
            guard let drop = shown.dropLast().last(where: { $0.id != newest }) ?? shown.first(where: { $0.id != newest }) else { break }
            shown.removeAll { $0.id == drop.id }
            hidden.append(drop)
        }
        var right = bounds.maxX - 12
        var paneFrames: [CGRect] = []
        for item in shown {
            guard let tag = tags[item.id] else { continue }
            let width = sizes[item.id] ?? 0
            let frame = CGRect(x: max(8, right - width), y: tagTop, width: width, height: Self.tagHeight)
            tag.setShape(.hanging, compact: compact.contains(item.id))
            right = frame.minX - 4
            paneFrames.append(frame)
            pending.append((tag, frame))
        }
        for item in hidden { if let tag = tags[item.id] { pending.append((tag, nil)) } }
        if hidden.isEmpty {
            fade(overflow, to: 0)
        } else {
            let frame = CGRect(x: max(8, right - chipWidth), y: tagTop, width: chipWidth, height: Self.tagHeight)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                overflow.configureOverflow(count: hidden.count, scale: window?.backingScaleFactor ?? 2, dark: effectiveAppearance.isDark)
            }
            paneFrames.append(frame)
            move(overflow, to: frame, animated: animated)
            fade(overflow, to: 1)
        }

        // Element tags sit above the element's own frame, clear of pane tags and each other.
        let elementItems = items.filter { $0.element != nil }
        for (id, ring) in elementRings where !elementItems.contains(where: { $0.id == id }) {
            elementRings[id] = nil
            ring.dismiss(animated: animated)
        }
        var occupied = paneFrames
        let usable = bounds.insetBy(dx: 1, dy: 1)
        for item in elementItems {
            guard let element = item.element, let tag = tags[item.id] else { continue }
            let target = element.insetBy(dx: -4, dy: -4).intersection(usable)
            guard !target.isNull, target.width > 2, target.height > 2 else {
                // The element moved out of view; drop its frame rather than draw a stale one.
                elementRings[item.id]?.dismiss(animated: animated)
                elementRings[item.id] = nil
                pending.append((tag, nil))
                continue
            }
            let ring = elementRings[item.id] ?? {
                let created = PresenceRingLayer()
                layer?.insertSublayer(created, below: overflow)
                elementRings[item.id] = created
                return created
            }()
            withoutActions {
                ring.frame = bounds
                ring.update(path: CGPath(roundedRect: target, cornerWidth: 6, cornerHeight: 6, transform: nil), colors: [NSColor(rgb: item.rgb)])
            }
            ring.setVisible(true, animated: animated)
            tag.setShape(.pill, compact: false)
            let width = tag.width(compact: false, maximum: max(60, bounds.width - 16))
            var frame = CGRect(x: min(max(4, target.minX), bounds.maxX - width - 4), y: target.minY - Self.tagHeight - 4,
                               width: width, height: Self.tagHeight)
            if frame.minY < tagTop + 2 { frame.origin.y = target.maxY + 4 }
            var attempts = 0
            while occupied.contains(where: { $0.intersects(frame) }), attempts < 8 {
                frame.origin.y += Self.tagHeight + 3
                attempts += 1
            }
            frame.origin.y = min(frame.minY, bounds.maxY - Self.tagHeight - 2)
            occupied.append(frame)
            pending.append((tag, frame))
        }

        for (tag, frame) in pending {
            guard let frame else {
                if !tag.isLeaving { fade(tag, to: 0) }
                continue
            }
            let appearing = tag.opacity == 0 && tag.animation(forKey: "fade") == nil
            move(tag, to: frame, animated: animated && !appearing)
            if !tag.isLeaving { fade(tag, to: 1) }
        }
    }

    private func move(_ layer: CALayer, to frame: CGRect, animated: Bool) {
        guard layer.frame != frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Self.reduceMotion)
        CATransaction.setAnimationDuration(Self.move)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.frame = frame
        CATransaction.commit()
    }

    private func fade(_ layer: CALayer, to target: Float, completion: (@MainActor () -> Void)? = nil) {
        guard layer.opacity != target else { completion?(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
        if !Self.reduceMotion {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
            animation.toValue = target
            animation.duration = Self.fade
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(animation, forKey: "fade")
        }
        layer.opacity = target
        CATransaction.commit()
    }

    private func withoutActions(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

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
                fields["shown"] = .bool(tag.opacity > 0)
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
private final class PresenceTagLayer: CALayer {
    enum Shape { case hanging, pill }
    var generation = 0
    var isLeaving = false
    private(set) var isCompact = false
    private var shape = Shape.pill
    private var item: PresenceOverlayItem?
    private var overflowCount: Int?
    private var scale: CGFloat = 2
    private var dark = true

    private let icon = CATextLayer()
    private let spinner = CAShapeLayer()
    private let nameText = CATextLayer()
    private let note = CATextLayer()
    private let detail = CATextLayer()

    private static let nameFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
    private static let noteFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    private static let detailFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private static let iconFont = NSFont.systemFont(ofSize: 9, weight: .bold)

    override init() {
        super.init()
        borderWidth = 1
        cornerRadius = 8
        shadowOpacity = 0.25
        shadowRadius = 5
        shadowOffset = CGSize(width: 0, height: 2)
        for (text, font) in [(icon, Self.iconFont), (nameText, Self.nameFont), (note, Self.noteFont), (detail, Self.detailFont)] {
            text.font = font
            text.fontSize = font.pointSize
            text.truncationMode = .end
            text.alignmentMode = .left
            addSublayer(text)
        }
        spinner.fillColor = nil
        spinner.lineWidth = 1.5
        spinner.lineCap = .round
        spinner.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 9, height: 9), transform: nil)
        spinner.strokeEnd = 0.75
        spinner.isHidden = true
        addSublayer(spinner)
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { nil }

    /// Call inside the overlay's effective appearance.
    func configure(_ next: PresenceOverlayItem, scale: CGFloat, dark: Bool) {
        let swapped = item != nil && item?.note != next.note
        item = next
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
        shape = .hanging
        restyle(scale: scale, dark: dark)
    }

    func setShape(_ next: Shape, compact: Bool) {
        guard next != shape || compact != isCompact else { return }
        shape = next
        isCompact = compact
        relayoutContents()
    }

    /// Call inside the overlay's effective appearance.
    func restyle(scale: CGFloat, dark: Bool) {
        self.scale = scale
        self.dark = dark
        let agent = item.map { NSColor(rgb: $0.rgb) } ?? .secondaryLabelColor
        let base = NSColor.windowBackgroundColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentsScale = scale
        backgroundColor = (base.blended(withFraction: 0.22, of: agent) ?? base).cgColor
        borderColor = agent.withAlphaComponent(0.5).cgColor
        shadowColor = NSColor.black.cgColor
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
            case .failed(let value): symbol = "✕"; text = value ?? ""; statusColor = .systemRed
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

    override func layoutSublayers() {
        super.layoutSublayers()
        relayoutContents()
    }

    private func relayoutContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A hanging tag joins the header edge, so only its lower corners are round.
        // The overlay is flipped, so this layer's maximum Y is its visual bottom.
        maskedCorners = shape == .hanging
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
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

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
