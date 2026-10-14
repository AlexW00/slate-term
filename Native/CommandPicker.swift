import AppKit
import SlateTermCore

struct PickerCommand {
    let item: CommandSearchItem
    let symbol: String
    let shortcut: String
    let unavailable: String?
}

/// A keyboard-first native command surface. One real Liquid Glass layer, not
/// stacked translucent rows. Opening/search/navigation are deliberately instant.
@MainActor
final class CommandPicker: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let search = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let count = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let runLabel = NSTextField(labelWithString: "Execute Command")
    private let runHint = NSStackView()
    private let empty = NSStackView()
    private var commands: [PickerCommand] = []
    private var results: [PickerCommand] = []
    private var mouseFocusedID: String?
    private weak var sourceWindow: NSWindow?
    private weak var sourceResponder: NSResponder?
    private weak var sourceEditorOwner: NSView?
    private var sourceSelection: NSRange?
    private var sourceResizeObserver: NSObjectProtocol?
    private(set) var isRestoringFocus = false
    var onExecute: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }
    private let secondaryColor = NSColor(name: nil) { appearance in
        // Keep a dynamic color: deriving labelColor.withAlphaComponent while
        // constructing the panel resolves it in the then-current appearance.
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(calibratedWhite: dark ? 0.76 : 0.32, alpha: 1)
    }

    init() {
        let panel = PickerPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 484),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Commands"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        super.init(window: panel)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.dismiss(restoreFocus: true) }
        buildContent(panel)
    }
    required init?(coder: NSCoder) { nil }
    isolated deinit {
        if let sourceResizeObserver { NotificationCenter.default.removeObserver(sourceResizeObserver) }
    }

    func show(commands: [PickerCommand], relativeTo proposedSource: NSWindow?) {
        let source = proposedSource === window ? nil : proposedSource
        if let sourceResizeObserver { NotificationCenter.default.removeObserver(sourceResizeObserver) }
        sourceResizeObserver = nil
        if let window { window.parent?.removeChildWindow(window) }
        sourceWindow = source
        sourceResponder = source?.firstResponder
        let editor = source?.firstResponder as? NSTextView
        sourceEditorOwner = editor?.isFieldEditor == true ? editor?.delegate as? NSView : nil
        sourceSelection = editor?.selectedRange()
        self.commands = commands
        window?.makeFirstResponder(nil)
        search.stringValue = ""
        reload(preserveSelection: false)
        guard let window else { return }
        if let source, source !== window {
            source.addChildWindow(window, ordered: .above)
            sourceResizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: source, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.centerWithinSource() == false { self?.dismiss(restoreFocus: true) }
                }
            }
        }
        guard centerWithinSource() else { dismiss(restoreFocus: true); NSSound.beep(); return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(search)
        search.selectText(nil)
    }

    private func centerWithinSource() -> Bool {
        guard let window else { return false }
        let source = sourceWindow
        let screen = source?.screen ?? NSScreen.main
        let available = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let content = source.map { $0.convertToScreen($0.contentLayoutRect) } ?? available
        let visibleContent = content.intersection(available)
        let anchor = source == nil ? available : visibleContent
        // An impossibly small content area cannot contain the search controls.
        // Dismiss rather than create a negative frame or spill outside the owner.
        guard !anchor.isEmpty, anchor.width >= 352, anchor.height >= 300 else { return false }
        let width = min(640, anchor.width - 32)
        // Keep full rows above the footer when fitting a smaller owner window.
        let maxHeight = min(484, anchor.height - 32)
        let chromeHeight: CGFloat = 148
        let height = chromeHeight + ((maxHeight - chromeHeight) / table.rowHeight).rounded(.down) * table.rowHeight
        let x = anchor.midX - width / 2
        let y = anchor.midY - height / 2
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        return true
    }

    func update(commands: [PickerCommand]) {
        self.commands = commands
        reload(preserveSelection: true)
    }

    func dismiss(restoreFocus: Bool) {
        if let sourceResizeObserver { NotificationCenter.default.removeObserver(sourceResizeObserver) }
        sourceResizeObserver = nil
        guard isVisible else {
            if let window { window.parent?.removeChildWindow(window) }
            return
        }
        let responder: NSResponder?
        if let owner = sourceEditorOwner { responder = owner.window === sourceWindow ? owner : nil }
        else if let editor = sourceResponder as? NSTextView, editor.isFieldEditor { responder = nil }
        else if let view = sourceResponder as? NSView, view.window === sourceWindow { responder = view }
        else { responder = nil }
        isRestoringFocus = restoreFocus && responder != nil
        defer { isRestoringFocus = false }
        if let window { window.parent?.removeChildWindow(window) }
        window?.orderOut(nil)
        if restoreFocus, let sourceWindow, sourceWindow.isVisible {
            sourceWindow.makeKeyAndOrderFront(nil)
            let sameEditor = sourceEditorOwner == nil || ((sourceResponder as? NSTextView)?.delegate as? NSView) === sourceEditorOwner
            // Re-entering a field that is still editing commits its draft first.
            // Keep that original editing session intact, including Escape semantics.
            if let responder, sourceWindow.firstResponder !== sourceResponder || !sameEditor { sourceWindow.makeFirstResponder(responder) }
            if let selection = sourceSelection, let editor = sourceWindow.firstResponder as? NSTextView,
               selection.location + selection.length <= (editor.string as NSString).length { editor.setSelectedRange(selection) }
        }
        onDismiss?()
    }
    func windowDidResignKey(_ notification: Notification) { dismiss(restoreFocus: false) }
    func controlTextDidChange(_ notification: Notification) { reload(preserveSelection: false) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Leave marked-text composition and its candidate navigation to the IME.
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)): dismiss(restoreFocus: true)
        default: return false
        }
        return true
    }

    private func buildContent(_ panel: NSPanel) {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 20
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 20
        glass.layer?.masksToBounds = true
        let content = NSView()
        glass.contentView = content
        panel.contentView = glass
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor), content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.topAnchor), content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        magnifier.contentTintColor = secondaryColor
        magnifier.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        search.placeholderString = "Search commands…"
        search.font = .systemFont(ofSize: 18)
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.setAccessibilityLabel("Search commands")
        (search.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        let escape = keycap("esc")
        let header = NSStackView(views: [magnifier, search, escape])
        header.orientation = .horizontal
        header.spacing = 14
        header.alignment = .centerY
        magnifier.widthAnchor.constraint(equalToConstant: 24).isActive = true
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let heading = NSTextField(labelWithString: "Commands")
        heading.font = .systemFont(ofSize: 11, weight: .medium)
        heading.textColor = secondaryColor
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = secondaryColor
        let section = NSStackView(views: [heading, NSView(), count])
        section.orientation = .horizontal

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 48
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clickedRow)
        table.doubleAction = #selector(clickedRow)
        table.setAccessibilityLabel("Commands")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        let emptyIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        let emptyTitle = NSTextField(labelWithString: "No commands found")
        emptyTitle.font = .systemFont(ofSize: 15, weight: .medium)
        let emptyDetail = NSTextField(labelWithString: "Try a different name or keyword.")
        emptyDetail.font = .systemFont(ofSize: 12)
        emptyDetail.textColor = secondaryColor
        empty.orientation = .vertical
        empty.spacing = 10
        [emptyIcon, emptyTitle, emptyDetail].forEach(empty.addArrangedSubview)

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = secondaryColor
        footer.lineBreakMode = .byTruncatingTail
        runHint.addArrangedSubview(runLabel)
        runHint.addArrangedSubview(keycap("↵"))
        runHint.orientation = .horizontal
        runHint.spacing = 8
        runLabel.font = .systemFont(ofSize: 11, weight: .medium)
        let bottom = NSStackView(views: [footer, NSView(), runHint])
        bottom.orientation = .horizontal
        bottom.spacing = 12
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let topLine = divider(), bottomLine = divider()
        for view in [header, topLine, section, scroll, empty, bottomLine, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: content.topAnchor), header.heightAnchor.constraint(equalToConstant: 68),
            topLine.topAnchor.constraint(equalTo: header.bottomAnchor), topLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: content.trailingAnchor), topLine.heightAnchor.constraint(equalToConstant: 1),
            section.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22), section.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            section.topAnchor.constraint(equalTo: topLine.bottomAnchor, constant: 9), section.heightAnchor.constraint(equalToConstant: 16),
            scroll.topAnchor.constraint(equalTo: section.bottomAnchor, constant: 5), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10), scroll.bottomAnchor.constraint(equalTo: bottomLine.topAnchor, constant: -8),
            bottomLine.leadingAnchor.constraint(equalTo: content.leadingAnchor), bottomLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomLine.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -40), bottomLine.heightAnchor.constraint(equalToConstant: 1),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22), bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            bottom.topAnchor.constraint(equalTo: bottomLine.bottomAnchor), bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    private func divider() -> NSView {
        let view = NSBox()
        view.boxType = .separator
        view.alphaValue = 0.45
        return view
    }
    private func keycap(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = secondaryColor
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 4
        label.layer?.borderWidth = 0.5
        label.layer?.borderColor = NSColor.separatorColor.cgColor
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: text == "esc" ? 28 : 22).isActive = true
        label.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return label
    }
    private func reload(preserveSelection: Bool) {
        let selected = results.indices.contains(table.selectedRow) ? results[table.selectedRow].item.id : nil
        let available = commands.filter { $0.unavailable == nil }
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.item.id, $0) })
        results = CommandSearch.results(available.map(\.item), query: search.stringValue).compactMap { byID[$0.id] }
        if !preserveSelection || !results.contains(where: { $0.item.id == mouseFocusedID && $0.item.id == selected }) { mouseFocusedID = nil }
        table.reloadData()
        let row = preserveSelection ? selected.flatMap { id in results.firstIndex { $0.item.id == id } } ?? 0 : 0
        if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        count.stringValue = "\(results.count)"
        empty.isHidden = !results.isEmpty
        scroll.isHidden = results.isEmpty
        updateFooter()
    }
    private func moveSelection(_ offset: Int) {
        mouseFocusedID = nil
        guard !results.isEmpty else { return }
        let index = min(max(table.selectedRow + offset, 0), results.count - 1)
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }
    private func updateFooter() {
        let selected = results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
        footer.stringValue = selected == nil ? "No matching commands" : "↑ ↓ to navigate"
        runHint.isHidden = selected == nil
    }
    private func activateSelection() {
        guard results.indices.contains(table.selectedRow), results[table.selectedRow].unavailable == nil else { NSSound.beep(); return }
        let id = results[table.selectedRow].item.id
        dismiss(restoreFocus: true)
        onExecute?(id)
    }
    @objc private func clickedRow() {
        window?.makeFirstResponder(search)
        (search.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (search.stringValue as NSString).length, length: 0))
        guard results.indices.contains(table.clickedRow) else { mouseFocusedID = nil; return }
        let id = results[table.clickedRow].item.id
        if mouseFocusedID == id { activateSelection() }
        else { mouseFocusedID = id }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateFooter() }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PickerRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = results[row]
        let icon = NSImageView(image: NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = secondaryColor
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let title = NSTextField(labelWithString: command.item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: command.item.detail)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = secondaryColor
        detail.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        let shortcut = NSTextField(labelWithString: command.shortcut)
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.textColor = secondaryColor
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, labels, NSView(), shortcut])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 14)
        row.setAccessibilityLabel(command.item.title + ", " + command.item.detail)
        return row
    }

    // Integration-only callers in WorkspaceHost; real widgets/data paths remain in use.
    func setQueryForTesting(_ value: String) {
        search.stringValue = value
        if let editor = search.currentEditor() as? NSTextView {
            editor.string = value
            editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        }
        reload(preserveSelection: false)
    }
    var contextWindow: NSWindow? { sourceWindow }
    func clickRowForTesting(_ row: Int, clickCount: Int = 1) throws {
        guard results.indices.contains(row), let window else { throw RPCFailure(code: -32602, message: "Picker row is unavailable") }
        table.scrollRowToVisible(row)
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: clickCount, pressure: 0) else {
            throw RPCFailure(code: -32000, message: "Could not create picker mouse events")
        }
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
    }
    var info: JSONValue {
        let frame = window?.frame ?? .zero
        let content = sourceWindow.map { $0.convertToScreen($0.contentLayoutRect) }
        return .object(["visible": .bool(isVisible), "query": .string(search.stringValue),
                 "insideSource": .bool(content?.contains(frame) ?? false),
                 "attachedToSource": .bool(sourceWindow != nil && window?.parent === sourceWindow),
                 "trackingSource": .bool(sourceResizeObserver != nil),
                 "keyWindow": .bool(window?.isKeyWindow == true), "applicationActive": .bool(NSApp.isActive),
                 "centerOffsetX": .number(content.map { frame.midX - $0.midX } ?? 0),
                 "centerOffsetY": .number(content.map { frame.midY - $0.midY } ?? 0),
                 "executeLabel": .string(runLabel.stringValue),
                 "selected": results.indices.contains(table.selectedRow) ? .string(results[table.selectedRow].item.id) : .null,
                 "results": .array(results.map { .object(["id": .string($0.item.id), "title": .string($0.item.title),
                    "enabled": .bool($0.unavailable == nil), "reason": $0.unavailable.map(JSONValue.string) ?? .null]) }),
                 "searchFocused": .bool((window?.firstResponder as? NSTextView)?.delegate === search),
                 "glass": .bool(window?.contentView is NSGlassEffectView)])
    }
}

@MainActor
private final class PickerPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
private final class PickerRow: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}
