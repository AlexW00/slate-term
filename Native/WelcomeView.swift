import AppKit
import SlateTermCore

/// Native content; only explicit insert buttons send terminal input. Frame-based document sizing avoids
/// imposing text's intrinsic width/height on the split tree's geometry constraints.
@MainActor
final class WelcomeView: NSScrollView {
    private struct Row {
        let label: WelcomeLabel
        let button: NSButton?
        let command: String?
    }
    private var rows: [Row] = []
    private let document = WelcomeDocument()
    private let boundary = NSBox()
    private let inset: CGFloat = 16
    var onFocus: (() -> Void)? { didSet { for row in rows { row.label.onFocus = onFocus } } }
    var onInsertCommand: ((String) -> Void)? {
        didSet { for row in rows { row.button?.isEnabled = onInsertCommand != nil } }
    }

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
        let content = WelcomeContent.current
        let intro = content.title + "\n" + content.paragraphs[0]
        addRow(intro)
        let attributed = NSMutableAttributedString(attributedString: rows[0].label.attributedStringValue)
        attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                range: (intro as NSString).range(of: content.title))
        rows[0].label.attributedStringValue = attributed
        for (paragraph, command) in zip(content.paragraphs.dropFirst(), [WelcomeContent.skillCommand, WelcomeContent.readCommand]) {
            addRow(paragraph.replacingOccurrences(of: " " + command, with: ""))
            addRow(command, command: command)
        }
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

    private func addRow(_ value: String, command: String? = nil) {
        let label = WelcomeLabel(wrappingLabelWithString: "")
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = command == nil ? 6 : 0
        style.lineSpacing = 2
        label.attributedStringValue = NSAttributedString(string: value, attributes: [
            .font: command == nil ? NSFont.systemFont(ofSize: 12) : NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: style
        ])
        label.isSelectable = false
        label.isEditable = false
        label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        label.setContentCompressionResistancePriority(.init(1), for: .vertical)
        var button: NSButton?
        if let command {
            let insert = NSButton()
            insert.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            insert.isBordered = false
            insert.setButtonType(.momentaryPushIn)
            insert.refusesFirstResponder = true
            insert.contentTintColor = .secondaryLabelColor
            insert.toolTip = "Insert command into terminal (does not run it)"
            insert.setAccessibilityLabel(command == WelcomeContent.skillCommand
                ? "Insert skill setup command into terminal" : "Insert welcome command into terminal")
            insert.setAccessibilityHelp("Inserts the command at the terminal cursor without pressing Return.")
            insert.isEnabled = false
            insert.tag = rows.count
            insert.target = self
            insert.action = #selector(insertCommand(_:))
            document.addSubview(insert)
            button = insert
        }
        document.addSubview(label)
        rows.append(Row(label: label, button: button, command: command))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateScrollerContrast()
    }

    private func updateScrollerContrast() {
        scrollerKnobStyle = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .light : .dark
    }

    private func rowMetrics(_ row: Row, width: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let available = max(1, width - inset * 2 - 10 - (row.button == nil ? 0 : 28))
        let labelWidth = row.button == nil ? available : min(ceil(row.label.attributedStringValue.size().width) + 4, available)
        let height = ceil(row.label.attributedStringValue.boundingRect(
            with: NSSize(width: labelWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
        return (labelWidth, max(row.button == nil ? 0 : 22, height + 3))
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        rows.reduce(inset * 2) { $0 + rowMetrics($1, width: width).height + 4 }
    }

    @objc private func insertCommand(_ sender: NSButton) {
        if let command = rows[sender.tag].command { onInsertCommand?(command) }
    }
    func clickInsertCommandForTesting(_ command: String = WelcomeContent.readCommand) {
        rows.first { $0.command == command }?.button?.performClick(nil)
    }

    override func layout() {
        super.layout()
        let width = contentSize.width
        let height = max(contentSize.height, preferredHeight(for: width))
        document.frame = NSRect(x: 0, y: 0, width: width, height: height)
        var y = inset
        for row in rows {
            let metrics = rowMetrics(row, width: width)
            row.button?.frame = NSRect(x: inset, y: y, width: 22, height: 22)
            row.label.frame = NSRect(x: inset + (row.button == nil ? 0 : 28), y: y + 3,
                                     width: metrics.width, height: metrics.height - 3)
            y += metrics.height + 4
        }
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
