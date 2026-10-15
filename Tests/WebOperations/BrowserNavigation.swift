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
        let pane = BrowserPane()
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
        let pane = BrowserPane()
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
        let pane = BrowserPane()
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
        let pane = BrowserPane()
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
            let pane = BrowserPane()
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
    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try await delayedInitialCallbacks(startingURL: false)
            try await delayedInitialCallbacks(startingURL: true)
            try await supersession(pageInitiated: false)
            try await supersession(pageInitiated: true)
            try await cancellation()
            let url = CommandLine.arguments[1]
            try await inFlight(url, cancel: false)
            try await inFlight(url, cancel: true)
            try await naturalCallbacks(url)
        } catch {
            fputs("FAIL browser navigation: \(error)\n", stderr)
            exit(1)
        }
    }
}
