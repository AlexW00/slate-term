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
    private enum BannerPlacement { case beside, above, hidden }
    private struct Arrangement {
        let placement: BannerPlacement
        let textColumn: CGFloat
        let textTop: CGFloat
        let banner: NSRect
        let height: CGFloat
    }
    private var rows: [Row] = []
    private let document = WelcomeDocument()
    private let banner = WelcomeBannerView()
    private let boundary = NSBox()
    private let inset: CGFloat = 16
    private let bannerGap: CGFloat = 48
    private let stackGap: CGFloat = 16
    // The banner only sits beside text that can keep at least this width.
    private let minTextColumn: CGFloat = 340
    /// The most height the pane can give this view. The banner only appears when it fits within it.
    var heightLimit: CGFloat = .greatestFiniteMagnitude {
        didSet { if heightLimit != oldValue { needsLayout = true } }
    }
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
        addRow(content.title)
        let attributed = NSMutableAttributedString(attributedString: rows[0].label.attributedStringValue)
        attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                range: NSRange(location: 0, length: (content.title as NSString).length))
        rows[0].label.attributedStringValue = attributed
        for (paragraph, command) in zip(content.paragraphs, [WelcomeContent.skillCommand, WelcomeContent.readCommand]) {
            addRow(paragraph.replacingOccurrences(of: " " + command, with: ""))
            addRow(command, command: command)
        }
        document.addSubview(banner)
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
            let insert = WelcomeCommandButton()
            insert.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
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

    /// Measures a row within a text column, which excludes the outer insets.
    private func rowMetrics(_ row: Row, column: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let available = max(1, column - 10 - (row.button == nil ? 0 : 28))
        let labelWidth = row.button == nil ? available : min(ceil(row.label.attributedStringValue.size().width) + 4, available)
        let height = ceil(row.label.attributedStringValue.boundingRect(
            with: NSSize(width: labelWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
        return (labelWidth, max(row.button == nil ? 0 : 22, height + 3))
    }

    private func textHeight(column: CGFloat) -> CGFloat {
        rows.reduce(0) { $0 + rowMetrics($1, column: column).height + 4 }
    }

    /// The column width at which no row wraps.
    private var naturalTextWidth: CGFloat {
        rows.map { ceil($0.label.attributedStringValue.size().width) + 4 + 10 + ($0.button == nil ? 0 : 28) }.max() ?? 0
    }

    /// Uses the first banner placement that fits: beside the text, above it, or not at all.
    /// The banner never shrinks or wraps, because its columns must stay aligned.
    private func arrangement(for width: CGFloat) -> Arrangement {
        let content = width - inset * 2
        let limit = heightLimit - inset * 2
        let art = banner.intrinsicContentSize
        // The banner follows the text at a fixed gap; spare width stays on the trailing side.
        // Text wraps only when its natural width does not leave room for the banner.
        if min(naturalTextWidth, minTextColumn) + bannerGap + art.width <= content {
            let column = min(naturalTextWidth, content - bannerGap - art.width)
            // Centre the wordmark letters on the text. The subtitle hangs below and does not count.
            let text = textHeight(column: column)
            let bannerTop = (text - banner.lettersHeight) / 2
            let top = min(0, bannerTop)
            let height = max(text, bannerTop + art.height) - top
            if height <= limit {
                let frame = NSRect(x: column + bannerGap, y: bannerTop - top, width: art.width, height: art.height)
                return Arrangement(placement: .beside, textColumn: column, textTop: -top, banner: frame, height: height)
            }
        }
        if art.width <= content {
            let height = art.height + stackGap + textHeight(column: content)
            if height <= limit {
                let frame = NSRect(x: 0, y: 0, width: art.width, height: art.height)
                return Arrangement(placement: .above, textColumn: content, textTop: art.height + stackGap,
                                   banner: frame, height: height)
            }
        }
        return Arrangement(placement: .hidden, textColumn: content, textTop: 0, banner: .zero,
                           height: textHeight(column: content))
    }

    func preferredHeight(for width: CGFloat) -> CGFloat {
        arrangement(for: width).height + inset * 2
    }

    var bannerFrameForTesting: NSRect? { banner.isHidden ? nil : banner.frame }

    @objc private func insertCommand(_ sender: NSButton) {
        if let command = rows[sender.tag].command { onInsertCommand?(command) }
    }
    func clickInsertCommandForTesting(_ command: String = WelcomeContent.readCommand) {
        rows.first { $0.command == command }?.button?.performClick(nil)
    }

    override func layout() {
        super.layout()
        let width = contentSize.width
        let arrangement = arrangement(for: width)
        let height = max(contentSize.height, arrangement.height + inset * 2)
        document.frame = NSRect(x: 0, y: 0, width: width, height: height)
        banner.isHidden = arrangement.placement == .hidden
        banner.frame = arrangement.banner.offsetBy(dx: inset, dy: inset)
        var y = inset + arrangement.textTop
        for row in rows {
            let metrics = rowMetrics(row, column: arrangement.textColumn)
            row.label.frame = NSRect(x: inset, y: y + 3,
                                     width: metrics.width, height: metrics.height - 3)
            row.button?.frame = NSRect(x: row.label.frame.maxX + 6, y: y, width: 22, height: 22)
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

@MainActor private final class WelcomeCommandButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

@MainActor private final class WelcomeDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class WelcomeLabel: NSTextField {
    var onFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onFocus?() }
}

/// Decorative `>_ SLATE` wordmark in the ANSI Shadow block style, with a hanging subtitle.
/// Rows step by the full-block glyph's height so block characters touch vertically.
@MainActor private final class WelcomeBannerView: NSView {
    // Every row has the same column count so the letters stay aligned.
    private static let rows = [
        "██╗              ███████╗██╗      █████╗ ████████╗███████╗",
        "╚██╗             ██╔════╝██║     ██╔══██╗╚══██╔══╝██╔════╝",
        " ╚██╗            ███████╗██║     ███████║   ██║   █████╗  ",
        " ██╔╝            ╚════██║██║     ██╔══██║   ██║   ██╔══╝  ",
        "██╔╝  ███████╗   ███████║███████╗██║  ██║   ██║   ███████╗",
        "╚═╝   ╚══════╝   ╚══════╝╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝",
    ]
    private static let subtitle = "T E R M I N A L"
    private static let subtitleGap: CGFloat = 6

    // Menlo includes every block and box-drawing character used above.
    private let font = NSFont(name: "Menlo-Regular", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
    private let subtitleFont = NSFont(name: "Menlo-Regular", size: 9) ?? .monospacedSystemFont(ofSize: 9, weight: .regular)
    private let block: CGRect

    override init(frame: NSRect) {
        var character: UniChar = 0x2588
        var glyph: CGGlyph = 0
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        block = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Height of the six letter rows, without the subtitle.
    var lettersHeight: CGFloat { block.height * CGFloat(Self.rows.count) }

    private var subtitleLineHeight: CGFloat { ceil(subtitleFont.ascender - subtitleFont.descender) }

    override var intrinsicContentSize: NSSize {
        let columns = Self.rows.map(\.count).max() ?? 0
        return NSSize(width: ceil(advance * CGFloat(columns)),
                      height: ceil(lettersHeight + Self.subtitleGap + subtitleLineHeight))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var advance: CGFloat { ("█" as NSString).size(withAttributes: [.font: font]).width }

    override func draw(_ dirtyRect: NSRect) {
        let advance = advance
        let shadow: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        // Snap cell edges to device pixels so neighbouring blocks share edges without seams.
        let snap = { (x: CGFloat, y: CGFloat) in self.backingAlignedRect(NSRect(x: x, y: y, width: 0, height: 0),
                                                                         options: .alignAllEdgesNearest).origin }
        for (index, row) in Self.rows.enumerated() {
            let top = CGFloat(index) * block.height
            var runStart: Int?
            // A trailing space closes a run that reaches the last column.
            for (column, character) in (Array(row) + [" "]).enumerated() {
                if character == "█" {
                    if runStart == nil { runStart = column }
                    continue
                }
                if let start = runStart {
                    // Solid blocks are filled rectangles. Glyphs leave hairline gaps between cells.
                    let origin = snap(CGFloat(start) * advance, top)
                    let end = snap(CGFloat(column) * advance, top + block.height)
                    // Text drawing changes the fill color, so set it for every run.
                    NSColor.labelColor.setFill()
                    NSRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y).fill()
                    runStart = nil
                }
                guard character != " ", column < row.count else { continue }
                // The thin box-drawing shadow stays as text and recedes. Without .usesLineFragmentOrigin,
                // the rect origin is the baseline.
                NSAttributedString(string: String(character), attributes: shadow).draw(
                    with: NSRect(x: CGFloat(column) * advance, y: top + block.maxY, width: advance, height: 0),
                    options: [], context: nil)
            }
        }
        let subtitle = NSAttributedString(string: Self.subtitle, attributes: [
            .font: subtitleFont, .foregroundColor: NSColor.secondaryLabelColor
        ])
        let x = bounds.width - ceil(subtitle.size().width)
        let baseline = lettersHeight + Self.subtitleGap + subtitleFont.ascender
        subtitle.draw(with: NSRect(x: x, y: baseline, width: bounds.width, height: 0), options: [], context: nil)
    }
}
