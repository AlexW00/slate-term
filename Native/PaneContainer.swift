import AppKit
import SlateTermCore

/// Stable chrome around retained content; split reparenting never recreates a surface.
@MainActor
final class PaneContainer: NSViewController, NSTextFieldDelegate {
    let content: NSViewController
    private let typeName: String
    private let typeID: String
    private let paneID: PaneID
    private let copyIDButton = PaneHeaderButton()
    private var copyPasteboard = NSPasteboard.general
    private let typeButton = PaneHeaderButton()
    private let titleField = PaneTitleField(string: "")
    private let closeButton = PaneHeaderButton()
    let dragHandle = PaneDragHandle(frame: .zero)
    var moveMenu: (() -> NSMenu)?
    var dropView: PaneDropView { view as! PaneDropView }
    private let header = PaneHeaderView()
    private var latestTitle = ""
    private var editingOriginal: String?
    private var cancellingEdit = false
    var onClose: (() -> Void)?
    var onFocus: (() -> Void)?
    var onRename: ((String) -> Void)?
    var typeChoices: (() -> [(name: String, id: String)])?
    var onChangeType: ((String) -> Void)?

    init(content: NSViewController, type: String, typeID: String, paneID: PaneID) {
        self.content = content
        self.typeName = type
        self.typeID = typeID
        self.paneID = paneID
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = PaneDropView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        addChild(content)
        header.onFocus = { [weak self] in self?.onFocus?() }
        dragHandle.target = self
        dragHandle.action = #selector(showMoveMenu)
        dragHandle.dragTitle = { [weak self] in self.map { "\($0.typeName): \($0.latestTitle)" } ?? "Move Pane" }
        typeButton.title = typeName
        typeButton.font = .systemFont(ofSize: 11, weight: .semibold)
        typeButton.contentTintColor = .secondaryLabelColor
        typeButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        typeButton.imagePosition = .imageTrailing
        typeButton.isBordered = false
        typeButton.lineBreakMode = .byTruncatingTail
        typeButton.target = self
        typeButton.action = #selector(showTypeMenu)
        typeButton.toolTip = "Change Pane Type"
        typeButton.setAccessibilityLabel("Pane type: \(typeName)")
        titleField.font = .systemFont(ofSize: 11)
        titleField.alignment = .center
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.delegate = self
        titleField.setAccessibilityLabel("Pane title")
        titleField.onClick = { [weak self] in
            self?.onFocus?()
            self?.beginTitleEditing()
        }
        typeButton.setContentHuggingPriority(.required, for: .horizontal)
        typeButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copyIDButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        copyIDButton.isBordered = false
        copyIDButton.setButtonType(.momentaryPushIn)
        copyIDButton.target = self
        copyIDButton.action = #selector(copyPaneID)
        copyIDButton.setAccessibilityLabel("Copy Panel ID: \(paneID.description)")
        copyIDButton.toolTip = "Copy Panel ID"
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryPushIn)
        closeButton.target = self
        closeButton.action = #selector(closePane)
        closeButton.setAccessibilityLabel("Close \(typeName) Pane")
        closeButton.toolTip = "Close Pane"
        for child in [dragHandle, typeButton, titleField, copyIDButton, closeButton] { child.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(child) }
        for child in [header, content.view] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        // Fill the largest symmetric title region without compressing the type control.
        let preferredTitleWidth = titleField.widthAnchor.constraint(equalTo: header.widthAnchor)
        preferredTitleWidth.priority = .init(500)
        let titleLeadingLimit = titleField.leadingAnchor.constraint(greaterThanOrEqualTo: typeButton.trailingAnchor, constant: 8)
        let titleTrailingLimit = titleField.trailingAnchor.constraint(lessThanOrEqualTo: copyIDButton.leadingAnchor, constant: -6)
        // At the split's 80-point minimum there may be no title space at all.
        // Collapse the title rather than breaking its center or required control constraints.
        titleLeadingLimit.priority = .init(999)
        titleTrailingLimit.priority = .init(999)
        NSLayoutConstraint.activate([
            preferredTitleWidth, titleLeadingLimit, titleTrailingLimit,
            header.topAnchor.constraint(equalTo: view.topAnchor), header.leadingAnchor.constraint(equalTo: view.leadingAnchor), header.trailingAnchor.constraint(equalTo: view.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 28),
            dragHandle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 3), dragHandle.centerYAnchor.constraint(equalTo: header.centerYAnchor), dragHandle.widthAnchor.constraint(equalToConstant: 20), dragHandle.heightAnchor.constraint(equalToConstant: 22),
            typeButton.leadingAnchor.constraint(equalTo: dragHandle.trailingAnchor, constant: 3), typeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor), typeButton.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor, multiplier: 0.35),
            titleField.centerXAnchor.constraint(equalTo: header.centerXAnchor), titleField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            copyIDButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2), copyIDButton.centerYAnchor.constraint(equalTo: header.centerYAnchor), copyIDButton.widthAnchor.constraint(equalToConstant: 22), copyIDButton.heightAnchor.constraint(equalToConstant: 22),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -5), closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor), closeButton.widthAnchor.constraint(equalToConstant: 22), closeButton.heightAnchor.constraint(equalToConstant: 22),
            content.view.topAnchor.constraint(equalTo: header.bottomAnchor), content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func setTitle(_ title: String) {
        _ = view
        latestTitle = String(title.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(512))
        // Keep receiving live titles, but never replace an in-progress draft.
        if editingOriginal == nil && titleField.currentEditor() == nil { titleField.stringValue = latestTitle }
        titleField.toolTip = latestTitle
        header.setAccessibilityLabel("\(typeName): \(latestTitle)")
        closeButton.setAccessibilityLabel("Close \(typeName) Pane: \(latestTitle)")
        dragHandle.setAccessibilityLabel("Move \(typeName) Pane: \(latestTitle)")
    }

    private func beginTitleEditing() {
        if editingOriginal == nil { editingOriginal = titleField.stringValue }
    }

    func controlTextDidBeginEditing(_ notification: Notification) { beginTitleEditing() }

    func controlTextDidEndEditing(_ notification: Notification) {
        let original = editingOriginal ?? latestTitle
        let title = titleField.stringValue
        editingOriginal = nil
        if !cancellingEdit && title != original { onRename?(title) }
        titleField.stringValue = latestTitle
        cancellingEdit = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) || commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        cancellingEdit = commandSelector == #selector(NSResponder.cancelOperation(_:))
        view.window?.makeFirstResponder(nil)
        onFocus?()
        return true
    }

    func makeTypeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for choice in typeChoices?() ?? [] {
            let item = menu.addItem(withTitle: choice.name, action: #selector(changeType(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = choice.id == typeID ? .on : .off
            item.isEnabled = choice.id != typeID
        }
        return menu
    }

    @objc private func showMoveMenu() {
        guard let menu = moveMenu?() else { return }
        presentMoveMenu(menu)
    }
    func presentMoveMenu(_ menu: NSMenu) {
        // Keep the responder intact: dismissing the menu must not disable terminal input.
        menu.popUp(positioning: nil, at: .zero, in: dragHandle)
    }
    @objc private func showTypeMenu() { presentTypeMenu(makeTypeMenu()) }
    func presentTypeMenu(_ menu: NSMenu) {
        view.window?.makeFirstResponder(nil)
        menu.popUp(positioning: nil, at: .zero, in: typeButton)
    }
    @objc private func changeType(_ sender: NSMenuItem) {
        guard let type = sender.representedObject as? String else { return }
        onChangeType?(type)
    }
    @objc private func copyPaneID() {
        copyPasteboard.clearContents()
        guard copyPasteboard.setString(paneID.description, forType: .string) else { return }
        copyIDButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyIDButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        }
    }
    @objc private func closePane() { onClose?() }
    func performClose() { closeButton.performClick(nil) }

    /// Exercise the real button without overwriting the user's clipboard.
    func copyIDForTesting() -> String? {
        _ = view
        let pasteboard = NSPasteboard.withUniqueName()
        copyPasteboard = pasteboard
        defer { copyPasteboard = .general; pasteboard.releaseGlobally() }
        copyIDButton.performClick(nil)
        return pasteboard.string(forType: .string)
    }

    func editTitleForTesting(_ text: String?, finish: String?) throws {
        _ = view
        if titleField.currentEditor() == nil {
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            titleField.mouseDown(with: event)
        }
        guard let editor = titleField.currentEditor() as? NSTextView else { throw RPCFailure(code: -32000, message: "Pane title editor did not open") }
        if let text { editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count)) }
        switch finish {
        case "commit": editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        case "cancel": editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        case "blur": view.window?.makeFirstResponder(nil)
        default: break
        }
    }

    var info: JSONValue {
        view.layoutSubtreeIfNeeded()
        // Constraints use alignment rects; NSTextField's frame has two-point side outsets.
        let titleRect = titleField.alignmentRect(forFrame: titleField.frame)
        return .object(["type": .string(typeName), "title": .string(latestTitle), "height": .number(header.bounds.height),
                 "headerWidth": .number(header.bounds.width), "titleCenterX": .number(titleRect.midX),
                 "titleLeadingX": .number(titleRect.minX), "titleTrailingX": .number(titleRect.maxX),
                 "typeTrailingX": .number(typeButton.frame.maxX), "copyIDLeadingX": .number(copyIDButton.frame.minX),
                 "titleCentered": .bool(titleField.alignment == .center),
                 "editing": .bool(titleField.currentEditor() != nil), "draft": .string(titleField.currentEditor()?.string ?? titleField.stringValue),
                 "copyIDVisible": .bool(copyIDButton.frame.minX >= 0 && copyIDButton.frame.maxX <= closeButton.frame.minX && !copyIDButton.isHidden),
                 "copyIDTooltip": .string(copyIDButton.toolTip ?? ""),
                 "dragHandleVisible": .bool(dragHandle.frame.minX >= 0 && dragHandle.frame.maxX <= typeButton.frame.minX && !dragHandle.isHidden),
                 "closeVisible": .bool(closeButton.frame.minX >= 0 && closeButton.frame.maxX <= header.bounds.width && !closeButton.isHidden), "attached": .bool(header.window != nil)])
    }
}

@MainActor
private final class PaneHeaderButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

@MainActor
private final class PaneTitleField: NSTextField {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if currentEditor() == nil {
            onClick?()
            selectText(nil)
        } else { super.mouseDown(with: event) }
    }
}

@MainActor
private final class PaneHeaderView: NSView {
    var onFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onFocus?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1 / (window?.backingScaleFactor ?? 1)).fill()
    }
}
