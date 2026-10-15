import AppKit
import WebKit
import SlateTermCore

@main
@MainActor
struct WebOperationChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func throwawaySubmission() { fatalError("Closed view submitted work") }
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
            print("PASS window-free web operations: cancellation/timeout/navigation retain platform capacity, process exit releases it, one-shot completion and closed admission")
        } catch {
            fputs("FAIL web operations: \(error)\n", stderr)
            exit(1)
        }
    }
}
