import Darwin
import Foundation
import SlateTermCore

@main
@MainActor
struct ServiceCommandsTest {
    struct Failure: Error { let message: String }
    final class Lifetime { var alive = true }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func rejects(_ code: Int, _ body: () throws -> Void) throws {
        do { try body() }
        catch let error as RPCFailure { try require(error.code == code, "Unexpected error code: \(error.code)"); return }
        throw Failure(message: "Expected rejection \(code)")
    }
    static func registration(_ commands: [[String: Any]]) throws -> PluginRegistration {
        try JSONDecoder().decode(PluginRegistration.self, from: JSONSerialization.data(withJSONObject: [
            "id": "tools", "title": "Tools", "commands": commands
        ]))
    }
    static func lifecycle(_ operation: WorkspaceOperationContext) -> CommandLifecycleContext {
        CommandLifecycleContext(operation: operation, launchWorkspaceRevision: "test-revision", launchLayoutRevision: nil)
    }
    /// Same command/notification path as header buttons, without opening workspace windows.
    static func checkShortCommandCompletion(connection: PluginControlConnection, directory: URL) async throws {
        let runner = PluginCommands()
        defer { runner.close() }
        let marker = directory.appendingPathComponent("header-target")
        let plugin = try registration([["id": "capture", "title": "Capture Pane Context", "executable": "/bin/sh",
            "arguments": ["-c", "printf '%s/%s' \"$SLATE_TERM_TAB_ID\" \"$SLATE_TERM_PANE_ID\" > \"$MARKER\"; /bin/sleep 1"],
            "environment": ["MARKER": marker.path], "timeoutSeconds": 5]])
        var states: [CommandLifecycle.State] = []
        var busyNotifications: [Bool] = []
        runner.onLifecycle = { record, _ in states.append(record.state) }
        runner.onChange = { [weak runner] in
            busyNotifications.append(runner?.all.contains { $0.object?["state"] == .string("running") } ?? false)
        }
        // Bounded repetition exercises short supervisor exits and re-admission of
        // the same command. A stale running record would leave every header disabled.
        for iteration in 0..<6 {
            states.removeAll(); busyNotifications.removeAll()
            let start = ContinuousClock.now
            let result = try await runner.execute(plugin: plugin, command: plugin.commands[0], connection: connection,
                tab: TabID(1), pane: PaneID(1), params: [:], settings: [:],
                lifecycle: lifecycle(WorkspaceOperationContext(origin: .native)))
            try require(start.duration(to: .now) < .seconds(5), "Short command missed completion deadline at iteration \(iteration)")
            try require(result.object?["state"] == .string("succeeded") && result.object?["exitCode"] == .integer(0), "Short command did not succeed: \(result)")
            try require(states == [.running, .succeeded], "Short command lifecycle was not balanced: \(states)")
            try require(busyNotifications == [true, false], "Header busy-state notifications were stale: \(busyNotifications)")
            try require(try String(contentsOf: marker, encoding: .utf8) == "t1/p1", "Short command lost clicked-pane context")
        }
        print("PASS six header-equivalent short commands: exact context, exit report, lifecycle and busy-state notifications")
    }
    static func checkDeferredTransferLaunch(connection: PluginControlConnection, directory: URL) async throws {
        let runner = PluginCommands()
        defer { runner.close() }
        let marker = directory.appendingPathComponent("stale-launch")
        let plugin = try registration([["id": "deferred", "title": "Deferred", "executable": "/bin/sh",
            "arguments": ["-c", "printf launched > \"$MARKER\"; /bin/sleep 0.1"],
            "environment": ["MARKER": marker.path]]])
        var workspace = Workspace()
        _ = try workspace.newTab()
        let validate = {
            guard (try? workspace.resolvedTab(pane: PaneID(1)).id) == TabID(1) else {
                throw RPCFailure(code: APIError.conflict, message: "Captured target moved")
            }
        }
        // Prepared context becomes stale before execution, including sole-pane tab retirement.
        try workspace.move(PaneID(1), beside: PaneID(2), direction: .right)
        do {
            _ = try await runner.execute(plugin: plugin, command: plugin.commands[0], connection: connection,
                tab: TabID(1), pane: PaneID(1), params: [:], settings: [:],
                lifecycle: lifecycle(.init(origin: .native)), validateTarget: validate)
            throw Failure(message: "Stale prepared command launched")
        } catch let error as RPCFailure { try require(error.code == APIError.conflict, "Wrong deferred rejection") }
        try require(runner.all.isEmpty && !FileManager.default.fileExists(atPath: marker.path), "Stale launch created runtime work")
        // A start-publication callback can change topology before actual spawning.
        workspace = Workspace(); _ = try workspace.newTab()
        runner.onLifecycle = { record, _ in
            if record.phase == .started { try workspace.move(PaneID(1), beside: PaneID(2), direction: .left) }
        }
        do {
            _ = try await runner.execute(plugin: plugin, command: plugin.commands[0], connection: connection,
                tab: TabID(1), pane: PaneID(1), params: [:], settings: [:],
                lifecycle: lifecycle(.init(origin: .native)), validateTarget: validate)
            throw Failure(message: "Post-callback stale command spawned")
        } catch let error as RPCFailure { try require(error.code == APIError.conflict, "Lost pre-spawn conflict") }
        try require(!FileManager.default.fileExists(atPath: marker.path), "Pre-spawn target rejection still launched process")
        // Once launched, movement does not become an ongoing cancellation predicate.
        runner.onLifecycle = nil
        workspace = Workspace(); _ = try workspace.newTab()
        runner.onChange = {
            if runner.all.contains(where: { $0.object?["state"] == .string("running") }) {
                try? workspace.move(PaneID(1), beside: PaneID(2), direction: .right)
            }
        }
        let result = try await runner.execute(plugin: plugin, command: plugin.commands[0], connection: connection,
            tab: TabID(1), pane: PaneID(1), params: [:], settings: [:],
            lifecycle: lifecycle(.init(origin: .native)), validateTarget: validate)
        try require(result.object?["state"] == .string("succeeded"), "Transfer cancelled already-running independent command")
        try require(FileManager.default.fileExists(atPath: marker.path), "Accepted command never spawned")
        runner.onChange = nil
        print("PASS deferred transfer launch: stale prepare, callback-to-spawn barrier, sole-pane closure and already-running survival")
    }

    static func main() async throws {
        let cli = CommandLine.arguments[1]
        let owner = try ServiceIdentity(appInstanceID: "app", pluginID: "controller", serviceID: "runtime", generation: "g1")
        let successor = try ServiceIdentity(appInstanceID: "app", pluginID: "controller", serviceID: "runtime", generation: "g2")
        let root = PluginControlConnection(socketPath: "/tmp/test-admin.sock", appInstanceID: "app", cliPath: cli)
        let delegated = PluginControlConnection(socketPath: "/tmp/test-service.sock", appInstanceID: "app", cliPath: cli, service: owner)
        try rejects(APIError.serviceSessionUnavailable) { _ = try root.commandEnvironment(owner: owner) }
        try rejects(APIError.serviceSessionUnavailable) { _ = try delegated.commandEnvironment(owner: nil) }
        try rejects(APIError.serviceSessionUnavailable) { _ = try delegated.commandEnvironment(owner: successor) }
        let wrongApp = PluginControlConnection(socketPath: "/tmp/test-service.sock", appInstanceID: "other", cliPath: cli, service: owner)
        try rejects(APIError.serviceSessionUnavailable) { _ = try wrongApp.commandEnvironment(owner: owner) }

        let epoch = UUID()
        let control = try OperationControl(epoch: epoch)
        let audience = CausationAudience.service(epoch: epoch, registrationID: owner.pluginID,
            recipient: try ServiceEventRecipient(serviceID: owner.serviceID, generation: owner.generation))
        try rejects(APIError.serviceSessionUnavailable) {
            _ = try control.admit("command.run", metadata: nil, origin: .service(successor), audience: audience)
        }
        let page = CausationAudience.plugin(epoch: epoch, registrationID: owner.pluginID, instanceID: "page", viewID: UUID(), documentGeneration: UUID())
        for _ in 0..<10 {
            _ = try control.admit("command.run", metadata: nil, origin: .plugin(id: owner.pluginID, instance: "page", view: "view"), audience: page)
            _ = try control.admit("command.run", metadata: nil, origin: .service(owner), audience: audience)
        }
        try rejects(-32057) { _ = try control.admit("command.run", metadata: nil, origin: .service(owner), audience: audience) }
        let operation = WorkspaceOperationContext(origin: .service(owner))
        let publication = operation.publication(topic: "host.test", payload: [:])
        let encoded = String(decoding: try JSONEncoder().encode(publication.payload), as: UTF8.self)
        try require(!encoded.contains("token") && !encoded.contains("viewId") && !encoded.contains("instanceId"), "Service origin fabricated view identity or leaked a credential")

        let events = try EventControl(epoch: epoch, operations: control)
        defer { events.close() }
        let cursor = events.head.object!["cursor"]!
        let recipient = try ServiceEventRecipient(serviceID: owner.serviceID, generation: owner.generation)
        try events.publishOperation(EventPublication(topic: "test.private", targetInstanceId: "page", lineage: OperationLineage()))
        try events.publishOperation(EventPublication(topic: "test.own", targetService: recipient, lineage: OperationLineage()))
        let delivery = try await events.poll(["after": cursor, "waitMilliseconds": .integer(0)], audience: audience)
        guard case .array(let delivered) = delivery.object!["events"]! else { throw Failure(message: "Invalid event batch") }
        try require(delivered.count == 1 && delivered[0].object?["topic"]?.string == "test.own", "Service poll leaked page-directed events")
        try require(delivered[0].object?["deliveryContext"]?.string != nil, "Service delivery lost causation")
        let all = try await events.poll(["after": cursor, "waitMilliseconds": .integer(0), "recipient": .string("all")], audience: audience)
        guard case .array(let observed) = all.object!["events"]!, observed.count == 2,
              let reference = observed[0].object?["deliveryContext"]?.string else { throw Failure(message: "Explicit all-recipient query lost events or cause") }
        _ = try control.admit("workspace.snapshot", metadata: RPCMetadata(cause: reference), origin: .service(owner), audience: audience)
        try rejects(-32055) {
            _ = try control.admit("workspace.snapshot", metadata: RPCMetadata(cause: reference), origin: .administrative, audience: control.administrativeAudience)
        }
        let reader = Lifetime()
        let head = events.head.object!["cursor"]!
        let pending = Task { try await events.poll(["after": head, "waitMilliseconds": .integer(2000)], audience: audience, validateCaller: {
            if !reader.alive { throw RPCFailure(code: APIError.serviceSessionUnavailable, message: "Retired reader") }
        }) }
        for _ in 0..<100 {
            if events.head.object?["pendingPolls"] == .integer(1) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(events.head.object?["pendingPolls"] == .integer(1), "Service poll did not suspend")
        reader.alive = false
        try events.publishOperation(EventPublication(topic: "test.wake", lineage: OperationLineage()))
        do { _ = try await pending.value; throw Failure(message: "Retired service reader received delivery") }
        catch let error as RPCFailure { try require(error.code == APIError.serviceSessionUnavailable, "Wrong retired reader error") }
        try require(events.head.object?["pendingPolls"] == .integer(0), "Retired service reader leaked a waiter")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-service-command-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = PluginCommands()
        defer { runner.close() }
        let script = """
        import os
        e=os.environ
        assert e['SLATE_TERM_PLUGIN_ID']=='tools'
        assert e['SLATE_TERM_INSTANCE_ID']=='app'
        if e['SLATE_TERM_COMMAND_ID'].endswith('.owned'):
            assert e['SLATE_TERM_SOCKET']=='/tmp/test-service.sock'
            assert e['SLATE_TERM_SERVICE_PLUGIN_ID']=='controller'
            assert e['SLATE_TERM_SERVICE_GENERATION']=='g1'
            assert 'SLATE_TERM_SERVICE_TOKEN' not in e
        else:
            assert e['SLATE_TERM_SOCKET']=='/tmp/test-admin.sock'
            assert not any(k.startswith('SLATE_TERM_SERVICE_') for k in e)
        print('environment verified')
        """
        let commands: [[String: Any]] = ["owned", "admin"].map { id in
            ["id": id, "title": id, "executable": "/usr/bin/python3", "arguments": ["-c", script],
             "environment": ["SLATE_TERM_SERVICE_TOKEN": "poison", "SLATE_TERM_SERVICE_PLUGIN_ID": "attacker", "SLATE_TERM_SOCKET": "/bad"]]
        }
        let plugin = try registration(commands)
        for (index, connection, context) in [(0, delegated, operation), (1, root, WorkspaceOperationContext(origin: .administrative))] {
            let result = try await runner.execute(plugin: plugin, command: plugin.commands[index], connection: connection,
                tab: nil, pane: nil, params: [:], settings: [:], lifecycle: lifecycle(context))
            try require(result.object?["stdout"]?.string == "environment verified\n", "Command ownership environment was incorrect")
        }
        try await checkShortCommandCompletion(connection: root, directory: directory)
        try await checkDeferredTransferLaunch(connection: root, directory: directory)
        // Even a missing host resolver cannot accidentally launch service work with the admin socket.
        do {
            _ = try await runner.execute(plugin: plugin, command: plugin.commands[1], connection: root,
                tab: nil, pane: nil, params: [:], settings: [:], lifecycle: lifecycle(operation))
            throw Failure(message: "Service command used administrative connection")
        } catch let error as RPCFailure { try require(error.code == APIError.serviceSessionUnavailable, "Wrong delegation rejection") }

        let lifetime = Lifetime()
        var finished = 0
        let retired = WorkspaceOperationContext(origin: .service(owner), validateCaller: {
            if !lifetime.alive { throw RPCFailure(code: APIError.serviceSessionUnavailable, message: "Retired") }
        })
        runner.onLifecycle = { record, _ in
            if record.phase == .started { lifetime.alive = false }
            else { finished += 1 }
        }
        do {
            _ = try await runner.execute(plugin: plugin, command: plugin.commands[0], connection: delegated,
                tab: nil, pane: nil, params: [:], settings: [:], lifecycle: lifecycle(retired))
            throw Failure(message: "Retired caller launched a command")
        } catch let error as RPCFailure { try require(error.code == -32022, "Wrong post-admission retirement error") }
        try require(finished == 1, "Retirement did not finish exactly once")
        runner.onLifecycle = nil

        // An administrator may follow a service event without inheriting its ownership.
        try events.publishOperation(operation.publication(topic: "test.shared", payload: [:]))
        let cause = try control.deliveryContext(cursor: events.head.object!["cursor"]!.string!,
            lineage: operation.lineage, audience: control.administrativeAudience)
        let administrative = try control.admit("command.run", metadata: RPCMetadata(cause: cause),
            origin: .administrative, audience: control.administrativeAudience)
        try require(administrative.serviceOwner == nil && administrative.lineage.rootOperationID == operation.lineage.rootOperationID,
                    "Causation incorrectly transferred service ownership")
        let pidFiles = ["owned-sleep", "admin-sleep"].map { directory.appendingPathComponent($0) }
        let sleepers = try registration(["owned-sleep", "admin-sleep"].enumerated().map { index, id in
            ["id": id, "title": id, "executable": "/bin/sh",
             "arguments": ["-c", "/bin/sleep 20 & child=$!; printf '%s %s' \"$$\" \"$child\" >\"$1.tmp\"; /bin/mv \"$1.tmp\" \"$1\"; wait", "fixture", pidFiles[index].path]]
        })
        let owned = Task { try await runner.execute(plugin: sleepers, command: sleepers.commands[0], connection: delegated,
            tab: nil, pane: nil, params: [:], settings: [:], lifecycle: lifecycle(operation)) }
        let admin = Task { try await runner.execute(plugin: sleepers, command: sleepers.commands[1], connection: root,
            tab: nil, pane: nil, params: [:], settings: [:], lifecycle: lifecycle(administrative)) }
        defer { owned.cancel(); admin.cancel() }
        for _ in 0..<200 {
            if runner.all.filter({ $0.object?["state"]?.string == "running" }).count == 2,
               pidFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(runner.all.filter { $0.object?["state"]?.string == "running" }.count == 2, "Owned jobs did not start")
        let pids = try pidFiles.map { url in
            try String(contentsOf: url, encoding: .utf8).split(separator: " ").compactMap { Int32($0) }
        }
        try require(pids.allSatisfy { $0.count == 2 && $0.allSatisfy { $0 > 1 } }, "Missing owned child/descendant PIDs")
        runner.cancelOwned(by: successor)
        try require(runner.all.filter { $0.object?["state"]?.string == "running" }.count == 2, "Successor cancelled predecessor's jobs")
        let cleanup = runner.cancelOwned(by: owner)
        cleanup.cancel() // A disconnected requester must not abandon owned cleanup.
        let cleaned = await cleanup.value
        try require(cleaned, "Owned command cleanup was not confirmed")
        do { _ = try await owned.value; throw Failure(message: "Owned command survived retirement") }
        catch let error as RPCFailure { try require(error.code == -32022, "Wrong owner cancellation error") }
        try require(runner.all.filter { $0.object?["state"]?.string == "running" }.count == 1, "Retirement cancelled unrelated administrative work")
        for _ in 0..<200 {
            if pids[0].allSatisfy({ kill($0, 0) == -1 && errno == ESRCH }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(pids[0].allSatisfy { kill($0, 0) == -1 && errno == ESRCH }, "Owned command descendants survived retirement")
        try require(pids[1].allSatisfy { kill($0, 0) == 0 }, "Unrelated command descendants were terminated")
        admin.cancel()
        _ = try? await admin.value
        print("PASS service-owned commands: isolated/retired event readers, bound environment, no admin fallback, shared plugin budget, post-admission retirement and generation-specific descendant cleanup")
    }
}
