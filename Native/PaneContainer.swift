import AppKit
import SlateTermCore

struct PaneHeaderAction {
    let id: String
    let title: String
    let symbol: String
    let enabled: Bool
    let revision: UUID
    let perform: () -> Void

    func hasSamePresentation(as other: Self) -> Bool {
        id == other.id && title == other.title && symbol == other.symbol && enabled == other.enabled && revision == other.revision
    }
}

/// Stable chrome around retained content; split reparenting never recreates a surface.
@MainActor
final class PaneContainer: NSViewController, NSTextFieldDelegate {
    let content: NSViewController
    private let typeName: String
    private let typeID: String
    private let actionStrip = NSStackView()
    private var headerActions: [PaneHeaderAction] = []
    private var actionCapacity = -1
    private struct ActionToken { let id: String; let revision: UUID }
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

    init(content: NSViewController, type: String, typeID: String) {
        self.content = content
        self.typeName = type
        self.typeID = typeID
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
        actionStrip.orientation = .horizontal
        actionStrip.spacing = 2
        actionStrip.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryPushIn)
        closeButton.target = self
        closeButton.action = #selector(closePane)
        closeButton.setAccessibilityLabel("Close \(typeName) Pane")
        closeButton.toolTip = "Close Pane"
        for child in [dragHandle, typeButton, titleField, actionStrip, closeButton] { child.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(child) }
        for child in [header, content.view] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        // Fill the largest symmetric title region without compressing the type control.
        let preferredTitleWidth = titleField.widthAnchor.constraint(equalTo: header.widthAnchor)
        preferredTitleWidth.priority = .init(500)
        let titleLeadingLimit = titleField.leadingAnchor.constraint(greaterThanOrEqualTo: typeButton.trailingAnchor, constant: 8)
        let titleTrailingLimit = titleField.trailingAnchor.constraint(lessThanOrEqualTo: actionStrip.leadingAnchor, constant: -6)
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
            actionStrip.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2), actionStrip.centerYAnchor.constraint(equalTo: header.centerYAnchor), actionStrip.heightAnchor.constraint(equalToConstant: 22),
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
    @objc private func closePane() { onClose?() }
    func performClose() { closeButton.performClick(nil) }

    func setHeaderActions(_ actions: [PaneHeaderAction]) {
        _ = view
        let unchanged = headerActions.count == actions.count && zip(headerActions, actions).allSatisfy { $0.0.hasSamePresentation(as: $0.1) }
        headerActions = actions
        if !unchanged { rebuildHeaderActions() }
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let capacity = header.bounds.width >= 500 ? 3 : header.bounds.width >= 320 ? 1 : header.bounds.width >= 180 ? 0 : -1
        if capacity != actionCapacity { actionCapacity = capacity; rebuildHeaderActions() }
    }
    private func rebuildHeaderActions() {
        for child in actionStrip.arrangedSubviews { actionStrip.removeArrangedSubview(child); child.removeFromSuperview() }
        guard actionCapacity >= 0 else { return }
        func button(_ title: String, symbol: String, id: String, action: Selector, enabled: Bool = true, revision: UUID? = nil) -> NSButton {
            let button = PaneHeaderButton()
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            button.symbolConfiguration = .init(pointSize: 10, weight: .medium)
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.pluginRevision = revision
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.target = self
            button.action = action
            button.isEnabled = enabled
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            return button
        }
        for action in headerActions.prefix(actionCapacity) {
            actionStrip.addArrangedSubview(button(action.title, symbol: action.symbol, id: action.id, action: #selector(performHeaderAction(_:)), enabled: action.enabled, revision: action.revision))
        }
        if headerActions.count > actionCapacity {
            actionStrip.addArrangedSubview(button("More Plugin Actions", symbol: "ellipsis", id: "overflow", action: #selector(showHeaderActions(_:))))
        }
    }
    @objc private func performHeaderAction(_ sender: NSButton) {
        guard let revision = (sender as? PaneHeaderButton)?.pluginRevision else { return }
        performHeaderAction(id: sender.identifier?.rawValue, revision: revision)
    }
    @objc private func performHeaderMenuAction(_ sender: NSMenuItem) {
        // A native menu can keep tracking across a registration replacement.
        // Never turn an old visible menu item into a newly registered action.
        guard let token = sender.representedObject as? ActionToken else { return }
        performHeaderAction(id: token.id, revision: token.revision)
    }
    private func performHeaderAction(id: String?, revision: UUID) {
        guard let action = headerActions.first(where: { $0.id == id && $0.revision == revision }), action.enabled else { return }
        action.perform()
    }
    func headerActionMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in headerActions.dropFirst(max(0, actionCapacity)) {
            let item = menu.addItem(withTitle: action.title, action: #selector(performHeaderMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ActionToken(id: action.id, revision: action.revision)
            item.isEnabled = action.enabled
            item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil) ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
        }
        return menu
    }
    @objc private func showHeaderActions(_ sender: NSButton) { headerActionMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender) }

    func clickHeaderActionForTesting(_ id: String) throws {
        view.layoutSubtreeIfNeeded()
        if let button = actionStrip.arrangedSubviews.first(where: { $0.identifier?.rawValue == id }) as? NSButton { button.performClick(nil); return }
        if actionStrip.arrangedSubviews.contains(where: { $0.identifier?.rawValue == "overflow" }) {
            let menu = headerActionMenu()
            if let index = menu.items.firstIndex(where: { ($0.representedObject as? ActionToken)?.id == id }) { menu.performActionForItem(at: index); return }
        }
        throw RPCFailure(code: -32602, message: "Header action is not visible")
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

    var effectiveTitle: String { latestTitle }

    var info: JSONValue {
        view.layoutSubtreeIfNeeded()
        // Constraints use alignment rects; NSTextField's frame has two-point side outsets.
        let titleRect = titleField.alignmentRect(forFrame: titleField.frame)
        return .object(["type": .string(typeName), "title": .string(latestTitle), "height": .number(header.bounds.height),
                 "headerWidth": .number(header.bounds.width), "titleCenterX": .number(titleRect.midX),
                 "titleLeadingX": .number(titleRect.minX), "titleTrailingX": .number(titleRect.maxX),
                 "typeTrailingX": .number(typeButton.frame.maxX), "actionsLeadingX": .number(actionStrip.frame.minX),
                 "titleCentered": .bool(titleField.alignment == .center),
                 "editing": .bool(titleField.currentEditor() != nil), "draft": .string(titleField.currentEditor()?.string ?? titleField.stringValue),
                 "headerActions": .array(headerActions.map { .object(["id": .string($0.id), "enabled": .bool($0.enabled)]) }),
                 "visibleHeaderActions": .array(actionStrip.arrangedSubviews.compactMap { $0.identifier?.rawValue }.map(JSONValue.string)),
                 "actionsBeforeClose": .bool(actionStrip.frame.maxX <= closeButton.frame.minX),
                 "dragHandleVisible": .bool(dragHandle.frame.minX >= 0 && dragHandle.frame.maxX <= typeButton.frame.minX && !dragHandle.isHidden),
                 "closeVisible": .bool(closeButton.frame.minX >= 0 && closeButton.frame.maxX <= header.bounds.width && !closeButton.isHidden), "attached": .bool(header.window != nil)])
    }
}

@MainActor
private final class PaneHeaderButton: NSButton {
    var pluginRevision: UUID?
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
