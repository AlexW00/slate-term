import AppKit
import WebKit
import SlateTermCore

/// Composed by both pane adapters. Navigation, data stores and bridge privileges
/// stay with those adapters; this world contains DOM automation only.
@MainActor
final class WebPaneAutomation {
    let web: WKWebView
    let viewID: String
    let world = WKContentWorld.world(name: "SlateAutomation")
    private(set) var documentID: String?
    private(set) var ready = false
    private var generation = UUID()
    private var closed = false
    private var initialization: Task<Void, Never>?
    private struct Operation {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let deadline: Task<Void, Never>
        let onComplete: ((Result<JSONValue, any Error>) -> Void)?
    }
    private var operations: [UUID: Operation] = [:]
    private var submissions: Set<UUID> = []
    // Waiting DOM actions release each WebKit probe while sleeping, but still
    // consume a bounded logical-action slot until cancellation/completion.
    private var activeActions = 0
    var pendingCount: Int { operations.count }

    init(web: WKWebView, viewID: String = UUID().uuidString) {
        self.web = web
        self.viewID = viewID
    }

    func invalidate(except preserved: UUID? = nil) {
        generation = UUID()
        ready = false
        documentID = nil
        initialization?.cancel(); initialization = nil
        for id in Array(operations.keys) where id != preserved {
            finish(id, .failure(RPCFailure(code: -32022, message: "Web document changed during the operation")))
        }
    }

    func documentFinished() {
        guard !closed else { return }
        ready = true
        let expected = generation
        initialization?.cancel()
        initialization = Task { [weak self] in
            guard let self else { return }
            _ = try? await self.prepareIdentity(generation: expected)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        invalidate()
        submissions.removeAll() // Closed views cannot admit more work.
    }

    func processTerminated() {
        invalidate()
        submissions.removeAll() // The platform has definitively retired these submissions.
    }

    func cancel(_ id: UUID, error: any Error) { finish(id, .failure(error)) }

    var info: [String: JSONValue] {
        ["viewId": .string(viewID), "documentId": ready ? documentID.map(JSONValue.string) ?? .null : .null,
         "ready": .bool(ready && documentID != nil && !closed), "pendingOperations": .integer(pendingCount),
         "pendingActions": .integer(activeActions), "pendingSubmissions": .integer(submissions.count)]
    }

    private func prepareIdentity(generation expected: UUID, beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> WebIdentity {
        guard !closed, generation == expected else { throw RPCFailure(code: -32022, message: "Web document was replaced") }
        let result = try await evaluate(BrowserAutomation.prepareScript(viewID: viewID), isolated: true, beforeSubmission: beforeSubmission)
        guard !closed, generation == expected, let document = result.object?["documentId"]?.string else {
            throw RPCFailure(code: -32022, message: "Web document was replaced")
        }
        let identity = try WebIdentity(viewID: viewID, documentID: document)
        documentID = document
        return identity
    }

    func inspect(expected: WebIdentity? = nil, beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        try beforeSubmission()
        guard ready, !closed else {
            if expected != nil { throw RPCFailure(code: APIError.unavailable, message: "Web document is not ready") }
            return .object(info)
        }
        let identity = try await prepareIdentity(generation: generation, beforeSubmission: beforeSubmission)
        try require(expected, matches: identity)
        return .object(info)
    }

    func evaluate(_ source: String, isolated: Bool = false, timeoutMilliseconds: Int = 10_000,
                  beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        try await perform(timeoutMilliseconds: timeoutMilliseconds, beforeSubmission: beforeSubmission) { id in
            web.evaluateJavaScript(source, in: nil, in: isolated ? world : .page) { [weak self] result in
                guard let self else { return }
                guard self.operations[id] != nil else { self.submissions.remove(id); return }
                do { self.complete(id, .success(try Self.jsonValue(result.get()))) }
                catch { self.complete(id, .failure(error)) }
            }
        }
    }

    func automate(_ action: BrowserAction, expected: WebIdentity? = nil, requireReady: Bool = false,
                  beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        guard activeActions < 32 else { throw RPCFailure(code: -32025, message: "Too many pending web actions") }
        activeActions += 1
        defer { activeActions -= 1 }
        let captured = generation
        if requireReady, !ready { throw RPCFailure(code: APIError.unavailable, message: "Web document is not ready") }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(action.timeoutMilliseconds == 0 ? 10_000 : action.timeoutMilliseconds))
        func remaining() throws -> Int {
            let interval = ContinuousClock.now.duration(to: deadline)
            guard interval > .zero else { throw RPCFailure(code: -32024, message: "Web condition timed out") }
            return max(1, Int(interval.components.seconds * 1000 + interval.components.attoseconds / 1_000_000_000_000_000))
        }
        let prepared = try await evaluate(BrowserAutomation.prepareScript(viewID: viewID), isolated: true,
                                          timeoutMilliseconds: remaining(), beforeSubmission: beforeSubmission)
        guard !closed, captured == generation, let document = prepared.object?["documentId"]?.string else {
            throw RPCFailure(code: -32022, message: "Web document was replaced")
        }
        let identity = try WebIdentity(viewID: viewID, documentID: document)
        try require(expected, matches: identity)
        documentID = document
        let source = try BrowserAutomation.script(for: action, documentID: document)
        while true {
            try Task.checkCancellation()
            guard !closed, generation == captured else { throw RPCFailure(code: -32022, message: "Web document was replaced") }
            let result = try await evaluate(source, isolated: true, timeoutMilliseconds: remaining(), beforeSubmission: beforeSubmission)
            if action.kind != .wait || result.object?["matched"] == .bool(true) { return result }
            guard action.timeoutMilliseconds > 0 else { throw RPCFailure(code: -32024, message: "Web condition did not match") }
            try await Task.sleep(for: .milliseconds(min(50, remaining())))
        }
    }

    private func require(_ expected: WebIdentity?, matches actual: WebIdentity) throws {
        guard expected == nil || expected == actual else {
            throw RPCFailure(code: APIError.conflict, message: "Web view or document changed; inspect again")
        }
    }

    static func jsonValue(_ value: Any?) throws -> JSONValue {
        let data = try JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.fragmentsAllowed])
        guard data.count <= 900_000 else { throw RPCFailure(code: -32025, message: "Web result exceeds 900000 bytes") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func perform(timeoutMilliseconds: Int = 10_000, beforeSubmission: @MainActor () throws -> Void = {},
                 onComplete: ((Result<JSONValue, any Error>) -> Void)? = nil, _ start: (UUID) -> Void) async throws -> JSONValue {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !closed, !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                do { try beforeSubmission() } catch { continuation.resume(throwing: error); return }
                guard submissions.count < 32 else { continuation.resume(throwing: RPCFailure(code: -32025, message: "Too many pending web operations")); return }
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(timeoutMilliseconds)) } catch { return }
                    self?.finish(id, .failure(RPCFailure(code: -32024, message: "Web operation timed out")))
                }
                operations[id] = Operation(continuation: continuation, deadline: deadline, onComplete: onComplete)
                submissions.insert(id)
                start(id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }

    /// Called only when the submitted platform work actually calls back.
    func complete(_ id: UUID, _ result: Result<JSONValue, any Error>) {
        submissions.remove(id)
        finish(id, result)
    }

    private func finish(_ id: UUID, _ result: Result<JSONValue, any Error>) {
        guard let operation = operations.removeValue(forKey: id) else { return }
        operation.deadline.cancel()
        operation.onComplete?(result)
        operation.continuation.resume(with: result)
    }

    func screenshot(to path: String, beforeSubmission: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        try await perform(beforeSubmission: beforeSubmission) { id in
            web.takeSnapshot(with: nil) { [weak self] image, error in
                guard let self else { return }
                guard self.operations[id] != nil else { self.submissions.remove(id); return }
                do {
                    if let error { throw error }
                    guard let data = image?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
                          let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw RPCFailure(code: -32023, message: "Snapshot unavailable")
                    }
                    try beforeSubmission()
                    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                    self.complete(id, .success(.object(["path": .string(path)])))
                } catch { self.complete(id, .failure(error)) }
            }
        }
    }
}
