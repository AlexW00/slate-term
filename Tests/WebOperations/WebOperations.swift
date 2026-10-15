import AppKit
import WebKit
import SlateTermCore

@MainActor
final class ControlledSnapshotView: WKWebView {
    var snapshotCompletion: (@MainActor (NSImage?, Error?) -> Void)?
    override func takeSnapshot(with snapshotConfiguration: WKSnapshotConfiguration?, completionHandler: @escaping @MainActor (NSImage?, Error?) -> Void) {
        snapshotCompletion = completionHandler
    }
}

@main
@MainActor
struct WebOperationChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func throwawaySubmission() { fatalError("Closed view submitted work") }
    static func screenshotChecks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-screenshot-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
        bitmap.bitmapData!.initialize(repeating: 255, count: 64)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.addRepresentation(bitmap)
        for mode in ["guard", "navigation", "cancellation", "close", "success"] {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let web = ControlledSnapshotView(frame: NSRect(x: 0, y: 0, width: 4, height: 4), configuration: config)
            let helper = WebPaneAutomation(web: web)
            defer { helper.close() }
            let path = directory.appendingPathComponent(mode + ".png")
            let original = Data("existing output must survive failed capture".utf8)
            try original.write(to: path)
            var valid = true
            let capture = Task {
                try await helper.screenshot(to: path.path, beforeSubmission: {
                    if !valid { throw RPCFailure(code: APIError.conflict, message: "Capture layout/target changed") }
                })
            }
            for _ in 0..<1000 where web.snapshotCompletion == nil { await Task.yield() }
            try require(web.snapshotCompletion != nil, "Snapshot did not submit")
            switch mode {
            case "guard": valid = false
            case "navigation": helper.invalidate()
            case "cancellation":
                capture.cancel()
                // Let caller cancellation retire its continuation before the platform callback.
                for _ in 0..<1000 where helper.pendingCount != 0 { await Task.yield() }
                try require(helper.pendingCount == 0, "Cancelled screenshot retained caller")
            case "close": helper.close()
            default: break
            }
            web.snapshotCompletion?(image, nil)
            web.snapshotCompletion = nil
            if mode == "success" {
                _ = try await capture.value
                try require(NSBitmapImageRep(data: try Data(contentsOf: path))?.pixelsWide == 4, "Screenshot output missing")
            } else {
                do { _ = try await capture.value; throw Failure(message: "Retired screenshot succeeded: " + mode) }
                catch is RPCFailure { }
                catch is CancellationError { }
                try require(try Data(contentsOf: path) == original, "Retired screenshot overwrote output: " + mode)
            }
            try require(helper.pendingCount == 0 && helper.info["pendingSubmissions"] == .integer(0), "Screenshot leaked capacity")
        }
    }
    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let helper = WebPaneAutomation(web: WKWebView(frame: .zero, configuration: config))
        defer { helper.close() }
        do {
            var submissions: [UUID] = []
            for _ in 0..<32 {
                var submitted: UUID?
                let task = Task { try await helper.perform { submitted = $0 } }
                for _ in 0..<1000 where submitted == nil { await Task.yield() }
                guard let id = submitted else { throw Failure(message: "Submission did not start") }
                submissions.append(id)
                task.cancel()
                do { _ = try await task.value; throw Failure(message: "Cancelled caller succeeded") }
                catch is CancellationError { }
                try require(helper.pendingCount == 0, "Caller continuation was retained after cancellation")
            }
            // No platform callback has arrived. Cancellation must not authorize
            // more submissions into a blocked WebKit process.
            do {
                _ = try await helper.perform { helper.complete($0, .success(.null)) }
                throw Failure(message: "Cancellation released an outstanding platform slot")
            } catch let error as RPCFailure {
                try require(error.code == -32025, "Wrong capacity refusal")
            }
            for id in submissions { helper.complete(id, .success(.null)); helper.complete(id, .success(.null)) }
            _ = try await helper.perform { helper.complete($0, .success(.null)) }
            var timedOut: UUID?
            do {
                _ = try await helper.perform(timeoutMilliseconds: 1) { timedOut = $0 }
                throw Failure(message: "Deadline did not finish caller")
            } catch let error as RPCFailure { try require(error.code == -32024, "Wrong timeout error") }
            try require(helper.info["pendingSubmissions"] == .integer(1), "Timeout prematurely released platform capacity")
            helper.invalidate()
            try require(helper.info["pendingSubmissions"] == .integer(1), "Navigation prematurely released platform capacity")
            helper.processTerminated()
            try require(helper.info["pendingSubmissions"] == .integer(0), "Process termination retained dead submissions")
            if let timedOut { helper.complete(timedOut, .success(.null)) }
            var completions = 0
            _ = try await helper.perform(onComplete: { _ in completions += 1 }) { id in
                helper.complete(id, .success(.null)); helper.complete(id, .success(.null))
            }
            try require(completions == 1 && helper.pendingCount == 0, "Completion was repeated or leaked")
            helper.close()
            do {
                _ = try await helper.perform { _ in throwawaySubmission() }
                throw Failure(message: "Closed view admitted work")
            } catch is CancellationError { }
            try await screenshotChecks()
            print("PASS window-free web operations: bounded platform capacity, one-shot completion/closed admission; screenshot output revalidation, navigation/cancellation/close suppress late writes, successful PNG output")
        } catch {
            fputs("FAIL web operations: \(error)\n", stderr)
            exit(1)
        }
    }
}
