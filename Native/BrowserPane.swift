import AppKit
import WebKit
import SlateTermCore
import SlateTermSettings

/// Browser content owns a fresh ephemeral store and never installs a plugin bridge.
@MainActor
final class BrowserPane: NSViewController, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    var browserConfiguration = AppConfiguration.defaults.browser
    let web: WKWebView
    lazy var automation = WebPaneAutomation(web: web)
    var onFocus: (() -> Void)?
    var onTitleChange: (() -> Void)?
    var paneTitle: String { web.title.flatMap { $0.isEmpty ? nil : $0 } ?? web.url?.host ?? "New Browser" }
    private let address = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let forward = NSButton(title: "Forward", target: nil, action: nil)
    private var observations: [NSKeyValueObservation] = []
    private var navigationOperation: UUID?
    private var currentNavigation: WKNavigation?
    private var trackedNavigations: [ObjectIdentifier: (navigation: WKNavigation, operation: UUID)] = [:]
    private var closed = false
    private var resumeAddressEditing = false

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

    var currentURL: String? { web.url?.absoluteString }

    /// The recipe boundary has already checked this URL; do not interpret it as a search.
    func loadStartingURL(_ url: String) {
        loadViewIfNeeded()
        web.load(URLRequest(url: URL(string: url)!))
    }

    func close() {
        guard !closed else { return }
        closed = true
        automation.close()
        trackedNavigations.removeAll(); currentNavigation = nil
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
    private func cancelPendingNavigation() {
        if let id = navigationOperation { automation.cancel(id, error: RPCFailure(code: -32022, message: "Navigation was superseded")) }
    }
    private func startNavigation(_ load: () -> WKNavigation?) {
        cancelPendingNavigation()
        if let navigation = load() { currentNavigation = navigation; automation.invalidate() }
    }
    @objc private func goBack() { startNavigation { web.goBack() } }
    @objc private func goForward() { startNavigation { web.goForward() } }
    @objc private func reloadPage() { startNavigation { web.reload() } }
    @objc private func openAddress() {
        do { let url = try browserConfiguration.addressURL(for: address.stringValue); startNavigation { web.load(URLRequest(url: url)) }; view.window?.makeFirstResponder(web) }
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
        if let url = navigationAction.request.url, Self.allowed(url) { startNavigation { web.load(navigationAction.request) } }
        return nil
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation else { return }
        currentNavigation = navigation
        let preserved = trackedNavigations[ObjectIdentifier(navigation)]?.operation
        if let id = navigationOperation, id != preserved {
            navigationOperation = nil // Do not stop the successor navigation.
            automation.cancel(id, error: RPCFailure(code: -32022, message: "Navigation was superseded"))
        }
        automation.invalidate(except: preserved)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let navigation else { return }
        currentNavigation = navigation
        automation.invalidate(except: trackedNavigations[ObjectIdentifier(navigation)]?.operation)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation else { return }
        let tracked = trackedNavigations.removeValue(forKey: ObjectIdentifier(navigation))
        guard navigation === currentNavigation else {
            if let tracked { automation.complete(tracked.operation, .failure(CancellationError())) }
            return
        }
        automation.documentFinished()
        if let id = tracked?.operation {
            guard navigationOperation == id else { automation.complete(id, .failure(CancellationError())); return }
            // Retain the submission slot through this metadata callback, even if
            // cancellation has already released its caller continuation.
            web.evaluateJavaScript("({url:location.href,title:document.title,loading:false})", in: nil, in: automation.world) { [weak self] result in
                guard let self else { return }
                do {
                    guard self.navigationOperation == id else { throw CancellationError() }
                    self.automation.complete(id, .success(try WebPaneAutomation.jsonValue(result.get())))
                } catch { self.automation.complete(id, .failure(error)) }
            }
        }
        updateControls()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(navigation, error: error)
        if navigation === currentNavigation { automation.invalidate() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        navigationFailed(navigation, error: error)
        if let navigation, navigation === currentNavigation, !web.isLoading {
            automation.documentFinished() // Only the failed current load can restore the prior document.
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        status.stringValue = "Browser process exited; reload to recover"
        navigationOperation = nil
        automation.processTerminated()
        trackedNavigations.removeAll(); currentNavigation = nil
    }
    private func navigationFailed(_ navigation: WKNavigation?, error: any Error) {
        guard let navigation else { return }
        if navigation === currentNavigation { status.stringValue = error.localizedDescription }
        if let tracked = trackedNavigations.removeValue(forKey: ObjectIdentifier(navigation)) {
            if navigationOperation == tracked.operation { navigationOperation = nil }
            automation.complete(tracked.operation, .failure(error))
        }
    }
    var info: JSONValue {
        var fields = automation.info
        fields.merge(["url": .string(web.url?.absoluteString ?? "about:blank"), "title": .string(web.title ?? ""), "loading": .bool(web.isLoading)]) { _, new in new }
        return .object(fields)
    }

    func navigate(_ value: String, beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        let url = try Self.url(value)
        guard !closed else { throw RPCFailure(code: -32022, message: "Browser pane is closed") }
        return try await automation.perform(timeoutMilliseconds: 15_000, beforeSubmission: beforeSubmission, onComplete: { [weak self] result in
            guard let self, self.navigationOperation != nil else { return }
            self.navigationOperation = nil
            if case .failure = result { self.web.stopLoading() }
        }) { id in
            self.cancelPendingNavigation()
            self.navigationOperation = id
            self.automation.invalidate(except: id)
            guard let navigation = self.web.load(URLRequest(url: url)) else {
                self.automation.complete(id, .failure(RPCFailure(code: APIError.unavailable, message: "Navigation could not start")))
                return
            }
            self.currentNavigation = navigation
            self.trackedNavigations[ObjectIdentifier(navigation)] = (navigation, id)
        }
    }

    func evaluate(_ source: String, isolated: Bool = false, timeoutMilliseconds: Int = 10_000,
                  beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        try await automation.evaluate(source, isolated: isolated, timeoutMilliseconds: timeoutMilliseconds, beforeSubmission: beforeSubmission)
    }

    func automate(_ action: BrowserAction, beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        try await automation.automate(action, beforeSubmission: beforeSubmission)
    }

    func screenshot(to path: String, beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        try await automation.screenshot(to: path, beforeSubmission: beforeSubmission)
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
