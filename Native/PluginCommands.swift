import Darwin
import Foundation
import SlateTermCore

struct CommandLifecycleContext: Sendable {
    let operation: WorkspaceOperationContext
    let launchWorkspaceRevision: String
    let launchLayoutRevision: String?
}

struct CommandLifecycle: Sendable {
    enum Phase: String, Sendable { case started, finished }
    enum State: String, Sendable { case running, succeeded, failed, timedOut, cancelled }
    enum Reason: String, Sendable { case exit, signal, spawnFailure, supervisorFailure, timeout, cancelled, unregistered, shutdown }
    let phase: Phase
    let invocationID: String
    let commandID: String
    let tab: TabID?
    let pane: PaneID?
    let state: State
    let exitCode: Int?
    let signal: Int?
    let reason: Reason?
}

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
        var cleanup: ProcessCleanup?
        var cleanupPending: Bool { cleanup?.snapshot.confirmed == false }
        var state = CommandLifecycle.State.running
        var failure: RPCFailure?
        var exit: PluginCommandExit?
        var stdout = ""
        var stderr = ""
        let lifecycle: CommandLifecycleContext
        init(plugin: String, command: String, tab: TabID?, pane: PaneID?, lifecycle: CommandLifecycleContext) {
            self.plugin = plugin; self.command = command; self.tab = tab; self.pane = pane; self.lifecycle = lifecycle
        }
        var info: JSONValue {
            .object(["instanceId": .string(id), "type": .string(plugin), "kind": .string("command"),
                     "commandId": .string(command), "state": .string(state.rawValue),
                     "tabId": tab.map { .string($0.description) } ?? .null,
                     "paneId": pane.map { .string($0.description) } ?? .null,
                     "pid": process.map { .integer(Int($0.pid)) } ?? .null,
                     "cleanupPending": .bool(cleanupPending),
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
    var onLifecycle: ((CommandLifecycle, CommandLifecycleContext) throws -> Void)?

    var all: [JSONValue] { runs.map(\.info) }
    func logs(instanceID: String) -> String? { runs.first { $0.id == instanceID }?.logs }

    func execute(plugin: PluginRegistration, command: PluginCommand, connection: PluginControlConnection,
                 tab: TabID?, pane: PaneID?, params: [String: JSONValue], settings: [String: JSONValue],
                 lifecycle: CommandLifecycleContext, validateTarget: @MainActor () throws -> Void = {}) async throws -> JSONValue {
        try Task.checkCancellation()
        try plugin.requireCompatibility()
        try lifecycle.operation.validateCaller()
        try validateTarget()
        let controlEnvironment = try connection.commandEnvironment(owner: lifecycle.operation.serviceOwner)
        let commandID = command.namespacedID(plugin: plugin.id)
        guard !runs.contains(where: { $0.command == commandID && ($0.state == .running || $0.cleanupPending) }) else {
            throw RPCFailure(code: -32023, message: "Plugin command is already running: \(commandID)")
        }
        guard runs.filter({ $0.state == .running || $0.cleanupPending }).count < 16 else {
            throw RPCFailure(code: -32023, message: "At most 16 plugin commands may run concurrently")
        }
        let encodedParams = try JSONEncoder().encode(params)
        guard encodedParams.count <= 16_384 else { throw RPCFailure(code: -32602, message: "Plugin command parameters exceed 16 KiB") }
        let run = Run(plugin: plugin.id, command: commandID, tab: tab, pane: pane, lifecycle: lifecycle)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-command-\(run.id)")
        var directoryCreated = false
        defer { if directoryCreated { try? FileManager.default.removeItem(at: directory) } }
        let statusFile = directory.appendingPathComponent("exit.json")
        var environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, value in value }
        for key in environment.keys where key.hasPrefix("SLATE_TERM_") { environment.removeValue(forKey: key) }
        environment.merge(controlEnvironment) { _, value in value }
        environment["SLATE_TERM_PLUGIN_ROOT"] = plugin.packageRoot
        environment["SLATE_TERM_PLUGIN_ID"] = plugin.id
        environment["SLATE_TERM_PLUGIN_INSTANCE"] = run.id // Compatibility alias; not a panel-service identity.
        environment["SLATE_TERM_INVOCATION_ID"] = run.id
        environment["SLATE_TERM_COMMAND_ID"] = commandID
        environment["SLATE_TERM_COMMAND_PARAMS"] = String(decoding: encodedParams, as: UTF8.self)
        environment["SLATE_TERM_PLUGIN_SETTINGS"] = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        environment["SLATE_TERM_TAB_ID"] = tab?.description
        environment["SLATE_TERM_PANE_ID"] = pane?.description
        let helperDirectory = URL(fileURLWithPath: connection.cliPath).deletingLastPathComponent().path
        environment["PATH"] = helperDirectory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        try onLifecycle?(record(run, phase: .started), lifecycle)
        while runs.count >= 64, let index = runs.firstIndex(where: { $0.state != .running && !$0.cleanupPending }) { runs.remove(at: index) }
        runs.append(run)
        do {
            try Task.checkCancellation()
            // Publication callbacks cannot grant a retired generation permission to spawn.
            do { try lifecycle.operation.validateCaller() }
            catch { throw CancellationError() }
            try validateTarget()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directoryCreated = true
            let process = try PluginProcess(executable: connection.cliPath,
                arguments: ["_plugin-worker", "--parent-pid", String(getpid()), "--exit-status-file", statusFile.path, command.executable] + command.arguments,
                directory: command.directory.map { URL(fileURLWithPath: $0) }, environment: environment)
            run.process = process
            process.onExit = { [weak self, weak run] status in
                guard let self, let run, run.state == .running else { return }
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
                    if exit.exitCode == 0 { self.finish(run, state: .succeeded, reason: .exit) }
                    else { self.finish(run, state: .failed, reason: exit.signal == nil ? .exit : .signal,
                                       message: "Command exited with \(exit.exitCode.map { "code \($0)" } ?? "signal \(exit.signal!)")") }
                } catch {
                    self.finish(run, state: .failed, reason: .supervisorFailure, message: "Command supervisor exited without a valid exit report: \(status)")
                }
            }
            onChange?()
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(command.timeoutSeconds * 1000)))
            while run.state == .running {
                if ContinuousClock.now >= deadline {
                    finish(run, state: .timedOut, reason: .timeout, message: "Command exceeded \(command.timeoutSeconds) seconds", code: -32024)
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            if run.state == .running {
                finish(run, state: error is CancellationError ? .cancelled : .failed,
                       reason: error is CancellationError ? .cancelled : .spawnFailure, message: String(describing: error),
                       code: (error as? RPCFailure)?.code ?? (error is CancellationError ? -32022 : -32025))
            }
        }
        if let failure = run.failure { throw failure }
        var result = run.info.object!
        result["stdout"] = .string(run.stdout)
        result["stderr"] = .string(run.stderr)
        return .object(result)
    }

    private func record(_ run: Run, phase: CommandLifecycle.Phase, reason: CommandLifecycle.Reason? = nil) -> CommandLifecycle {
        CommandLifecycle(phase: phase, invocationID: run.id, commandID: run.command, tab: run.tab, pane: run.pane,
                         state: run.state, exitCode: run.exit?.exitCode, signal: run.exit?.signal, reason: reason)
    }

    private func finish(_ run: Run, state: CommandLifecycle.State, reason: CommandLifecycle.Reason, message: String? = nil, code: Int = -32025) {
        guard run.state == .running else { return }
        run.state = state // Consume completion before resource cleanup can trigger callbacks.
        if let process = run.process {
            run.stdout = String(decoding: process.stdoutTail, as: UTF8.self)
            run.stderr = String(decoding: process.stderrTail, as: UTF8.self)
            process.close()
            run.cleanup = process.cleanupObservation
            run.process = nil
        }
        run.failure = message.map { RPCFailure(code: code, message: "\($0) (\(run.command), instance \(run.id)); inspect plugins logs; do not blindly retry") }
        do { try onLifecycle?(record(run, phase: .finished, reason: reason), run.lifecycle) }
        catch { NSLog("Command lifecycle publication unavailable: %@", String(describing: error)) }
        onChange?()
    }

    @discardableResult
    func cancelOwned(by owner: ServiceIdentity) -> Task<Bool, Never> {
        let owned = runs.filter { $0.lifecycle.operation.serviceOwner == owner }
        for run in owned {
            finish(run, state: .cancelled, reason: .cancelled, message: "Service generation was retired", code: -32022)
        }
        // Include recently finished jobs whose reaper is still working, not just running jobs.
        // Receipts contain no PIDs and can outlive the process wrapper without risking reuse.
        let receipts = owned.compactMap(\.cleanup)
        return Task {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while receipts.contains(where: { !$0.snapshot.finished }), ContinuousClock.now < deadline {
                // Cleanup is owned by the host, not the lifetime of a requesting socket/task.
                await PluginProcess.yieldForCleanup()
            }
            return receipts.allSatisfy { $0.snapshot.confirmed }
        }
    }

    func remove(plugin: String) {
        for run in runs where run.plugin == plugin { finish(run, state: .cancelled, reason: .unregistered, message: "Plugin was unregistered or replaced", code: -32022) }
        // Keep diagnostic records after unload: callers receive the invocation ID
        // and must still be able to inspect partial output and cancellation state.
    }
    func close() {
        onChange = nil
        for run in runs { finish(run, state: .cancelled, reason: .shutdown, message: "Application is closing", code: -32022) }
        runs.removeAll()
        onLifecycle = nil
    }
}
