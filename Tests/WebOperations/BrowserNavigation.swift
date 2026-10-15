import AppKit
import WebKit
import SlateTermCore

/// Retains real WebKit callback identities while the test controls delivery order.
@MainActor
final class NavigationCallbacks: NSObject, WKNavigationDelegate {
    enum Event {
        case start(WKNavigation), commit(WKNavigation), finish(WKNavigation)
        case failure(WKNavigation, any Error)
    }
    let pane: BrowserPane
    var events: [Event] = []
    var finished: Bool { events.contains { if case .finish = $0 { return true }; return false } }
    init(_ pane: BrowserPane) { self.pane = pane }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { events.append(.start(navigation)) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { events.append(.commit(navigation)) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { events.append(.finish(navigation)) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { events.append(.failure(navigation, error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { events.append(.failure(navigation, error)) }
    func take() -> [Event] { defer { events.removeAll() }; return events }
    func deliver(_ event: Event) {
        switch event {
        case .start(let navigation): pane.webView(pane.web, didStartProvisionalNavigation: navigation)
        case .commit(let navigation): pane.webView(pane.web, didCommit: navigation)
        case .finish(let navigation): pane.webView(pane.web, didFinish: navigation)
        case .failure(let navigation, let error): pane.webView(pane.web, didFailProvisionalNavigation: navigation, withError: error)
        }
    }
}

@main
@MainActor
struct BrowserNavigationChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func eventually(_ label: String, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while try await !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(message: "Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    static func delayedInitialCallbacks(startingURL: Bool) async throws {
        let pane = BrowserPane(mode: .privateBrowser, dataStore: .nonPersistent())
        defer { pane.close() }
        let callbacks = NavigationCallbacks(pane)
        pane.web.navigationDelegate = callbacks
        pane.loadViewIfNeeded()
        try await eventually("welcome load callbacks") { callbacks.finished }
        var initial = callbacks.take()
        if startingURL {
            pane.loadStartingURL("about:blank")
            try await eventually("recipe starting URL callbacks") { callbacks.finished }
            initial += callbacks.take()
        }
        let request = Task { try await pane.navigate("about:blank") }
        defer { request.cancel() }
        try await eventually("explicit navigation submission") { pane.automation.pendingCount == 1 }
        // Initial loads were submitted first, but queued delegate callbacks arrive
        // after the RPC load. Neither start nor commit may replace the newer request.
        for event in initial {
            callbacks.deliver(event)
            try require(pane.automation.pendingCount == 1, "Delayed initial callback cancelled the explicit navigation: \(event)")
            try require(!pane.automation.ready, "Old document became ready during the new navigation")
        }
        try await eventually("requested navigation callbacks") { callbacks.finished }
        for event in callbacks.take() { callbacks.deliver(event) }
        let result = try await request.value
        try require(result.object?["url"] == .string("about:blank"), "Explicit navigation did not finish")
        try await eventually("navigation submissions released") { pane.automation.info["pendingSubmissions"] == .integer(0) }
        print("PASS delayed \(startingURL ? "welcome/recipe" : "welcome") callbacks preserve the explicit navigation")
    }
    static func supersession(pageInitiated: Bool) async throws {
        let pane = BrowserPane(mode: .privateBrowser, dataStore: .nonPersistent())
        defer { pane.close() }
        let callbacks = NavigationCallbacks(pane)
        pane.web.navigationDelegate = callbacks
        let first = Task { try await pane.navigate("about:blank") }
        defer { first.cancel() }
        try await eventually("first navigation callbacks") { callbacks.finished }
        let old = callbacks.take()
        var successor: Task<JSONValue, any Error>?
        defer { successor?.cancel() }
        if pageInitiated {
            // Bypass the host loader: this identity is unknown to BrowserPane,
            // just like a navigation initiated by a page link or script.
            pane.web.loadHTMLString("<title>Successor</title>", baseURL: nil)
        } else {
            successor = Task { try await pane.navigate("about:blank") }
        }
        try await eventually("successor navigation callbacks") { callbacks.finished }
        let next = callbacks.take()
        if pageInitiated {
            guard let start = next.first else { throw Failure(message: "No successor start") }
            callbacks.deliver(start)
        }
        do { _ = try await first.value; throw Failure(message: "Genuine successor did not supersede prior request") }
        catch let error as RPCFailure { try require(error.code == -32022, "Wrong supersession error") }
        try require(pane.automation.info["pendingSubmissions"] == .integer(pageInitiated ? 1 : 2), "Supersession prematurely released platform capacity")
        for event in old { callbacks.deliver(event) }
        try require(!pane.automation.ready, "Superseded document became ready")
        try require(pane.automation.pendingCount == (pageInitiated ? 0 : 1), "Old callbacks cancelled the successor")
        for event in pageInitiated ? Array(next.dropFirst()) : next { callbacks.deliver(event) }
        if let successor { _ = try await successor.value }
        try await eventually("successor identity ready") { pane.automation.info["ready"] == .bool(true) }
        try await eventually("all navigation slots released") { pane.automation.info["pendingSubmissions"] == .integer(0) }
        print("PASS \(pageInitiated ? "page" : "RPC") successor cancels the old caller without releasing its platform slot early")
    }
    static func cancellation() async throws {
        let pane = BrowserPane(mode: .privateBrowser, dataStore: .nonPersistent())
        defer { pane.close() }
        let callbacks = NavigationCallbacks(pane)
        pane.web.navigationDelegate = callbacks
        let request = Task { try await pane.navigate("about:blank") }
        defer { request.cancel() }
        try await eventually("cancelled navigation callbacks") { callbacks.finished }
        request.cancel()
        do { _ = try await request.value; throw Failure(message: "Cancelled navigation succeeded") }
        catch is CancellationError { }
        try require(pane.automation.info["pendingSubmissions"] == .integer(1), "Cancellation released the platform slot before callback delivery")
        for event in callbacks.take() { callbacks.deliver(event) }
        try await eventually("cancelled submission released") { pane.automation.info["pendingSubmissions"] == .integer(0) }
        print("PASS cancelled navigation releases its caller before its platform slot")
    }
    static func inFlight(_ url: String, cancel: Bool) async throws {
        let pane = BrowserPane(mode: .privateBrowser, dataStore: .nonPersistent())
        defer { pane.close() }
        let mode = cancel ? "cancel" : "supersede"
        let request = Task { try await pane.navigate(url + "held/" + mode) }
        defer { request.cancel() }
        try await eventually("server received in-flight HTTP navigation") {
            let (data, _) = try await URLSession.shared.data(from: URL(string: url + "started/" + mode)!)
            return data == Data("yes".utf8)
        }
        try require(pane.web.isLoading && pane.automation.pendingCount == 1, "Held response finished before interruption")
        if cancel {
            request.cancel()
            do { _ = try await request.value; throw Failure(message: "In-flight cancellation succeeded") }
            catch is CancellationError { }
        } else {
            let successor = Task { try await pane.navigate(url) }
            defer { successor.cancel() }
            do { _ = try await request.value; throw Failure(message: "In-flight navigation was not superseded") }
            catch let error as RPCFailure { try require(error.code == -32022, "Wrong in-flight supersession error") }
            let result = try await successor.value
            try require(result.object?["title"] == .string("Slate Browser Fixture"), "Old load failure stopped the successor")
        }
        try await eventually("in-flight load retired") { !pane.web.isLoading && pane.automation.info["pendingSubmissions"] == .integer(0) }
        print("PASS real in-flight \(cancel ? "cancellation" : "supersession") and platform failure callback cleanup")
    }
    static func naturalCallbacks(_ url: String) async throws {
        for _ in 0..<3 {
            let pane = BrowserPane(mode: .privateBrowser, dataStore: .nonPersistent())
            defer { pane.close() }
            pane.loadViewIfNeeded()
            let result = try await pane.navigate(url)
            try require(result.object?["title"] == .string("Slate Browser Fixture"), "First navigation did not load the local fixture")
            try await eventually("first document identity") { pane.automation.info["ready"] == .bool(true) }
            let document = pane.automation.documentID
            _ = try await pane.navigate(url + "next")
            try await eventually("next document identity") { pane.automation.info["ready"] == .bool(true) }
            try require(pane.automation.documentID != document, "New document revived the old identity")
            try pane.performCommand("browser.back")
            try await eventually("back navigation identity") { pane.currentURL == url && pane.automation.info["ready"] == .bool(true) }
            try require(pane.automation.documentID != document, "History restoration revived the original identity")
        }
        print("PASS three fresh browsers: immediate first navigation, real callback delivery, document replacement and history restoration")
    }
    static func localFiles() async throws {
        try await checkLocalFiles(mode: .privateBrowser, dataStore: .nonPersistent())
        let identifier = UUID(uuidString: CommandLine.arguments[3])!
        try await checkLocalFiles(mode: .browser, dataStore: WKWebsiteDataStore(forIdentifier: identifier))
    }
    static func checkLocalFiles(mode: PaneType, dataStore: WKWebsiteDataStore) async throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("slate-local-files-\(UUID())", isDirectory: true)
        let root = fixture.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "window.escapedReadScope = true;".write(to: fixture.appendingPathComponent("outside.js"), atomically: true, encoding: .utf8)
        let image = root.appendingPathComponent("image 日本語 #1.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: image)
        let video = root.appendingPathComponent("clip 日本語.mp4")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), to: video)
        let page = root.appendingPathComponent("local page 日本語 #1.html")
        try "body { color: rgb(12, 34, 56); }".write(to: root.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try "document.body.dataset.script = 'loaded';".write(to: root.appendingPathComponent("script.js"), atomically: true, encoding: .utf8)
        try """
        <!doctype html><meta charset="utf-8"><title>Local HTML Fixture</title>
        <link rel="stylesheet" href="style.css"><body><h1>Local file</h1>
        <img src="\(image.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)">
        <video controls preload="auto" src="\(video.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)"></video>
        <a id="next" href="next.html">Next</a><a id="popup" href="next.html" target="_blank">Popup</a>
        <script src="script.js"></script><script src="../outside.js"></script>
        """.write(to: page, atomically: true, encoding: .utf8)
        try "<title>Local Successor</title>".write(to: root.appendingPathComponent("next.html"), atomically: true, encoding: .utf8)
        let pane = BrowserPane(mode: mode, dataStore: dataStore)
        defer { pane.close() }
        pane.loadViewIfNeeded()
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        window.orderBack(nil) // Video source selection requires an attached, visible view.
        defer { window.close() }
        let result = try await pane.navigate(page.path)
        try await eventually("local document identity") { pane.automation.documentID != nil }
        try require(result.object?["title"] == .string("Local HTML Fixture"), "Local HTML navigation did not finish")
        try require(try await pane.evaluate("document.body.dataset.script === 'loaded' && getComputedStyle(document.body).color === 'rgb(12, 34, 56)' && document.images[0].naturalWidth === 8") == .bool(true), "Local relative scripts/styles/images did not load")
        try require(try await pane.evaluate("typeof workspace === 'undefined' && !window.webkit?.messageHandlers?.workspace") == .bool(true), "Local HTML received plugin privileges")
        try require(try await pane.evaluate("typeof escapedReadScope === 'undefined'") == .bool(true), "Local HTML read outside its containing directory")
        _ = try await pane.evaluate("const video = document.querySelector('video'); video.load(); video.play().catch(e => document.body.dataset.playError = String(e)); true")
        do {
            try await eventually("embedded local video decoding") {
                try await pane.evaluate("document.querySelector('video').videoWidth === 32 && document.querySelector('video').readyState >= 2") == .bool(true)
            }
        } catch {
            print("VIDEO DIAGNOSTICS", try await pane.evaluate("JSON.stringify((v => ({src:v.currentSrc,ready:v.readyState,network:v.networkState,error:v.error?.message,playError:document.body.dataset.playError,width:v.videoWidth}))(document.querySelector('video')))"))
            throw error
        }
        let document = pane.automation.documentID
        for invalid in [root.path, root.appendingPathComponent("missing.html").path] {
            do { _ = try await pane.navigate(invalid); throw Failure(message: "Invalid file destination succeeded") }
            catch let error as RPCFailure { try require(error.code == -32602, "Wrong missing-file error") }
            try require(pane.automation.ready && pane.automation.documentID == document, "Rejected file navigation retired the current document")
        }
        _ = try await pane.evaluate("document.querySelector('#next').click(); true")
        try await eventually("relative local link") { pane.web.title == "Local Successor" && !pane.web.isLoading }
        try pane.performCommand("browser.back")
        try await eventually("local history") { pane.web.title == "Local HTML Fixture" && !pane.web.isLoading }
        _ = try await pane.evaluate("document.querySelector('#popup').click(); true")
        try await eventually("local target blank link") { pane.web.title == "Local Successor" && !pane.web.isLoading }
        _ = try await pane.navigate(image.absoluteString)
        try require(try await pane.evaluate("document.images[0].naturalWidth === 8") == .bool(true), "Standalone local image did not decode")
        _ = try await pane.navigate(video.absoluteString)
        try await eventually("standalone local video decoding") {
            try await pane.evaluate("document.querySelector('video')?.videoWidth === 32 && document.querySelector('video')?.readyState >= 2") == .bool(true)
        }
        // Exercise the real native address action as well as the shared RPC loader.
        let toolbar = pane.view.subviews.compactMap { $0 as? NSStackView }.first!
        let address = toolbar.arrangedSubviews.compactMap { $0 as? NSTextField }.first!
        address.stringValue = page.path
        NSApp.sendAction(address.action!, to: address.target, from: address)
        try await eventually("native local address") { pane.web.title == "Local HTML Fixture" && !pane.web.isLoading }
        try pane.performCommand("browser.reload")
        try await eventually("local reload") { !pane.web.isLoading && pane.automation.ready }
        let recipe = BrowserPane(mode: mode, dataStore: dataStore)
        defer { recipe.close() }
        recipe.loadStartingURL(page.absoluteString)
        try await eventually("local recipe starting URL") { recipe.web.title == "Local HTML Fixture" && !recipe.web.isLoading }
        try require(pane.info.object?["type"] == .string(mode.identifier) && pane.info.object?["persistent"] == .bool(mode == .browser), "Local navigation changed the browser mode/store")
        print("PASS \(mode.identifier): local HTML, relative CSS/JS/image/video, standalone PNG/MP4, links/popups, history/reload, native address, recipe and bridge isolation")
    }
    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            if CommandLine.arguments[1] == "--remove-profile" {
                // Run only after the owning fixture exits: AppKit/WebKit can retain
                // closed views beyond their Swift scope, keeping a profile in use.
                let identifier = UUID(uuidString: CommandLine.arguments[2])!
                let store = WKWebsiteDataStore(forIdentifier: identifier)
                defer { withExtendedLifetime(store) {} }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                print("PASS temporary persistent browser profile removed")
                return
            }
            try await delayedInitialCallbacks(startingURL: false)
            try await delayedInitialCallbacks(startingURL: true)
            try await supersession(pageInitiated: false)
            try await supersession(pageInitiated: true)
            try await cancellation()
            let url = CommandLine.arguments[1]
            try await inFlight(url, cancel: false)
            try await inFlight(url, cancel: true)
            try await naturalCallbacks(url)
            try await localFiles()
        } catch {
            fputs("FAIL browser navigation: \(error)\n", stderr)
            exit(1)
        }
    }
}
