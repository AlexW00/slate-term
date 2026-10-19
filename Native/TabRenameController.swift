import AppKit
import SlateTermCore

/// The draft is presentation state. Only explicit confirmation invokes the host mutation.
@MainActor
final class TabRenameController: NSObject, NSTextFieldDelegate {
    let tab: TabID
    weak var owner: NSWindow?
    let originalTitle: String?
    private let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 210),
                                styleMask: [.titled], backing: .buffered, defer: false)
    private let field = LiteralTextField(string: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var finished = false
    private var restoreFocus = true
    private let commitTitle: (String) throws -> Void
    var onFinish: (() -> Void)?
    var isEditing: Bool { !finished && sheet.sheetParent != nil }
    var window: NSWindow { sheet }

    init(tab: TabID, window: NSWindow, originalTitle: String?, commit: @escaping (String) throws -> Void) {
        self.tab = tab
        owner = window
        self.originalTitle = originalTitle
        commitTitle = commit
        super.init()
    }

    static func unavailableReason(window: NSWindow?, editor: TabRenameController?) -> String? {
        guard let window, window.isVisible, !window.isMiniaturized,
              window.tabGroup == nil || window.tabGroup?.selectedWindow === window else {
            return "Rename requires a selected, visible tab"
        }
        guard NSApp.modalWindow == nil else { return "Finish the current dialog before renaming a tab" }
        if let attached = window.attachedSheet, attached !== editor?.sheet {
            return "Finish the current sheet before renaming this tab"
        }
        return nil
    }

    func show() {
        guard let owner else { return }
        sheet.isReleasedWhenClosed = false
        sheet.title = "Rename Tab"
        field.stringValue = originalTitle ?? ""
        field.placeholderString = TabTitle.defaultTitle
        field.setAccessibilityLabel("Tab name")
        field.delegate = self
        let heading = NSTextField(labelWithString: "Rename Tab")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        let hint = NSTextField(labelWithString: "Leave empty to use \(TabTitle.defaultTitle).")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Rename", target: self, action: #selector(confirm))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        buttons.spacing = 8
        let stack = NSStackView(views: [heading, field, hint, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 360),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            errorLabel.widthAnchor.constraint(equalTo: field.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: field.widthAnchor)
        ])
        let controller = NSViewController()
        controller.view = stack
        sheet.contentViewController = controller
        let previous = owner.firstResponder
        owner.beginSheet(sheet) { [self, weak owner, weak previous] _ in
            sheet.orderOut(nil)
            guard restoreFocus, let owner, NSApp.isActive, owner.isKeyWindow,
                  owner.tabGroup == nil || owner.tabGroup?.selectedWindow === owner else { return }
            if let view = previous as? NSView, view.window !== owner { return }
            owner.makeFirstResponder(previous)
        }
        selectDraft()
        observeLifetime(owner)
    }

    func selectDraft() { field.selectText(nil) }

    private func observeLifetime(_ window: NSWindow) {
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification] {
            let object: Any? = name == NSApplication.didResignActiveNotification ? NSApp : window
            notifications.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelForLifecycle() }
            })
        }
        if let group = window.tabGroup {
            observations.append(group.observe(\.windows) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.cancelForLifecycle() }
            })
            observations.append(group.observe(\.selectedWindow) { [weak self, weak window] group, _ in
                MainActor.assumeIsolated {
                    if group.selectedWindow !== window { self?.cancelForLifecycle() }
                }
            })
        }
    }

    @objc private func confirm() {
        guard !finished else { return }
        do {
            try commitTitle(field.stringValue)
            finish()
        } catch {
            errorLabel.stringValue = (error as? RPCFailure)?.message ?? String(describing: error)
            sheet.contentView?.layoutSubtreeIfNeeded()
        }
    }

    @objc private func cancel() { finish() }

    func cancelForLifecycle() {
        restoreFocus = false
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        observations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        owner?.endSheet(sheet)
        onFinish?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)): cancel()
        case #selector(NSResponder.insertNewline(_:)): confirm()
        default: return false
        }
        return true
    }

    func editForTesting(_ draft: String?, finish: String?) throws {
        if let draft {
            field.stringValue = draft
            field.currentEditor()?.string = draft
        }
        switch finish {
        case "commit": confirm()
        case "cancel": cancel()
        case nil: break
        default: throw RPCFailure(code: -32602, message: "Unknown editor completion")
        }
    }

    var info: JSONValue {
        .object(["editing": .bool(isEditing), "tabId": .string(tab.description),
                 "draft": .string(field.currentEditor()?.string ?? field.stringValue),
                 "error": .string(errorLabel.stringValue), "windowNumber": .integer(sheet.windowNumber)])
    }
}
