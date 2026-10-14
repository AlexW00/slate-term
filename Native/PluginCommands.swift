import Darwin
import Foundation
import SlateTermCore

/// Bounded, on-demand jobs. No WebKit view or HTTP listener is needed.
@MainActor
final class PluginCommands {
    @MainActor
    private final class Run {
        let id = UUID().uuidString
        let plugin: String
        let command: String
        let tab: TabID?
        let pane: PaneID?
        var process: PluginProcess?
        var state = "running"
        var failure: RPCFailure?
        var exit: PluginCommandExit?
        var stdout = ""
        var stderr = ""
        init(plugin: String, command: String, tab: TabID?, pane: PaneID?) {
            self.plugin = plugin; self.command = command; self.tab = tab; self.pane = pane
        }
        var info: JSONValue {
            .object(["instanceId": .string(id), "type": .string(plugin), "kind": .string("command"),
                     "commandId": .string(command), "state": .string(state),
                     "tabId": tab.map { .string($0.description) } ?? .null,
                     "paneId": pane.map { .string($0.description) } ?? .null,
                     "pid": process.map { .integer(Int($0.pid)) } ?? .null,
                     "exitCode": exit?.exitCode.map(JSONValue.integer) ?? .null,
                     "signal": exit?.signal.map(JSONValue.integer) ?? .null,
                     "error": failure.map { .string($0.message) } ?? .null])
        }
        var logs: String {
            "[stdout]\n" + (process.map { String(decoding: $0.stdoutTail, as: UTF8.self) } ?? stdout)
                + "\n[stderr]\n" + (process.map { String(decoding: $0.stderrTail, as: UTF8.self) } ?? stderr)
        }
    }
    private var runs: [Run] = []
    var onChange: (() -> Void)?

    var all: [JSONValue] { runs.map(\.info) }
    func logs(instanceID: String) -> String? { runs.first { $0.id == instanceID }?.logs }

    func execute(plugin: PluginRegistration, command: PluginCommand, connection: PluginControlConnection,
                 tab: TabID?, pane: PaneID?, params: [String: JSONValue], settings: [String: JSONValue]) async throws -> JSONValue {
        try Task.checkCancellation()
        let commandID = command.namespacedID(plugin: plugin.id)
        guard !runs.contains(where: { $0.command == commandID && $0.state == "running" }) else {
            throw RPCFailure(code: -32023, message: "Plugin command is already running: \(commandID)")
        }
        guard runs.filter({ $0.state == "running" }).count < 16 else {
            throw RPCFailure(code: -32023, message: "At most 16 plugin commands may run concurrently")
        }
        let encodedParams = try JSONEncoder().encode(params)
        guard encodedParams.count <= 16_384 else { throw RPCFailure(code: -32602, message: "Plugin command parameters exceed 16 KiB") }
        let run = Run(plugin: plugin.id, command: commandID, tab: tab, pane: pane)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-command-\(run.id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let statusFile = directory.appendingPathComponent("exit.json")
        var environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, value in value }
        for key in environment.keys where key.hasPrefix("SLATE_TERM_") { environment.removeValue(forKey: key) }
        environment["SLATE_TERM_SOCKET"] = connection.socketPath
        environment["SLATE_TERM_CLI"] = connection.cliPath
        environment["SLATE_TERM_INSTANCE_ID"] = connection.appInstanceID
        environment["SLATE_TERM_PLUGIN_ID"] = plugin.id
        environment["SLATE_TERM_PLUGIN_INSTANCE"] = run.id
        environment["SLATE_TERM_COMMAND_ID"] = commandID
        environment["SLATE_TERM_COMMAND_PARAMS"] = String(decoding: encodedParams, as: UTF8.self)
        environment["SLATE_TERM_PLUGIN_SETTINGS"] = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        environment["SLATE_TERM_TAB_ID"] = tab?.description
        environment["SLATE_TERM_PANE_ID"] = pane?.description
        let helperDirectory = URL(fileURLWithPath: connection.cliPath).deletingLastPathComponent().path
        environment["PATH"] = helperDirectory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        while runs.count >= 64, let index = runs.firstIndex(where: { $0.state != "running" }) { runs.remove(at: index) }
        runs.append(run)
        do {
            let process = try PluginProcess(executable: connection.cliPath,
                arguments: ["_plugin-worker", "--parent-pid", String(getpid()), "--exit-status-file", statusFile.path, command.executable] + command.arguments,
                directory: command.directory.map { URL(fileURLWithPath: $0) }, environment: environment)
            run.process = process
            process.onExit = { [weak self, weak run] status in
                guard let self, let run, run.state == "running" else { return }
                do {
                    let handle = try FileHandle(forReadingFrom: statusFile)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 4097) ?? Data()
                    guard data.count <= 4096 else { throw RPCFailure(code: -32025, message: "Invalid command exit report") }
                    let exit = try JSONDecoder().decode(PluginCommandExit.self, from: data)
                    guard (exit.exitCode != nil) != (exit.signal != nil),
                          exit.exitCode.map({ (0...255).contains($0) }) ?? true,
                          exit.signal.map({ (1...127).contains($0) }) ?? true else {
                        throw RPCFailure(code: -32025, message: "Invalid command exit report")
                    }
                    run.exit = exit
                    if exit.exitCode == 0 { self.finish(run, state: "succeeded") }
                    else { self.finish(run, state: "failed", message: "Command exited with \(exit.exitCode.map { "code \($0)" } ?? "signal \(exit.signal!)")") }
                } catch {
                    self.finish(run, state: "failed", message: "Command supervisor exited without a valid exit report: \(status)")
                }
            }
            onChange?()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(command.timeoutSeconds * 1000)))
            while run.state == "running" {
                if ContinuousClock.now >= deadline {
                    finish(run, state: "timedOut", message: "Command exceeded \(command.timeoutSeconds) seconds", code: -32024)
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            if run.state == "running" {
                finish(run, state: error is CancellationError ? "cancelled" : "failed", message: String(describing: error),
                       code: error is CancellationError ? -32022 : -32025)
            }
        }
        if let failure = run.failure { throw failure }
        var result = run.info.object!
        result["stdout"] = .string(run.stdout)
        result["stderr"] = .string(run.stderr)
        return .object(result)
    }

    private func finish(_ run: Run, state: String, message: String? = nil, code: Int = -32025) {
        guard run.state == "running" else { return }
        if let process = run.process {
            run.stdout = String(decoding: process.stdoutTail, as: UTF8.self)
            run.stderr = String(decoding: process.stderrTail, as: UTF8.self)
            process.close()
            run.process = nil
        }
        run.state = state
        run.failure = message.map { RPCFailure(code: code, message: "\($0) (\(run.command), instance \(run.id)); inspect plugins logs; do not blindly retry") }
        onChange?()
    }

    func remove(plugin: String) {
        for run in runs where run.plugin == plugin { finish(run, state: "cancelled", message: "Plugin was unregistered or replaced", code: -32022) }
        // Keep diagnostic records after unload: callers receive the invocation ID
        // and must still be able to inspect partial output and cancellation state.
    }
    func close() {
        onChange = nil
        for run in runs { finish(run, state: "cancelled", message: "Application is closing", code: -32022) }
        runs.removeAll()
    }
}
