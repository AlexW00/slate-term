import AppKit
import WebKit
import SlateTermCore

// Investigation only: exercises unchanged WebPaneAutomation below the host's
// visibility gate. This is not an alternate production API or a plugin bridge test.
@MainActor
final class Fixture: NSObject, WKNavigationDelegate {
    private final class SchemeHandler: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            let data = Data(Fixture.html.utf8)
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }
    let web: WKWebView
    let automation: WebPaneAutomation
    var loadError: String?
    static let html = """
    <!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>html,body{margin:0;width:100%;height:100%;background:rgb(220,30,40)}
    h1{position:absolute;left:60px;top:60px;color:white;font:28px sans-serif}
    canvas{position:absolute;left:128px;top:160px;width:256px;height:160px}</style>
    <h1 id="label">INITIAL RED</h1><canvas id="paint" width="256" height="160"></canvas>
    <script>
    window.phase=0;
    window.paintPhase=function(n){
      window.phase=n;
      const colors=['rgb(220,30,40)','rgb(20,190,70)','rgb(30,80,220)'];
      document.documentElement.style.background=colors[n];
      document.body.style.background=colors[n];
      document.getElementById('label').textContent=['INITIAL RED','HIDDEN GREEN','HIDDEN BLUE'][n];
      const c=document.getElementById('paint').getContext('2d');
      c.fillStyle=colors[(n+1)%3];c.fillRect(0,0,256,160);
    };
    paintPhase(0);
    </script>
    """
    init(pluginLike: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if pluginLike { configuration.setURLSchemeHandler(SchemeHandler(), forURLScheme: "plugin") }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        automation = WebPaneAutomation(web: web)
        super.init()
        web.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { automation.documentFinished() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadError = String(describing: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { automation.processTerminated(); loadError = "Web process terminated" }
}

@main
@MainActor
struct BackgroundSnapshotProbe {
    struct Failure: Error { let message: String }
    static let colors = [[220,30,40], [20,190,70], [30,80,220]]
    static var rows: [[String: Any]] = []
    static var fixtures: [Fixture] = []
    static var windows: [NSWindow] = []
    static var output: URL!

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func pause(_ milliseconds: Int) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
    static func window(_ title: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 640, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.tabbingMode = .preferred
        w.tabbingIdentifier = "slate-background-snapshot-probe"
        windows.append(w)
        return w
    }
    static func state(_ fixture: Fixture, _ target: NSWindow) async throws -> [String: Any] {
        let value = try await fixture.automation.evaluate("({phase:window.phase,visibility:document.visibilityState,focus:document.hasFocus(),width:innerWidth,height:innerHeight})")
        let dom = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return ["dom": dom, "selected": target.tabGroup?.selectedWindow === target,
                "windowVisible": target.isVisible, "occlusionVisible": target.occlusionState.contains(.visible),
                "attached": fixture.web.window === target, "hiddenAncestor": fixture.web.isHiddenOrHasHiddenAncestor,
                "bounds": [fixture.web.bounds.width, fixture.web.bounds.height]]
    }
    static func checkPixels(_ path: URL, phase: Int, bounds: NSRect) throws -> [String: Any] {
        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: path))!
        // Compare encoded RGB samples. colorAt returns NSCalibratedRGBColorSpace
        // here despite the PNG's sRGB profile, so converting that NSColor again
        // changes the numbers and is not a valid comparison to CSS RGB values.
        try require(bitmap.bitsPerSample == 8 && bitmap.samplesPerPixel == 4 && !bitmap.isPlanar
                    && !bitmap.bitmapFormat.contains(.alphaFirst), "Unexpected PNG pixel format")
        let sx = CGFloat(bitmap.pixelsWide) / bounds.width
        let sy = CGFloat(bitmap.pixelsHigh) / bounds.height
        var samples: [[String: Any]] = []
        // Solid background corners plus the 2D canvas center (top-left coordinates).
        for (x, y, expectedPhase) in [(32.0,32.0,phase), (600,32,phase), (32,440,phase), (600,440,phase), (256,240,(phase+1)%3)] {
            let pixel = bitmap.bitmapData! + Int(y*sy)*bitmap.bytesPerRow + Int(x*sx)*4
            let actual = [Int(pixel[0]), Int(pixel[1]), Int(pixel[2])]
            let expected = colors[expectedPhase]
            samples.append(["point": [x,y], "rgb": actual, "expectedRGB": expected,
                            "matches": zip(actual,expected).allSatisfy { abs($0-$1) <= 12 }])
        }
        return ["width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "samples": samples,
                "freshPixels": samples.allSatisfy { $0["matches"] as? Bool == true }]
    }
    static func capture(_ name: String, fixture: Fixture, target: NSWindow, phase: Int) async throws {
        let selected = target.tabGroup?.selectedWindow
        let key = NSApp.keyWindow
        let responder = key?.firstResponder
        let selectedResponder = selected?.firstResponder
        let bounds = fixture.web.bounds
        let path = output.appendingPathComponent(name + ".png")
        var row: [String: Any] = ["name": name, "expectedPhase": phase, "before": try await state(fixture,target)]
        let start = Date()
        do {
            _ = try await fixture.automation.screenshot(to: path.path)
            row["pixels"] = try checkPixels(path, phase: phase, bounds: bounds)
            row["path"] = path.path
            row["success"] = true
        } catch {
            row["success"] = false
            row["error"] = String(describing: error)
        }
        row["seconds"] = Date().timeIntervalSince(start)
        row["after"] = try await state(fixture,target)
        let preserved = target.tabGroup?.selectedWindow === selected && NSApp.keyWindow === key
            && key?.firstResponder === responder && selected?.firstResponder === selectedResponder
        row["keyWindowPresent"] = key != nil
        row["firstResponderPresent"] = responder != nil
        row["selectedWindowWasKey"] = selected != nil && selected === key
        row["selectedWindowResponderPresent"] = selectedResponder != nil
        row["selectionAndFocusPreserved"] = preserved
        rows.append(row)
        print("PROBE \(name): success=\(row["success"]!) pixels=\((row["pixels"] as? [String: Any])?["freshPixels"] ?? false) selection/focus=\(preserved)")
        try require(preserved, "Capture changed selection/focus")
    }
    static func run() async throws {
        let target = window("Screenshot probe — target")
        let foreground = window("Screenshot probe — foreground (must stay selected)")
        let editor = NSTextField(string: "Focus sentinel — must remain focused")
        editor.frame = NSRect(x: 40, y: 200, width: 500, height: 30)
        foreground.contentView!.addSubview(editor)
        target.makeKeyAndOrderFront(nil)
        target.addTabbedWindow(foreground, ordered: .above)
        NSApp.activate(ignoringOtherApps: true)
        try await pause(300)
        for pluginLike in [false, true] {
            let prefix = pluginLike ? "plugin-scheme" : "browser-like"
            let fixture = Fixture(pluginLike: pluginLike)
            fixtures.append(fixture)
            fixture.web.autoresizingMask = [.width,.height]
            target.contentView = fixture.web
            target.makeKeyAndOrderFront(nil)
            target.tabGroup?.selectedWindow = target
            if pluginLike { fixture.web.load(URLRequest(url: URL(string: "plugin://probe/index.html")!)) }
            else { fixture.web.loadHTMLString(Fixture.html, baseURL: URL(string: "https://probe.invalid/")) }
            for _ in 0..<200 {
                if fixture.automation.ready && fixture.automation.documentID != nil { break }
                if let error = fixture.loadError { throw Failure(message: error) }
                try await pause(50)
            }
            try require(fixture.automation.ready && fixture.automation.documentID != nil, "Document did not become ready")
            try await pause(300)
            try await capture(prefix + "-01-visible-red", fixture: fixture, target: target, phase: 0)
            target.tabGroup?.selectedWindow = foreground
            foreground.makeKeyAndOrderFront(nil)
            try await pause(500)
            try require(target.tabGroup?.selectedWindow === foreground, "Failed to select foreground tab")
            try require(foreground.makeFirstResponder(editor), "Failed to focus sentinel text field")
            try await pause(100)
            try require(foreground.firstResponder != nil, "Foreground tab has no first responder")
            let document = fixture.automation.documentID
            _ = try await fixture.automation.evaluate("paintPhase(1); true")
            try await capture(prefix + "-02-inactive-green-immediate", fixture: fixture, target: target, phase: 1)
            try await pause(2000)
            _ = try await fixture.automation.evaluate("paintPhase(2); true")
            try await capture(prefix + "-03-inactive-blue-after-delay", fixture: fixture, target: target, phase: 2)
            try require(fixture.automation.documentID == document, "Capture changed document identity")
            target.tabGroup?.selectedWindow = target
            target.makeKeyAndOrderFront(nil)
            try await pause(300)
            try await capture(prefix + "-04-visible-blue-reference", fixture: fixture, target: target, phase: 2)
            fixture.automation.close()
        }
        try require(rows.count == 8 && rows.allSatisfy {
            $0["success"] as? Bool == true && ($0["pixels"] as? [String: Any])?["freshPixels"] as? Bool == true
        }, "One or more captures failed pixel freshness checks; inspect results.json")
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        Task { @MainActor in
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try await run()
            } catch { failure = String(describing: error); print("PROBE FAILURE: \(failure!)") }
            let result: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                "captureImplementation": "Unmodified WebPaneAutomation.screenshot -> WKWebView.takeSnapshot(nil)",
                "observations": rows, "failure": failure as Any? ?? NSNull()]
            do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("results.json")) }
            catch { print("RESULT WRITE FAILURE: \(error)"); failure = String(describing:error) }
            for fixture in fixtures { fixture.automation.close(); fixture.web.stopLoading(); fixture.web.navigationDelegate = nil }
            for window in windows { window.close() }
            exit(failure == nil ? 0 : 1)
        }
        app.run()
    }
}
