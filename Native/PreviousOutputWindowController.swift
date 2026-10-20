import AppKit
import SlateTermSettings

/// Historical text stays separate from the live terminal and never accepts input.
@MainActor
final class PreviousOutputWindowController: NSWindowController {
    private let text = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let clear = NSButton(title: "Clear Previous Output", target: nil, action: nil)
    var onClear: (() -> Void)?

    init(output: SavedTerminalOutput) {
        let panel = PreviousOutputPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Previous Terminal Output"
        panel.minSize = NSSize(width: 420, height: 300)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.find = { [weak self] in self?.showFind() }
        let content = NSView()
        panel.contentView = content
        let explanation = NSTextField(wrappingLabelWithString: "Saved from an earlier terminal session. Select and copy text, or press ⌘F to find.")
        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: 12)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        clear.target = self
        clear.action = #selector(clearOutput)
        clear.bezelStyle = .rounded
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.findBarPosition = .aboveContent
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isAutomaticTextReplacementEnabled = false
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel("Previous terminal output, read only")
        scroll.documentView = text
        for child in [explanation, scroll, status, clear] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            explanation.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            explanation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            explanation.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: clear.topAnchor, constant: -12),
            clear.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            clear.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(lessThanOrEqualTo: clear.leadingAnchor, constant: -12),
            status.centerYAnchor.constraint(equalTo: clear.centerYAnchor),
        ])
        update(output)
        panel.center()
    }

    required init?(coder: NSCoder) { nil }

    func update(_ output: SavedTerminalOutput) {
        text.string = output.text
        status.stringValue = "Saved " + output.capturedAt.formatted(date: .abbreviated, time: .shortened)
            + (output.ended ? " · Session ended" : " · Last snapshot")
        status.toolTip = status.stringValue
        scrollToLatestOutput()
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(text)
        scrollToLatestOutput()
    }

    private func scrollToLatestOutput() {
        window?.contentView?.layoutSubtreeIfNeeded()
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        text.scrollToEndOfDocument(nil)
        // The initial zero-size text view can otherwise leave line beginnings offscreen.
        scrollHorizontally(toEnd: false)
    }

    var horizontalOffset: CGFloat { text.enclosingScrollView?.contentView.bounds.minX ?? 0 }
    func scrollHorizontally(toEnd: Bool) {
        guard let scroll = text.enclosingScrollView else { return }
        let clip = scroll.contentView
        let end = max(0, text.bounds.width - clip.bounds.width)
        clip.scroll(to: NSPoint(x: toEnd ? end : 0, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
    }

    var savedText: String { text.string }
    var isReadOnly: Bool { !text.isEditable }
    var findVisible: Bool { text.enclosingScrollView?.isFindBarVisible == true }
    func showFind() {
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        text.performFindPanelAction(item)
    }
    func pressFindShortcut() {
        guard let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f",
            charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3) else { return }
        _ = window.performKeyEquivalent(with: event)
    }
    func clickClear() { clear.performClick(nil) }

    @objc private func clearOutput() { onClear?() }
}

@MainActor
private final class PreviousOutputPanel: NSPanel {
    var find: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            find?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
