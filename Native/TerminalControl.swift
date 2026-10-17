import Foundation
import SlateTermCore

/// Generic terminal I/O and authenticated shell completion. Tool-specific protocols live in extensions.
@MainActor
final class TerminalControl {
    struct Target {
        let paneID: PaneID
        let sessionID: String
        let runKey: String
        let view: TerminalView
        let report: ShellReport?
    }
    private let lookup: (PaneID) -> Target?
    private let runs = TerminalRuns()
    private var waits = Set<UUID>()
    private var closed = false
    var pendingRuns: Int { runs.pendingCount }
    var pendingWaits: Int { waits.count }
    func displayCommand(pane: PaneID) -> String? { runs.displayCommand(pane: pane) }
    func claimInput(pane: PaneID, sessionID: String, emptyBuffer: Bool) throws -> String {
        try runs.claimInput(pane: pane, sessionID: sessionID, emptyBuffer: emptyBuffer)
    }

    init(lookup: @escaping (PaneID) -> Target?) { self.lookup = lookup }
    func reserveStartup(_ panes: Set<PaneID>) throws { try runs.reserve(panes) }
    func releaseStartup(_ pane: PaneID) { runs.releaseReservation(pane) }
    func remove(pane: PaneID) { runs.remove(pane: pane) }
    func close() { closed = true; runs.close() }
    /// Late reports are forwarded too: run tracking pairs commands with prompts by sequence.
    func observe(pane: PaneID, sessionID: String, report: ShellReport) {
        guard let target = lookup(pane), target.sessionID == sessionID else { runs.remove(pane: pane); return }
        runs.observe(pane: pane, sessionID: sessionID, report: report, capture: { target.view.capture() })
    }

    func call(_ action: String, pane: PaneID, params: [String: JSONValue], startup: Bool = false,
              validateCaller: @escaping @MainActor () throws -> Void = {}) async throws -> JSONValue {
        try validateCaller()
        let fields: Set<String>
        switch action {
        case "send": fields = ["text"]
        case "key": fields = ["key"]
        case "capture": fields = []
        case "run": fields = ["command", "timeoutMilliseconds", "shell"]
        case "wait": fields = ["contains", "afterSequence", "timeoutMilliseconds"]
        default: throw RPCFailure(code: -32601, message: "Unknown terminal action")
        }
        let allowed = fields.union(["pane", "tab", "scope", "sessionId"])
        guard params.keys.allSatisfy({ allowed.contains($0) }) else { throw RPCFailure(code: -32602, message: "Unknown terminal parameter") }
        if let scope = params["scope"] {
            guard let scope = scope.string, ["pane", "tab", "global"].contains(scope) else { throw RPCFailure(code: -32602, message: "scope must be pane, tab, or global") }
        }
        guard !closed, let target = lookup(pane) else { throw RPCFailure(code: -32022, message: "Terminal session is unavailable") }
        if let value = params["sessionId"] {
            guard let session = value.string else { throw RPCFailure(code: -32602, message: "sessionId must be a string") }
            guard session == target.sessionID else { throw RPCFailure(code: -32022, message: "Terminal session was replaced; read context again") }
        }
        if action == "key" {
            guard let key = params["key"]?.string else { throw RPCFailure(code: -32602, message: "key must be a string") }
            try target.view.sendKey(TerminalKey(parsing: key))
            return .object([:])
        }
        if action == "send" {
            guard let text = params["text"]?.string else { throw RPCFailure(code: -32602, message: "text must be a string") }
            try target.view.send(text)
            return .object([:])
        }
        if action == "capture" {
            let output = TerminalOutput(target.view.capture())
            return .object(["text": .string(output.text), "truncated": .bool(output.truncated),
                            "paneId": .string(pane.description), "sessionId": .string(target.sessionID)])
        }
        let timeout: Int
        if let value = params["timeoutMilliseconds"] {
            guard case .integer(let milliseconds) = value, (1...295_000).contains(milliseconds) else {
                throw RPCFailure(code: -32602, message: "timeoutMilliseconds must be an integer in 1...295000")
            }
            timeout = milliseconds
        } else { timeout = 30_000 }
        if action == "run" {
            var expected: ShellKind?
            if let value = params["shell"] {
                guard let name = value.string, let kind = ShellKind(rawValue: name) else {
                    throw RPCFailure(code: -32602, message: "shell must be zsh, bash or fish")
                }
                expected = kind
            }
            guard let report = target.report, report.state == .prompt else {
                throw RPCFailure(code: -32041, message: "Run requires a known idle prompt from shell integration; use literal send for other terminal applications")
            }
            // The command is source code in the pane's shell language; never run it in another shell.
            if let expected, expected != report.shellKind {
                throw RPCFailure(code: -32041, message: "Pane runs \(report.shellKind.rawValue), not \(expected.rawValue); the command was not submitted")
            }
            guard report.acceptsRunInput else {
                throw RPCFailure(code: -32041, message: "Run requires bash 4.4 or later, which can check the edit line before submitting; this shell reports state only")
            }
            guard let command = params["command"]?.string else { throw RPCFailure(code: -32602, message: "command must be a string") }
            do {
                let result = try await runs.run(pane: pane, sessionID: target.sessionID, command: command,
                    timeoutMilliseconds: timeout, shell: report.shellKind, baseline: report.sequence,
                    usingReservation: startup, validateCaller: validateCaller,
                    send: { _ in try target.view.send(target.runKey) })
                return try .encoding(result)
            } catch let error as TerminalRunError {
                throw RPCFailure(code: error == .timeout ? -32024 : -32042, message: error.localizedDescription)
            }
        }
        let contains: String?
        if let value = params["contains"] {
            guard let text = value.string, !text.isEmpty, text.utf8.count <= 4_096 else {
                throw RPCFailure(code: -32602, message: "contains must be a nonempty string of at most 4096 UTF-8 bytes")
            }
            contains = text
        } else { contains = nil }
        let afterSequence: Int?
        if let value = params["afterSequence"] {
            guard contains == nil, case .integer(let sequence) = value, sequence >= 0 else {
                throw RPCFailure(code: -32602, message: "afterSequence requires a prompt wait and a nonnegative integer")
            }
            afterSequence = sequence
        } else { afterSequence = nil }
        guard contains != nil || target.report != nil else {
            throw RPCFailure(code: -32041, message: "Prompt state is unknown; use an explicit screen-text condition instead")
        }
        guard waits.count < 32 else { throw RPCFailure(code: -32042, message: "Too many pending terminal waits") }
        let operation = UUID()
        waits.insert(operation)
        defer { waits.remove(operation) }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(timeout))
        while true {
            try Task.checkCancellation()
            try validateCaller()
            guard !closed, let current = lookup(pane), current.sessionID == target.sessionID else {
                throw RPCFailure(code: -32022, message: "Terminal session was replaced while waiting")
            }
            let matched = contains.map { current.view.capture().contains($0) }
                ?? (current.report?.state == .prompt && (afterSequence.map { (current.report?.sequence ?? 0) > $0 } ?? true))
            if matched {
                return .object(["matched": .bool(true), "paneId": .string(pane.description), "sessionId": .string(target.sessionID),
                    "sequence": current.report.map { .integer($0.sequence) } ?? .null, "exitCode": current.report?.exitCode.map(JSONValue.integer) ?? .null])
            }
            guard ContinuousClock.now < deadline else { throw RPCFailure(code: -32024, message: "Terminal condition timed out; the shell process was not stopped") }
            try await Task.sleep(until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(50))), clock: .continuous)
        }
    }
}
