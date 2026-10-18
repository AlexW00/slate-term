import AppKit

/// Search chrome belongs to the retained terminal controller, so moving a pane
/// keeps its search and PTY. Programmatic searches never steal keyboard focus.
@MainActor
final class TerminalPaneController: NSViewController, NSSearchFieldDelegate {
    let terminal: TerminalView
    var onAvailabilityChanged: (() -> Void)?
    private let bar = NSView()
    private let field = TerminalFindField()
    private let count = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()
    private let done = NSButton()
    private var barHeight: NSLayoutConstraint!
    private var regular: [NSLayoutConstraint] = []
    private var compact: [NSLayoutConstraint] = []
    private var compactLayout = false
    private var resumeSearchEditing = false
    var findVisible: Bool { isViewLoaded && !bar.isHidden }
    var findFocused: Bool { field.currentEditor() != nil }

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(nibName: nil, bundle: nil)
        terminal.onFindChanged = { [weak self] focus in self?.refresh(focus: focus) }
        terminal.onInputFocus = { [weak self] in self?.resumeSearchEditing = false }
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: terminal.frame)
        field.placeholderString = "Find in Terminal"
        field.setAccessibilityLabel("Find in terminal history")
        field.delegate = self
        field.onFocus = { [weak self] in
            guard let self else { return }
            self.resumeSearchEditing = true
            self.terminal.onFocus?()
        }
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(queryChanged)
        field.font = .systemFont(ofSize: 12)
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, symbol, label, action) in [
            (previous, "chevron.up", "Previous Match", #selector(previousMatch)),
            (next, "chevron.down", "Next Match", #selector(nextMatch)),
            (done, "xmark", "Close Find", #selector(closeFind))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.setAccessibilityLabel(label)
            button.toolTip = label
            button.isBordered = false
            button.target = self
            button.action = action
        }
        for child in [bar, terminal] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        for child in [field, count, previous, next, done] { child.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(child) }
        barHeight = bar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor), bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor), barHeight,
            terminal.topAnchor.constraint(equalTo: bar.bottomAnchor), terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor), terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 6),
            next.leadingAnchor.constraint(equalTo: previous.trailingAnchor), done.leadingAnchor.constraint(equalTo: next.trailingAnchor),
            done.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -4),
        ])
        for button in [previous, next, done] {
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        regular = [field.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: count.leadingAnchor, constant: -4),
            count.widthAnchor.constraint(equalToConstant: 54), count.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            previous.leadingAnchor.constraint(equalTo: count.trailingAnchor, constant: 2)]
            + [previous, next, done].map { $0.centerYAnchor.constraint(equalTo: bar.centerYAnchor) }
        compact = [field.topAnchor.constraint(equalTo: bar.topAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -6)]
            + [previous, next, done].map { $0.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -2) }
        NSLayoutConstraint.activate(regular)
        refresh(focus: false)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let narrow = view.bounds.width < 300
        guard narrow != compactLayout else { return }
        compactLayout = narrow
        NSLayoutConstraint.deactivate(narrow ? regular : compact)
        NSLayoutConstraint.activate(narrow ? compact : regular)
        count.isHidden = narrow
        barHeight.constant = terminal.findState.active ? (narrow ? 56 : 32) : 0
    }

    private func refresh(focus: Bool) {
        guard isViewLoaded else { return }
        let state = terminal.findState
        let wasVisible = !bar.isHidden
        let editorHadFocus = field.currentEditor() != nil
        bar.isHidden = !state.active
        if !state.active { resumeSearchEditing = false }
        barHeight.constant = state.active ? (compactLayout ? 56 : 32) : 0
        if field.stringValue != state.query { field.stringValue = state.query }
        if state.query.isEmpty { count.stringValue = "" }
        else if let total = state.total {
            count.stringValue = state.selected.map { "\($0 + 1)/\(total)" } ?? "\(total)"
        } else { count.stringValue = "…" }
        count.setAccessibilityLabel(state.total.map { "\($0) matches" } ?? "Searching")
        previous.isEnabled = state.active && !state.query.isEmpty && state.total != 0
        next.isEnabled = previous.isEnabled
        view.layoutSubtreeIfNeeded()
        if wasVisible != state.active { onAvailabilityChanged?() }
        if focus && state.active {
            // start_search/search_selection asks the host to submit the needle.
            try? terminal.search(state.query)
            resumeSearchEditing = true
            terminal.onFocus?()
            focusSearchField()
        } else if wasVisible && !state.active && editorHadFocus {
            view.window?.makeFirstResponder(terminal)
        }
    }

    func focusSearchField() {
        guard terminal.findState.active else { return }
        view.window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    func rememberFocus() {
        guard let responder = view.window?.firstResponder else { return }
        if responder === field.currentEditor() { resumeSearchEditing = terminal.findState.active }
        else if responder === terminal { resumeSearchEditing = false }
    }

    func focus() {
        guard let window = view.window else { return }
        if let responder = window.firstResponder, responder === terminal || responder === field.currentEditor() { return }
        window.makeFirstResponder(resumeSearchEditing && terminal.findState.active ? field : terminal)
    }

    func controlTextDidBeginEditing(_ notification: Notification) { field.onFocus?() }

    @objc private func queryChanged() {
        do { try terminal.search(field.stringValue) }
        catch { NSSound.beep(); field.stringValue = terminal.findState.query }
    }
    @objc private func previousMatch() { terminal.onFocus?(); focus(); terminal.navigateSearch(previous: true) }
    @objc private func nextMatch() { terminal.onFocus?(); focus(); terminal.navigateSearch(previous: false) }
    @objc private func closeFind() {
        resumeSearchEditing = false
        terminal.onFocus?()
        terminal.endSearch()
        view.window?.makeFirstResponder(terminal)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { closeFind(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            terminal.navigateSearch(previous: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        }
        return false
    }
}

/// Editing-begin notifications alone omit a click/focus without text changes.
@MainActor
private final class TerminalFindField: LiteralSearchField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if currentEditor() != nil { onFocus?() }
    }
    override func selectText(_ sender: Any?) {
        super.selectText(sender)
        if currentEditor() != nil { onFocus?() }
    }
}
