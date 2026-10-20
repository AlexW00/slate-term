import AppKit
import WebKit
import SlateTermCore
import SlateTermSettings

/// Both browser modes remain ordinary web content and never install a plugin bridge.
@MainActor
final class BrowserPane: NSViewController, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    var browserConfiguration = AppConfiguration.defaults.browser
    let web: WKWebView
    let mode: PaneType
    private var newPageTitle: String { mode == .privateBrowser ? "New Private Browser" : "New Browser" }
    lazy var downloads = BrowserDownloads(window: { [weak self] in self?.web.window })
    lazy var automation = WebPaneAutomation(web: web)
    var onFocus: (() -> Void)?
    var onTitleChange: (() -> Void)?
    var paneTitle: String { web.title.flatMap { $0.isEmpty ? nil : $0 } ?? (web.url?.isFileURL == true ? web.url?.lastPathComponent : web.url?.host) ?? newPageTitle }
    private let address = LiteralTextField()
    private let status = NSTextField(labelWithString: "")
    private let back = NSButton(title: "Back", target: nil, action: nil)
    private let forward = NSButton(title: "Forward", target: nil, action: nil)
    private var observations: [NSKeyValueObservation] = []
    private var navigationOperation: UUID?
    private var currentNavigation: WKNavigation?
    private var downloadNavigation: WKNavigation?
    private var trackedNavigations: [ObjectIdentifier: (navigation: WKNavigation, operation: UUID)] = [:]
    // WebKit may omit terminal callbacks for loads replaced before they start.
    // Remember their identities without retaining every native/welcome load forever.
    private let submittedNavigations = NSHashTable<WKNavigation>.weakObjects()
    private var closed = false
    private var resumeAddressEditing = false
    private let popupID: String?
    private weak var popupOwner: BrowserPopups?
    private lazy var ownedPopups = BrowserPopups(root: self)
    private var popupRegistry: BrowserPopups { popupOwner ?? ownedPopups }

    convenience init(mode: PaneType, dataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // WebKit admits script-created windows only during a user gesture.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        self.init(mode: mode, configuration: configuration)
    }

    init(mode: PaneType, configuration: WKWebViewConfiguration,
         popupOwner: BrowserPopups? = nil, popupID: String? = nil) {
        precondition(mode.isBrowser && configuration.websiteDataStore.isPersistent == (mode == .browser))
        self.mode = mode
        self.popupOwner = popupOwner
        self.popupID = popupID
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
        let downloadButton = NSButton(image: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloads")!,
                                      target: self, action: #selector(showDownloads))
        downloadButton.toolTip = "Downloads"
        downloadButton.setAccessibilityLabel("Downloads")
        downloadButton.setContentHuggingPriority(.required, for: .horizontal)
        let toolbar = NSStackView(views: [back, forward, address, reload, downloadButton])
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
                        web.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated {
                            self?.updateControls()
                            if self?.web.isLoading == false { self?.rememberLocation() }
                        } },
                        web.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateControls() } }]
        updateControls()
        if popupID == nil {
            startNavigation {
                web.loadHTMLString("<!doctype html><meta name='color-scheme' content='light dark'><title>\(newPageTitle)</title><style>body{font:16px system-ui;padding:48px;max-width:600px;margin:auto}h1{font-size:26px}</style><h1>\(newPageTitle)</h1><p>Search or enter a URL in the address bar to browse.</p>", baseURL: nil)
            }
        }
    }

    var currentURL: String? { web.url?.absoluteString }
    private(set) var restorationURL: String?
    var onLocationChange: (() -> Void)?

    private func rememberLocation() {
        guard let url = currentURL, url != restorationURL else { return }
        restorationURL = url
        onLocationChange?()
    }

    /// The recipe boundary has already checked this URL; do not interpret it as a search.
    func loadStartingURL(_ url: String) {
        loadViewIfNeeded()
        do {
            let location = try Self.checkedLocation(BrowserURL.parse(url))
            restorationURL = location.absoluteString
            startNavigation { load(location) }
        }
        catch let error as RPCFailure { status.stringValue = error.message }
        catch { status.stringValue = String(describing: error) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let popupID { popupOwner?.closeDescendants(of: popupID) }
        else { ownedPopups.closeAll() }
        downloads.close()
        automation.close()
        trackedNavigations.removeAll(); submittedNavigations.removeAllObjects(); currentNavigation = nil
        observations.removeAll()
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        onFocus = nil
        onTitleChange = nil
        onLocationChange = nil
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
        case "browser.showDownloads": downloads.showDownloads()
        default: throw RPCFailure(code: -32601, message: "Unknown browser command: \(command)")
        }
    }

    @objc private func showDownloads() { downloads.showDownloads() }

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
        if let navigation = load() { trackNavigation(navigation); automation.invalidate() }
    }
    private func trackNavigation(_ navigation: WKNavigation) {
        currentNavigation = navigation
        downloadNavigation = nil
        submittedNavigations.add(navigation)
    }
    @objc private func goBack() { startNavigation { web.goBack() } }
    @objc private func goForward() { startNavigation { web.goForward() } }
    @objc private func reloadPage() { startNavigation { web.reload() } }
    @objc private func openAddress() {
        do { let url = try Self.checkedLocation(browserConfiguration.addressURL(for: address.stringValue)); startNavigation { load(url) }; view.window?.makeFirstResponder(web) }
        catch let error as RPCFailure { status.stringValue = error.message }
        catch { status.stringValue = String(describing: error) }
    }
    private func updateControls() {
        if let url = web.url { address.stringValue = url.absoluteString == "about:blank" && popupID == nil ? "" : url.absoluteString }
        back.isEnabled = web.canGoBack
        forward.isEnabled = web.canGoForward
        status.stringValue = web.isLoading ? "Loading…" : (web.url?.host ?? "")
    }
    private static func checkedLocation(_ url: URL) throws -> URL {
        if url.isFileURL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw RPCFailure(code: -32602, message: "Choose an existing local file, not a directory")
            }
        }
        return url
    }
    private func load(_ url: URL) -> WKNavigation? {
        if url.isFileURL {
            // Relative assets may be read below this directory, not the whole filesystem.
            // A file directly under / gets access to itself only.
            let directory = url.deletingLastPathComponent()
            return web.loadFileURL(url, allowingReadAccessTo: directory.path == "/" ? url : directory)
        }
        return web.load(URLRequest(url: url))
    }
    static func url(_ text: String) throws -> URL { try BrowserURL.parse(text, assumingHTTPS: true) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        automation.dialogs.alert(message, frame: frame, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        automation.dialogs.confirm(message, frame: frame, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        automation.dialogs.prompt(prompt, defaultText: defaultText, frame: frame, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        automation.openFileChooser(parameters: parameters, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload, let url = navigationAction.request.url,
           BrowserURL.allows(url) || url.scheme?.lowercased() == "blob" {
            decisionHandler(.download)
            return
        }
        guard let url = navigationAction.request.url, BrowserURL.allows(url) else {
            decisionHandler(.cancel)
            status.stringValue = "Navigation scheme is not allowed"
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let attachment = disposition.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
        let isDownload = !navigationResponse.canShowMIMEType || attachment
        if isDownload { downloadNavigation = currentNavigation }
        decisionHandler(isDownload ? .download : .allow)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.receive(download)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.receive(download)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !closed, navigationAction.targetFrame == nil,
              let url = navigationAction.request.url, BrowserURL.allows(url),
              !url.isFileURL || navigationAction.sourceFrame.request.url?.isFileURL == true else { return nil }
        return popupRegistry.open(configuration: configuration, opener: self, openerID: popupID,
                                  sourceFrame: navigationAction.sourceFrame, features: windowFeatures)
    }
    func webViewDidClose(_ webView: WKWebView) {
        guard let popupID else { return }
        popupOwner?.close(id: popupID)
    }

    var popupInfo: JSONValue { closed ? .array([]) : popupRegistry.info }

    func popup(id: String) throws -> BrowserPane {
        guard !closed else { throw RPCFailure(code: APIError.conflict, message: "Browser pane is closed") }
        return try popupRegistry.pane(id: id)
    }

    func closePopup(id: String, expected: WebIdentity? = nil) throws -> JSONValue {
        let pane = try popup(id: id)
        if let expected {
            guard pane.automation.viewID == expected.viewID,
                  pane.automation.documentID == expected.documentID, pane.automation.ready else {
                throw RPCFailure(code: APIError.conflict, message: "Popup view or document changed; inspect again")
            }
        }
        popupRegistry.close(id: id)
        return .object(["popupId": .string(id), "closed": .bool(true)])
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation else { return }
        // Host loads are ordered at submission, not by delayed delegate delivery.
        // An unknown navigation (e.g. a page link) is still a genuine successor.
        guard !submittedNavigations.contains(navigation) || navigation === currentNavigation else { return }
        trackNavigation(navigation)
        let preserved = trackedNavigations[ObjectIdentifier(navigation)]?.operation
        if let id = navigationOperation, id != preserved {
            navigationOperation = nil // Do not stop the successor navigation.
            automation.cancel(id, error: RPCFailure(code: -32022, message: "Navigation was superseded"))
        }
        automation.invalidate(except: preserved)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let navigation, navigation === currentNavigation else { return }
        automation.invalidate(except: trackedNavigations[ObjectIdentifier(navigation)]?.operation)
        rememberLocation()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation else { return }
        let tracked = trackedNavigations.removeValue(forKey: ObjectIdentifier(navigation))
        guard navigation === currentNavigation else {
            if let tracked { automation.complete(tracked.operation, .failure(CancellationError())) }
            return
        }
        automation.documentFinished()
        rememberLocation()
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
        let failure = error as NSError
        if failure.domain == "WebKitErrorDomain", failure.code == 204, webView.url?.isFileURL == true {
            // A committed built-in media document reports legacy "Plug-in handled load"
            // instead of didFinish. Treating it as failure would stop valid playback.
            self.webView(webView, didFinish: navigation)
            return
        }
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
        trackedNavigations.removeAll(); submittedNavigations.removeAllObjects(); currentNavigation = nil
    }
    private func navigationFailed(_ navigation: WKNavigation?, error: any Error) {
        guard let navigation else { return }
        let failure = error as NSError
        let becameDownload = navigation === downloadNavigation && failure.domain == "WebKitErrorDomain" && failure.code == 102
        if becameDownload {
            downloadNavigation = nil
            updateControls()
        } else if navigation === currentNavigation { status.stringValue = error.localizedDescription }
        if let tracked = trackedNavigations.removeValue(forKey: ObjectIdentifier(navigation)) {
            if navigationOperation == tracked.operation { navigationOperation = nil }
            automation.complete(tracked.operation, .failure(error))
        }
    }
    var info: JSONValue {
        var fields = automation.info
        fields.merge(["url": .string(web.url?.absoluteString ?? "about:blank"), "title": .string(web.title ?? ""), "loading": .bool(web.isLoading), "type": .string(mode.identifier), "persistent": .bool(web.configuration.websiteDataStore.isPersistent)]) { _, new in new }
        return .object(fields)
    }

    func navigate(_ value: String, beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        let url = try Self.checkedLocation(Self.url(value))
        guard !closed else { throw RPCFailure(code: -32022, message: "Browser pane is closed") }
        return try await automation.perform(timeoutMilliseconds: 15_000, beforeSubmission: beforeSubmission, onComplete: { [weak self] result in
            guard let self, self.navigationOperation != nil else { return }
            self.navigationOperation = nil
            if case .failure = result { self.web.stopLoading() }
        }) { id in
            self.cancelPendingNavigation()
            self.navigationOperation = id
            self.automation.invalidate(except: id)
            guard let navigation = self.load(url) else {
                self.automation.complete(id, .failure(RPCFailure(code: APIError.unavailable, message: "Navigation could not start")))
                return
            }
            self.trackNavigation(navigation)
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
