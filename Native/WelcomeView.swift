import AppKit
import SlateTermCore

/// Native content; only the explicit insert button sends terminal input. Frame-based document sizing avoids
/// imposing text's intrinsic width/height on the split tree's geometry constraints.
@MainActor
final class WelcomeView: NSScrollView {
    private let text = WelcomeLabel(wrappingLabelWithString: "")
    private let command = WelcomeLabel(wrappingLabelWithString: WelcomeContent.readCommand)
    private let insertButton = NSButton()
    private let document = WelcomeDocument()
    private let boundary = NSBox()
    private let inset: CGFloat = 16
    var onFocus: (() -> Void)? { didSet { text.onFocus = onFocus; command.onFocus = onFocus } }
    var onInsertCommand: (() -> Void)? { didSet { insertButton.isEnabled = onInsertCommand != nil } }

    init() {
        super.init(frame: .zero)
        drawsBackground = true
        backgroundColor = .windowBackgroundColor
        borderType = .noBorder
        hasVerticalScroller = true
        autohidesScrollers = true
        hasHorizontalScroller = false
        // Keep an overflow cue visible when a small pane needs local scrolling.
        scrollerStyle = .legacy
        text.isSelectable = false
        text.isEditable = false
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        text.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let content = WelcomeContent.current
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        style.lineSpacing = 2
        // Keep the shared copy, but lay out the command and its insert control as a row.
        let source = ([content.title] + content.paragraphs).joined(separator: "\n")
            .replacingOccurrences(of: " " + WelcomeContent.readCommand, with: "")
        let attributed = NSMutableAttributedString(string: source, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ])
        attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: (source as NSString).range(of: content.title))
        text.attributedStringValue = attributed
        let commandStyle = NSMutableParagraphStyle()
        commandStyle.lineSpacing = 2
        command.attributedStringValue = NSAttributedString(string: WelcomeContent.readCommand, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: commandStyle
        ])
        command.isSelectable = false
        command.isEditable = false
        insertButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        insertButton.isBordered = false
        insertButton.setButtonType(.momentaryPushIn)
        insertButton.refusesFirstResponder = true
        insertButton.contentTintColor = .secondaryLabelColor
        insertButton.toolTip = "Insert command into terminal (does not run it)"
        insertButton.setAccessibilityLabel("Insert welcome command into terminal")
        insertButton.setAccessibilityHelp("Inserts the command at the terminal cursor without pressing Return.")
        insertButton.isEnabled = false
        insertButton.target = self
        insertButton.action = #selector(insertCommand)
        for child in [text, command, insertButton] { document.addSubview(child) }
        documentView = document
        // Separate clipped native text from live terminal output without a panel.
        boundary.boxType = .separator
        boundary.setAccessibilityElement(false)
        addSubview(boundary, positioned: .above, relativeTo: nil)
        setAccessibilityLabel(content.title)
        updateScrollerContrast()
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateScrollerContrast()
    }

    private func updateScrollerContrast() {
        scrollerKnobStyle = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .light : .dark
    }

    private func rowMetrics(for width: CGFloat) -> (bodyHeight: CGFloat, commandWidth: CGFloat, rowHeight: CGFloat) {
        let available = max(1, width - inset * 2 - 10)
        func height(_ value: NSAttributedString, width: CGFloat) -> CGFloat {
            ceil(value.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
        }
        let commandWidth = min(ceil(command.attributedStringValue.size().width) + 4, max(1, available - 28))
        return (height(text.attributedStringValue, width: available), commandWidth,
                max(22, height(command.attributedStringValue, width: commandWidth) + 3))
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        let row = rowMetrics(for: width)
        return row.bodyHeight + row.rowHeight + inset * 2
    }

    @objc private func insertCommand() { onInsertCommand?() }
    func clickInsertCommandForTesting() { insertButton.performClick(nil) }

    override func layout() {
        super.layout()
        let width = contentSize.width
        let height = max(contentSize.height, preferredHeight(for: width))
        document.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let row = rowMetrics(for: width)
        text.frame = NSRect(x: inset, y: inset, width: max(1, width - inset * 2 - 10), height: row.bodyHeight)
        let rowY = inset + row.bodyHeight
        command.frame = NSRect(x: inset, y: rowY + 3, width: row.commandWidth, height: row.rowHeight - 3)
        insertButton.frame = NSRect(x: command.frame.maxX + 6, y: rowY, width: 22, height: 22)
        boundary.isHidden = height <= contentSize.height
        boundary.frame = NSRect(x: 0, y: isFlipped ? bounds.height - 1 : 0, width: bounds.width, height: 1)
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }
}

@MainActor private final class WelcomeDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class WelcomeLabel: NSTextField {
    var onFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onFocus?() }
}
