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
final class PaneContainer: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
    private(set) var content: NSViewController
    private var contentConstraints: [NSLayoutConstraint] = []
    private let welcomeView: WelcomeView?
    private var welcomeHeight: NSLayoutConstraint?
    private var welcomeEnabled: Bool
    var welcomeVisible: Bool { welcomeEnabled && (welcomeHeight?.constant ?? 0) > 0 }
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
    private lazy var headerHeight = header.heightAnchor.constraint(equalToConstant: 28)
    private(set) var headerVisible = true
    private var latestTitle = ""
    private var hasUnreadNotification = false
    private var renameTitle = ""
    private var renamePopover: NSPopover?
    private let renameField = LiteralTextField(string: "")
    private var editingOriginal: String?
    private let inactiveShade = PaneInactiveShade()
    private var isActive = true
    var onClose: (() -> Void)?
    var onFocus: (() -> Void)?
    var onInsertWelcomeCommand: (() -> Void)? {
        didSet {
            welcomeView?.onInsertCommand = onInsertWelcomeCommand == nil ? nil : { [weak self] in
                guard let self, self.welcomeVisible else { return }
                self.onInsertWelcomeCommand?()
            }
        }
    }
    var onRename: ((String) -> Void)?
    var typeChoices: (() -> [(name: String, id: String)])?
    var onChangeType: ((String) -> Void)?

    init(content: NSViewController, type: String, typeID: String, showWelcome: Bool = false) {
        welcomeEnabled = showWelcome && typeID == "terminal"
        welcomeView = showWelcome && typeID == "terminal" ? WelcomeView() : nil
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
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.setAccessibilityRole(.button)
        titleField.setAccessibilityLabel("Rename Pane")
        titleField.onClick = { [weak self] in self?.showRenamePopover() }
        typeButton.setContentHuggingPriority(.required, for: .horizontal)
        // Preserve the header's internal ordering, but keep optional text below the
        // split item's 251 holding priority. Otherwise fitting-size pressure silently
        // overrides model fractions (the type label alone imposed a 193-point minimum).
        typeButton.setContentCompressionResistancePriority(.init(rawValue: 249), for: .horizontal)
        titleField.setContentHuggingPriority(.init(rawValue: 246), for: .horizontal)
        titleField.setContentCompressionResistancePriority(.init(rawValue: 247), for: .horizontal)
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
        if let welcomeView {
            welcomeView.onFocus = { [weak self] in self?.onFocus?() }
            welcomeView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(welcomeView)
            let height = welcomeView.heightAnchor.constraint(equalToConstant: 0)
            welcomeHeight = height
            NSLayoutConstraint.activate([
                welcomeView.topAnchor.constraint(equalTo: header.bottomAnchor),
                welcomeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                welcomeView.trailingAnchor.constraint(equalTo: view.trailingAnchor), height
            ])
        }
        inactiveShade.translatesAutoresizingMaskIntoConstraints = false
        inactiveShade.isHidden = true
        view.addSubview(inactiveShade)
        NSLayoutConstraint.activate([
            inactiveShade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inactiveShade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inactiveShade.topAnchor.constraint(equalTo: view.topAnchor),
            inactiveShade.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // Fill the largest symmetric title region without compressing the type control.
        let preferredTitleWidth = titleField.widthAnchor.constraint(equalTo: header.widthAnchor)
        preferredTitleWidth.priority = .init(248)
        let titleLeadingLimit = titleField.leadingAnchor.constraint(greaterThanOrEqualTo: typeButton.trailingAnchor, constant: 8)
        let titleTrailingLimit = titleField.trailingAnchor.constraint(lessThanOrEqualTo: actionStrip.leadingAnchor, constant: -6)
        // At the split's 80-point minimum there may be no title space at all.
        // Collapse the title rather than breaking its center or required control constraints.
        titleLeadingLimit.priority = .init(250)
        titleTrailingLimit.priority = .init(250)
        NSLayoutConstraint.activate([
            preferredTitleWidth, titleLeadingLimit, titleTrailingLimit,
            header.topAnchor.constraint(equalTo: view.topAnchor), header.leadingAnchor.constraint(equalTo: view.leadingAnchor), header.trailingAnchor.constraint(equalTo: view.trailingAnchor), headerHeight,
            dragHandle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 3), dragHandle.centerYAnchor.constraint(equalTo: header.centerYAnchor), dragHandle.widthAnchor.constraint(equalToConstant: 20), dragHandle.heightAnchor.constraint(equalToConstant: 22),
            typeButton.leadingAnchor.constraint(equalTo: dragHandle.trailingAnchor, constant: 3), typeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor), typeButton.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor, multiplier: 0.35),
            titleField.centerXAnchor.constraint(equalTo: header.centerXAnchor), titleField.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            actionStrip.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2), actionStrip.centerYAnchor.constraint(equalTo: header.centerYAnchor), actionStrip.heightAnchor.constraint(equalToConstant: 22),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -5), closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor), closeButton.widthAnchor.constraint(equalToConstant: 22), closeButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        constrainContent()
    }

    private func constrainContent() {
        contentConstraints = [content.view.topAnchor.constraint(equalTo: welcomeView?.bottomAnchor ?? header.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)]
        NSLayoutConstraint.activate(contentConstraints)
    }

    /// A tab-scoped plugin changes logical instances on transfer; chrome/drag identity stays live.
    func replaceContent(with controller: NSViewController) {
        _ = view
        renamePopover?.close()
        NSLayoutConstraint.deactivate(contentConstraints)
        content.view.removeFromSuperview()
        content.removeFromParent()
        content = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view, positioned: .below, relativeTo: inactiveShade)
        constrainContent()
    }

    func clickWelcomeInsertForTesting() throws {
        guard welcomeVisible, let welcomeView else {
            throw RPCFailure(code: -32051, message: "Welcome message is not presented")
        }
        welcomeView.clickInsertCommandForTesting()
    }

    func dismissWelcome() {
        guard welcomeEnabled else { return }
        welcomeEnabled = false
        welcomeView?.onInsertCommand = nil
        _ = view
        welcomeHeight?.constant = 0
        welcomeView?.isHidden = true
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    func setHeaderVisible(_ visible: Bool) {
        _ = view
        guard headerVisible != visible else { return }
        // Closing an anchored editor cancels its draft; visibility is not a rename.
        if !visible { renamePopover?.close() }
        headerVisible = visible
        header.isHidden = !visible
        headerHeight.constant = visible ? 28 : 0
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    func setTitle(_ title: String) {
        _ = view
        renameTitle = title
        latestTitle = String(title.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(512))
        // The header stays live; the separate rename draft is never overwritten.
        titleField.stringValue = (hasUnreadNotification ? "● " : "") + latestTitle
        titleField.toolTip = (hasUnreadNotification ? "Unread notification · " : "") + latestTitle
        header.setAccessibilityLabel("\(typeName): \(latestTitle)")
        closeButton.setAccessibilityLabel("Close \(typeName) Pane: \(latestTitle)")
        dragHandle.setAccessibilityLabel("Move \(typeName) Pane: \(latestTitle)")
    }

    func setUnreadNotification(_ unread: Bool) {
        guard hasUnreadNotification != unread else { return }
        hasUnreadNotification = unread
        setTitle(renameTitle)
        titleField.setAccessibilityLabel(unread ? "Unread notification. Rename Pane" : "Rename Pane")
    }

    override func viewWillDisappear() {
        renamePopover?.close()
        super.viewWillDisappear()
    }

    func setActive(_ active: Bool) {
        _ = view
        isActive = active
        inactiveShade.isHidden = active
        if !active { renamePopover?.close() }
    }

    func showRenamePopover() {
        guard headerVisible, view.window != nil else { return }
        if renamePopover?.isShown == true { renameField.selectText(nil); return }
        onFocus?()
        editingOriginal = renameTitle
        renameField.stringValue = renameTitle
        renameField.placeholderString = "Pane name"
        renameField.setAccessibilityLabel("Pane name")
        renameField.delegate = self
        let heading = NSTextField(labelWithString: "Rename Pane")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let hint = NSTextField(labelWithString: "Leave empty to use the automatic title.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRename))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Rename", target: self, action: #selector(commitRename))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.spacing = 8
        let stack = NSStackView(views: [heading, renameField, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 320),
            renameField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: renameField.widthAnchor),
        ])
        let controller = NSViewController()
        controller.view = stack
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = controller
        renamePopover = popover
        popover.show(relativeTo: titleField.bounds, of: titleField, preferredEdge: .minY)
        renameField.selectText(nil)
    }

    @objc private func commitRename() {
        let title = renameField.stringValue
        let original = editingOriginal
        renamePopover?.close()
        // Closing a popover is not itself a mutation. Reuse the host's guarded
        // title operation, including normalization, persistence and events.
        if title != original { onRename?(title) }
        onFocus?()
    }

    @objc private func cancelRename() {
        renamePopover?.close()
        onFocus?()
    }

    func popoverDidClose(_ notification: Notification) {
        editingOriginal = nil
        renamePopover = nil
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)): cancelRename()
        case #selector(NSResponder.insertNewline(_:)): commitRename()
        default: return false
        }
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

    @objc func showMoveMenu() {
        guard let menu = moveMenu?() else { return }
        presentMoveMenu(menu)
    }
    func presentMoveMenu(_ menu: NSMenu) {
        // Keep the responder intact: dismissing the menu must not disable terminal input.
        guard headerVisible else { return }
        menu.popUp(positioning: nil, at: .zero, in: dragHandle)
    }
    @objc private func showTypeMenu() { presentTypeMenu(makeTypeMenu()) }
    func presentTypeMenu(_ menu: NSMenu) {
        guard headerVisible else { return }
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
        if let welcomeView, let welcomeHeight {
            let available = max(0, view.bounds.height - headerHeight.constant)
            // Never impose a pane minimum. Give the live terminal at least 80pt where
            // available and at least half of larger panes; longer copy can scroll.
            let height = welcomeEnabled ? min(welcomeView.preferredHeight(for: view.bounds.width), available / 2, max(0, available - 80)) : 0
            if abs(welcomeHeight.constant - height) > 0.5 { welcomeHeight.constant = height }
            welcomeView.isHidden = height == 0
        }
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
        guard headerVisible, let action = headerActions.first(where: { $0.id == id && $0.revision == revision }), action.enabled else { return }
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
        if renamePopover?.isShown != true {
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            titleField.mouseDown(with: event)
        }
        guard let editor = renameField.currentEditor() as? NSTextView else { throw RPCFailure(code: -32000, message: "Pane title editor did not open") }
        if let text { editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count)) }
        switch finish {
        case "commit": editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        case "cancel": editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        case "blur": renamePopover?.close()
        case "outsideClick":
            guard let window = view.window else { return }
            let point = content.view.convert(NSPoint(x: content.view.bounds.midX, y: content.view.bounds.midY), to: nil)
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { return }
            NSApp.postEvent(up, atStart: true)
            NSApp.postEvent(down, atStart: true)
        default: break
        }
    }

    var effectiveTitle: String { latestTitle }

    var info: JSONValue {
        view.layoutSubtreeIfNeeded()
        // Constraints use alignment rects; NSTextField's frame has two-point side outsets.
        let titleRect = titleField.alignmentRect(forFrame: titleField.frame)
        return .object(["type": .string(typeName), "title": .string(latestTitle), "height": .number(header.bounds.height),
                 "headerVisible": .bool(headerVisible), "unreadNotification": .bool(hasUnreadNotification), "contentHeight": .number(content.view.bounds.height),
                 "headerWidth": .number(header.bounds.width), "titleCenterX": .number(titleRect.midX),
                 "titleLeadingX": .number(titleRect.minX), "titleTrailingX": .number(titleRect.maxX),
                 "typeTrailingX": .number(typeButton.frame.maxX), "actionsLeadingX": .number(actionStrip.frame.minX),
                 "titleCentered": .bool(titleField.alignment == .center),
                 "editing": .bool(renamePopover?.isShown == true), "draft": .string(renameField.currentEditor()?.string ?? renameField.stringValue),
                 "active": .bool(isActive), "dimmed": .bool(!inactiveShade.isHidden),
                 "renameWindowNumber": renameField.window.map { .integer($0.windowNumber) } ?? .null,
                 "headerActions": .array(headerActions.map { .object(["id": .string($0.id), "enabled": .bool($0.enabled)]) }),
                 "visibleHeaderActions": .array(headerVisible ? actionStrip.arrangedSubviews.compactMap { $0.identifier?.rawValue }.map(JSONValue.string) : []),
                 "actionsBeforeClose": .bool(actionStrip.frame.maxX <= closeButton.frame.minX),
                 "dragHandleVisible": .bool(dragHandle.frame.minX >= 0 && dragHandle.frame.maxX <= typeButton.frame.minX && !dragHandle.isHiddenOrHasHiddenAncestor),
                 "closeVisible": .bool(closeButton.frame.minX >= 0 && closeButton.frame.maxX <= header.bounds.width && !closeButton.isHiddenOrHasHiddenAncestor), "attached": .bool(header.window != nil)])
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
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Paint over retained Metal/WebKit content without intercepting clicks or drags.
@MainActor
private final class PaneInactiveShade: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.08).setFill()
        bounds.fill()
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
