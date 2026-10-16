import Darwin
import Foundation
import SlateTermCore
import SlateTermIPC

@main
@MainActor
struct ServiceGenerationTest {
    static let python = ProcessInfo.processInfo.environment["SLATE_TEST_PYTHON"] ?? ""
    struct Failure: Error { let message: String }
    final class GenerationReference { weak var value: BackgroundServiceGeneration? }
    final class ManagerReference { weak var value: BackgroundServices? }
    final class Probe {
        var current = true
        var ready = 0
        var retired = 0
        var failures: [BackgroundServiceGeneration.Failure] = []
        var polling = false
        var cleanupSucceeds = true
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "Condition deadline exceeded")
    }
    static func call(_ connection: PluginControlConnection, _ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await Task.detached {
            try UnixClient(path: connection.socketPath, service: connection.service).call(method, params: params)
        }.value
    }
    static func main() async {
        do { try await run() }
        catch { fputs("FAIL service generation: \(error)\n", stderr); exit(1) }
    }
    static func run() async throws {
        try require(FileManager.default.isExecutableFile(atPath: python), "Run the gate script with SLATE_TEST_PYTHON set to its runtime interpreter")
        let cli = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: "/tmp/slate-generation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let endpointFile = directory.appendingPathComponent("endpoint")
        let identity = try ServiceIdentity(appInstanceID: "app", pluginID: "controller", serviceID: "runtime", generation: "g1")
        let control = try OperationControl(epoch: UUID())
        let audience = CausationAudience.service(epoch: control.epoch, registrationID: identity.pluginID,
            recipient: try ServiceEventRecipient(serviceID: identity.serviceID, generation: identity.generation))
        func make(_ probe: Probe, timeout: Double = 5, exits: Bool = false) throws -> BackgroundServiceGeneration {
            let script = """
            import os,pathlib,time
            assert 'SLATE_TERM_PANE_ID' not in os.environ
            assert 'SLATE_TERM_TAB_ID' not in os.environ
            assert 'SLATE_TERM_SERVICE_TOKEN' not in os.environ
            assert os.environ['SLATE_TERM_SERVICE_PLUGIN_ID']=='controller'
            pathlib.Path(os.environ['TEST_ENDPOINT']).write_text(os.environ['SLATE_TERM_SOCKET'])
            time.sleep(20)
            """
            let spec = try JSONDecoder().decode(PluginProcessSpec.self, from: JSONSerialization.data(withJSONObject: [
                "executable": exits ? "/usr/bin/true" : python, "arguments": exits ? [] : ["-c", script],
                "readyTimeoutSeconds": timeout, "restartLimit": 0,
                "environment": ["TEST_ENDPOINT": endpointFile.path, "SLATE_TERM_PANE_ID": "poison", "SLATE_TERM_TAB_ID": "poison"]
            ]))
            let reference = GenerationReference()
            let generation = try BackgroundServiceGeneration(identity: identity, cliPath: cli, spec: spec,
                isCurrent: { probe.current }, operations: control, request: { method, params, metadata, caller in
                    let operation = try caller.admit(method, metadata: metadata, through: control)
                    try require(operation.serviceOwner == identity, "Endpoint did not stamp generation ownership")
                    if method == "service.ready" {
                        guard params["version"] == .integer(1), let generation = reference.value else { throw Failure(message: "Invalid fixture ready request") }
                        return try generation.acknowledgeReady(operation: operation)
                    }
                    if method == "events.poll", params["waitMilliseconds"] != .integer(0) {
                        probe.polling = true
                        defer { probe.polling = false }
                        try await Task.sleep(for: .seconds(10))
                        try operation.validateCaller()
                    }
                    return .object(["method": .string(method)])
                }, ready: { _ in probe.ready += 1 }, retireOwned: { _ in
                    probe.retired += 1
                    return Task { probe.cleanupSucceeds }
                }, failed: { probe.failures.append($0) })
            reference.value = generation
            return generation
        }
        let probe = Probe()
        let generation = try make(probe)
        defer { generation.close() }
        try generation.start(settings: [:])
        try await wait { (try? String(contentsOf: endpointFile, encoding: .utf8).isEmpty) == false }
        let path = try String(contentsOf: endpointFile, encoding: .utf8)
        let connection = PluginControlConnection(socketPath: path, appInstanceID: identity.appInstanceID, cliPath: cli, service: identity)
        _ = try await call(connection, "workspace.snapshot")
        _ = try await call(connection, "events.poll", ["waitMilliseconds": .integer(0)])
        _ = try await call(connection, "config.get")
        _ = try await Task.detached { try UnixClient(path: path).call("config.get") }.value
        try require(try generation.commandConnection().service == identity, "Starting generation could not delegate with its owner")
        // Other views can exhaust this plugin's budget without blocking readiness/recovery.
        for _ in 0..<20 { _ = try control.admit("command.run", metadata: nil, origin: .service(identity), audience: audience) }
        _ = try await call(connection, "service.ready", ["version": .integer(1), "expectedInstanceId": .string("app")])
        _ = try await call(connection, "service.ready", ["version": .integer(1)])
        try require(probe.ready == 1 && generation.state == .ready, "Readiness was not idempotent")
        try require(try generation.commandConnection().service == identity, "Delegation lost generation")
        let pending = Task { try await call(connection, "events.poll") }
        try await wait { probe.polling }
        do { _ = try await call(connection, "events.poll"); throw Failure(message: "Concurrent generation polls admitted") }
        catch let error as RPCFailure { try require(error.code == -32032, "Wrong concurrent poll error") }
        let firstCleanup = generation.retire()
        let secondCleanup = generation.retire()
        await firstCleanup.value; await secondCleanup.value
        do { _ = try await pending.value; throw Failure(message: "Retired peer returned successfully") }
        catch is Failure { throw Failure(message: "Retired peer returned successfully") }
        catch {}
        try require(generation.cleanupConfirmed && probe.retired == 1 && !probe.polling, "Generation cleanup leaked or duplicated")
        try require(!FileManager.default.fileExists(atPath: path), "Retired endpoint survived")
        do { _ = try await call(connection, "service.ready", ["version": .integer(1)]); throw Failure(message: "Retired endpoint admitted") }
        catch is Failure { throw Failure(message: "Retired endpoint admitted") }
        catch {}

        let timeoutProbe = Probe()
        let timedOut = try make(timeoutProbe, timeout: 0.1)
        defer { timedOut.close() }
        try timedOut.start(settings: [:])
        try await wait { timedOut.state == .retired }
        await timedOut.stop()
        try require(timeoutProbe.failures == [.readinessTimeout] && timeoutProbe.retired == 1, "Ready timeout did not retire once")

        let exitProbe = Probe()
        let exited = try make(exitProbe, exits: true)
        defer { exited.close() }
        try exited.start(settings: [:])
        try await wait { exited.state == .retired }
        await exited.stop()
        try require(exitProbe.failures == [.processExit] && exited.cleanupConfirmed, "Process exit did not clean its generation")

        let uncertainProbe = Probe(); uncertainProbe.cleanupSucceeds = false
        let uncertain = try make(uncertainProbe)
        defer { uncertain.close() }
        try uncertain.start(settings: [:])
        await uncertain.stop()
        try require(!uncertain.cleanupConfirmed, "Unconfirmed owned-job cleanup was reported as complete")
        let closedProbe = Probe()
        let closed = try make(closedProbe)
        try closed.start(settings: [:]); closed.close(); await closed.stop()
        try require(!closed.cleanupConfirmed, "Immediate close fabricated confirmed cleanup")
        try require(closedProbe.retired == 1, "Close followed by stop duplicated ownership retirement")
        try await nestedCommands(cli: cli, directory: directory, identity: identity)
        try await managerLifecycle(cli: cli)
        try await crashThenStop(cli: cli)
        print("PASS window-free service generation: lifecycle-bound readiness, pre-ready API access, poll bounds, budget recovery, retirement, timeout/exit, honest cleanup and live A→CLI→B ownership")
    }

    static func nestedCommands(cli: String, directory: URL, identity: ServiceIdentity) async throws {
        let commands = PluginCommands()
        defer { commands.close() }
        let plugin = try JSONDecoder().decode(PluginRegistration.self, from: JSONSerialization.data(withJSONObject: [
            "id": "tools", "title": "Tools", "commands": [
                ["id": "parent", "title": "Parent", "executable": cli,
                 "arguments": ["rpc", "command.run", "--params", "{\"id\":\"plugin.tools.child\"}"]],
                ["id": "child", "title": "Child", "executable": "/bin/sleep", "arguments": ["20"]]
            ]
        ]))
        let endpointFile = directory.appendingPathComponent("nested-endpoint")
        let script = "import os,pathlib,time; pathlib.Path(os.environ['TEST_ENDPOINT']).write_text(os.environ['SLATE_TERM_SOCKET']); time.sleep(20)"
        let spec = try JSONDecoder().decode(PluginProcessSpec.self, from: JSONSerialization.data(withJSONObject: [
            "executable": python, "arguments": ["-c", script], "readyTimeoutSeconds": 5,
            "environment": ["TEST_ENDPOINT": endpointFile.path]
        ]))
        let control = try OperationControl(epoch: UUID())
        let reference = GenerationReference()
        var owners: [ServiceIdentity] = []
        var terminalFacts = 0
        commands.onLifecycle = { record, context in
            if record.phase == .finished { terminalFacts += 1 }
            try require(context.operation.serviceOwner == identity, "Nested command lost its service owner")
        }
        let generation = try BackgroundServiceGeneration(identity: identity, cliPath: cli, spec: spec,
            isCurrent: { true }, operations: control, request: { method, params, metadata, caller in
                let operation = try caller.admit(method, metadata: metadata, through: control)
                if method == "service.ready" {
                    guard params["version"] == .integer(1), let generation = reference.value else { throw Failure(message: "Invalid nested ready request") }
                    return try generation.acknowledgeReady(operation: operation)
                }
                if let expected = params["expectedInstanceId"], expected != .string(identity.appInstanceID) {
                    throw RPCFailure(code: APIError.conflict, message: "Fixture app changed")
                }
                if method == "api.describe" {
                    return .object(["identityGuards": .bool(true), "guards": .array([.string("expectedInstanceId")]),
                                    "causation": .object(["version": .integer(1)])])
                }
                guard method == "command.run", let id = params["id"]?.string,
                      let command = plugin.commands.first(where: { $0.namespacedID(plugin: plugin.id) == id }),
                      let generation = reference.value, let owner = operation.serviceOwner else {
                    throw RPCFailure(code: -32601, message: "Unknown fixture method or command")
                }
                owners.append(owner)
                return try await commands.execute(plugin: plugin, command: command,
                    connection: generation.commandConnection(), tab: nil, pane: nil, params: [:], settings: [:],
                    lifecycle: CommandLifecycleContext(operation: operation, launchWorkspaceRevision: "fixture", launchLayoutRevision: nil))
            }, ready: { _ in }, retireOwned: { commands.cancelOwned(by: $0) }, failed: { _ in })
        reference.value = generation
        defer { generation.close() }
        try generation.start(settings: [:])
        try await wait { (try? String(contentsOf: endpointFile, encoding: .utf8).isEmpty) == false }
        let connection = PluginControlConnection(socketPath: try String(contentsOf: endpointFile, encoding: .utf8),
            appInstanceID: identity.appInstanceID, cliPath: cli, service: identity)
        _ = try await call(connection, "service.ready", ["version": .integer(1)])
        let invocation = Task { try await call(connection, "command.run", ["id": .string("plugin.tools.parent")]) }
        try await wait { commands.all.filter { $0.object?["state"]?.string == "running" }.count == 2 }
        await generation.stop()
        do { _ = try await invocation.value; throw Failure(message: "Retired nested invocation returned success") }
        catch is Failure { throw Failure(message: "Retired nested invocation returned success") }
        catch {}
        try require(owners == [identity, identity], "A→CLI→B changed service authority")
        try require(terminalFacts == 2 && generation.cleanupConfirmed, "Nested job cleanup/lifecycle was not confirmed exactly once")
        try require(commands.all.allSatisfy { $0.object?["state"]?.string == "cancelled" && $0.object?["cleanupPending"] == .bool(false) },
                    "Nested jobs survived generation retirement")
    }
}
