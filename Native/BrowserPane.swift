import AppKit
import WebKit
import SlateTermCore
import SlateTermSettings

/// Browser content owns a fresh ephemeral store and never installs a plugin bridge.
@MainActor
final class BrowserPane: NSViewController, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    var browserConfiguration = AppConfiguration.defaults.browser
    let web: WKWebView
    // Named worlds are only reused while their WKContentWorld is retained.
    private let automationWorld = WKContentWorld.world(name: "SlateAutomation")
    var onFocus: (() -> Void)?
    var onTitleChange: (() -> Void)?
    var paneTitle: String { web.title.flatMap { $0.isEmpty ? nil : $0 } ?? web.url?.host ?? "New Browser" }
    private let address = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let forward = NSButton(title: "Forward", target: nil, action: nil)
    private var observations: [NSKeyValueObservation] = []
    private var navigationOperation: UUID?
    private var pendingNavigation: WKNavigation?
    private var closed = false
    private var documentGeneration = UUID()
    private var resumeAddressEditing = false
    private struct Operation {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let deadline: Task<Void, Never>
    }
    private var operations: [UUID: Operation] = [:]

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
        web.navigationDelegate = self
        web.uiDelegate = self
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = PaneFocusView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        container.autoresizingMask = [.width, .height]
        container.onFocus = { [weak self] in self?.onFocus?() }
        view = container
        back.target = self; back.action = #selector(goBack)
        forward.target = self; forward.action = #selector(goForward)
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadPage))
        for (button, symbol, label) in [(back, "chevron.backward", "Back"), (forward, "chevron.forward", "Forward"), (reload, "arrow.clockwise", "Reload")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.placeholderString = "Search or enter a URL"
        address.target = self; address.action = #selector(openAddress)
        address.delegate = self
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.setAccessibilityLabel("Browser address")
        let toolbar = NSStackView(views: [back, forward, address, reload])
        toolbar.spacing = 6
        toolbar.distribution = .fill
        toolbar.setHuggingPriority(.fittingSizeCompression, for: .horizontal)
        toolbar.setVisibilityPriority(.detachOnlyIfNecessary, for: back)
        toolbar.setVisibilityPriority(.detachOnlyIfNecessary, for: forward)
        let readableAddress = address.widthAnchor.constraint(greaterThanOrEqualToConstant: 100)
        readableAddress.priority = .defaultHigh
        readableAddress.isActive = true
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        for child in [toolbar, web, status] { child.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(child) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor), toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: toolbar.bottomAnchor), web.leadingAnchor.constraint(equalTo: container.leadingAnchor), web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            status.topAnchor.constraint(equalTo: web.bottomAnchor, constant: 3), status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8), status.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8), status.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        observations = [web.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.onTitleChange?() } },
                        web.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateControls() } },
                        web.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateControls() } }]
        updateControls()
        web.loadHTMLString("<!doctype html><meta name='color-scheme' content='light dark'><title>New Browser</title><style>body{font:16px system-ui;padding:48px;max-width:600px;margin:auto}h1{font-size:26px}</style><h1>New Browser</h1><p>Search or enter a URL in the address bar to browse.</p>", baseURL: nil)
    }

    func close() {
        guard !closed else { return }
        closed = true
        for id in Array(operations.keys) { complete(id, .failure(RPCFailure(code: -32022, message: "Browser pane was closed"))) }
        finishNavigation(.failure(RPCFailure(code: -32022, message: "Browser pane was closed")))
        observations.removeAll()
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        onFocus = nil
        onTitleChange = nil
    }

    func rememberFocus() {
        guard let responder = view.window?.firstResponder else { return }
        if responder === address.currentEditor() { resumeAddressEditing = true }
        else if let responder = responder as? NSView, responder.isDescendant(of: web) { resumeAddressEditing = false }
    }

    func focus() {
        guard let window = view.window else { return }
        if let responder = window.firstResponder as? NSView, responder !== view,
           responder === address.currentEditor() || responder.isDescendant(of: view) { return }
        window.makeFirstResponder(resumeAddressEditing ? address : web)
    }

    func performCommand(_ command: String) throws {
        switch command {
        case "browser.back": goBack()
        case "browser.forward": goForward()
        case "browser.focusAddress": focusAddress()
        case "browser.reload": reloadPage()
        default: throw RPCFailure(code: -32601, message: "Unknown browser command: \(command)")
        }
    }

    func focusAddress() { resumeAddressEditing = true; address.selectText(nil) }
    var focusInfo: JSONValue {
        let responder = view.window?.firstResponder as? NSView
        return .object(["addressFocused": .bool(responder != nil && responder === address.currentEditor()),
                        "webFocused": .bool(responder?.isDescendant(of: web) ?? false), "address": .string(address.stringValue)])
    }

    func controlTextDidBeginEditing(_ obj: Notification) { resumeAddressEditing = true; onFocus?() }
    private func cancelPendingNavigation() { finishNavigation(.failure(RPCFailure(code: -32022, message: "Navigation was superseded"))) }
    @objc private func goBack() { cancelPendingNavigation(); web.goBack() }
    @objc private func goForward() { cancelPendingNavigation(); web.goForward() }
    @objc private func reloadPage() { cancelPendingNavigation(); web.reload() }
    @objc private func openAddress() {
        do { let url = try browserConfiguration.addressURL(for: address.stringValue); cancelPendingNavigation(); web.load(URLRequest(url: url)); view.window?.makeFirstResponder(web) }
        catch { status.stringValue = String(describing: error) }
    }
    private func updateControls() {
        if let url = web.url, url.absoluteString != "about:blank" { address.stringValue = url.absoluteString }
        back.isEnabled = web.canGoBack
        forward.isEnabled = web.canGoForward
        status.stringValue = web.isLoading ? "Loading…" : (web.url?.host ?? "")
    }
    static func url(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = value.contains("://") || value.hasPrefix("about:") ? value : "https://" + value
        guard let url = URL(string: normalized), allowed(url) else { throw RPCFailure(code: -32602, message: "Use an HTTP or HTTPS URL") }
        return url
    }
    private static func allowed(_ url: URL) -> Bool {
        url.absoluteString == "about:blank" || (["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, Self.allowed(url) else {
            decisionHandler(.cancel)
            status.stringValue = "Navigation scheme is not allowed"
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, Self.allowed(url) { web.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        documentGeneration = UUID()
        for id in Array(operations.keys) where id != navigationOperation {
            complete(id, .failure(RPCFailure(code: -32022, message: "Browser document changed during the operation")))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if navigation === pendingNavigation, let id = navigationOperation {
            // Native title KVO can lag didFinish. Complete the tracked navigation
            // with document metadata, without observing a successor's document.
            web.evaluateJavaScript("({url:location.href,title:document.title,loading:false})", in: nil, in: automationWorld) { [weak self] result in
                guard let self, self.navigationOperation == id else { return }
                do { self.complete(id, .success(try Self.jsonValue(result.get()))) }
                catch { self.complete(id, .failure(error)) }
            }
        }
        updateControls()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if navigation === pendingNavigation { failed(error) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if navigation === pendingNavigation { failed(error) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        documentGeneration = UUID()
        let error = RPCFailure(code: -32023, message: "Browser process exited; reload to recover")
        failed(error)
        for id in Array(operations.keys) { complete(id, .failure(error)) }
    }
    private func failed(_ error: any Error) {
        status.stringValue = error.localizedDescription
        if let id = navigationOperation { complete(id, .failure(error), stopNavigation: false) }
    }
    private func finishNavigation(_ result: Result<JSONValue, any Error>) {
        if let id = navigationOperation { complete(id, result) }
    }
    var info: JSONValue { .object(["url": .string(web.url?.absoluteString ?? "about:blank"), "title": .string(web.title ?? ""), "loading": .bool(web.isLoading), "pendingOperations": .integer(operations.count)]) }

    func navigate(_ value: String, beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        let url = try Self.url(value)
        guard !closed else { throw RPCFailure(code: -32022, message: "Browser pane is closed") }
        cancelPendingNavigation()
        return try await perform(timeoutMilliseconds: 15_000, beforeSubmission: beforeSubmission) { id in
            self.navigationOperation = id
            self.pendingNavigation = self.web.load(URLRequest(url: url))
        }
    }

    func evaluate(_ source: String, isolated: Bool = false, timeoutMilliseconds: Int = 10_000,
                  beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        guard !closed else { throw RPCFailure(code: -32022, message: "Browser pane is closed") }
        return try await perform(timeoutMilliseconds: timeoutMilliseconds, beforeSubmission: beforeSubmission) { id in
            self.web.evaluateJavaScript(source, in: nil, in: isolated ? self.automationWorld : .page) { [weak self] result in
                guard let self, self.operations[id] != nil else { return }
                do {
                    self.complete(id, .success(try Self.jsonValue(result.get())))
                } catch { self.complete(id, .failure(error)) }
            }
        }
    }

    func automate(_ action: BrowserAction, beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        let generation = documentGeneration
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(action.timeoutMilliseconds == 0 ? 10_000 : action.timeoutMilliseconds))
        func remainingMilliseconds() throws -> Int {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw RPCFailure(code: -32024, message: "Browser condition timed out") }
            return max(1, Int(remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000))
        }
        // Bind selectors to the actual document before any mutation. The private
        // world rejects a queued action if navigation replaced that document.
        let prepared = try await evaluate(BrowserAutomation.prepareScript(), isolated: true, timeoutMilliseconds: remainingMilliseconds(), beforeSubmission: beforeSubmission)
        guard let documentID = prepared.object?["documentId"]?.string else { throw RPCFailure(code: -32023, message: "Browser document identity unavailable") }
        let source = try BrowserAutomation.script(for: action, documentID: documentID)
        while true {
            try Task.checkCancellation()
            guard !closed, documentGeneration == generation else { throw RPCFailure(code: -32022, message: "Browser document was replaced") }
            let result = try await evaluate(source, isolated: true, timeoutMilliseconds: remainingMilliseconds(), beforeSubmission: beforeSubmission)
            if action.kind != .wait || result.object?["matched"] == .bool(true) { return result }
            guard action.timeoutMilliseconds > 0 else { throw RPCFailure(code: -32024, message: "Browser condition did not match") }
            try await Task.sleep(for: .milliseconds(min(50, remainingMilliseconds())))
        }
    }

    private static func jsonValue(_ value: Any?) throws -> JSONValue {
        let data = try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed])
        guard data.count <= 900_000 else { throw RPCFailure(code: -32025, message: "Browser result exceeds 900000 bytes") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func perform(timeoutMilliseconds: Int = 10_000, beforeSubmission: @MainActor () throws -> Void = {}, _ start: (UUID) -> Void) async throws -> JSONValue {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !closed, !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                do { try beforeSubmission() } catch { continuation.resume(throwing: error); return }
                guard operations.count < 32 else { continuation.resume(throwing: RPCFailure(code: -32025, message: "Too many pending browser operations")); return }
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(timeoutMilliseconds)) } catch { return }
                    self?.complete(id, .failure(RPCFailure(code: -32024, message: "Browser operation timed out")))
                }
                operations[id] = Operation(continuation: continuation, deadline: deadline)
                start(id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.complete(id, .failure(CancellationError())) }
        }
    }
    private func complete(_ id: UUID, _ result: Result<JSONValue, any Error>, stopNavigation: Bool = true) {
        guard let operation = operations.removeValue(forKey: id) else { return }
        if navigationOperation == id {
            navigationOperation = nil
            pendingNavigation = nil
            if stopNavigation, case .failure = result { web.stopLoading() }
        }
        operation.deadline.cancel()
        operation.continuation.resume(with: result)
    }

    func screenshot(to path: String, beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        try await perform(beforeSubmission: beforeSubmission) { id in
            self.web.takeSnapshot(with: nil) { [weak self] image, error in
                guard let self, self.operations[id] != nil else { return }
                do {
                    if let error { throw error }
                    guard let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { throw RPCFailure(code: -32023, message: "Snapshot unavailable") }
                    try beforeSubmission()
                    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                    self.complete(id, .success(.object(["path": .string(path)])))
                } catch { self.complete(id, .failure(error)) }
            }
        }
    }
}

@MainActor
final class PaneFocusView: NSView {
    var onFocus: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { onFocus?(); return true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit != nil, NSApp.currentEvent?.type == .leftMouseDown { onFocus?() }
        return hit
    }
}
