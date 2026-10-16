import Foundation
import SlateTermCore

extension ServiceGenerationTest {
    static func managerLifecycle(cli: String) async throws {
        let script = "import os,subprocess,time; subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc','service.ready','--params','{\"version\":1}'],check=True); print('service-output',flush=True); time.sleep(20)"
        let registration = try JSONDecoder().decode(PluginRegistration.self, from: JSONSerialization.data(withJSONObject: [
            "id": "managed", "title": "Managed", "service": ["executable": python, "arguments": ["-c", script], "readyTimeoutSeconds": 5]
        ]))
        var catalog = [registration]
        var rejectPublication = true
        var confirmCleanup = true
        var states: [String] = []
        let control = try OperationControl(epoch: UUID())
        let reference = ManagerReference()
        let manager = BackgroundServices(appID: "app", cliPath: cli, operations: control,
            registrations: { catalog }, settings: { _ in [:] }, request: { method, params, metadata, caller in
                let operation = try caller.admit(method, metadata: metadata, through: control)
                if method == "service.ready", let manager = reference.value {
                    return try manager.acknowledgeReady(params.filter { $0.key != "expectedInstanceId" }, defaultOwner: operation.serviceOwner, operation: operation)
                }
                guard method == "api.describe" else { throw Failure(message: "Unexpected manager fixture request") }
                return .object(["identityGuards": .bool(true), "guards": .array([.string("expectedInstanceId")])])
            }, publish: { fields, _, commit in
                if rejectPublication { throw Failure(message: "Rejected publication") }
                commit(); states.append(fields["state"]!.string!)
            }, retireOwned: { _ in let confirmed = confirmCleanup; return Task { confirmed } })
        reference.value = manager
        defer { manager.close() }
        let operation = WorkspaceOperationContext(origin: .plugin(id: "trusted", instance: "page", view: "view"))
        do { _ = try manager.start("managed", operation: operation); throw Failure(message: "Preflight did not reject") }
        catch let error as Failure { try require(error.message == "Rejected publication", "Wrong preflight failure") }
        try require(try manager.status("managed").object?["state"] == .string("stopped"), "Failed publication changed service state")
        rejectPublication = false
        let first = try manager.start("managed", operation: operation)
        try require(first.object?["generation"] == manager.start("managed", operation: operation).object?["generation"], "Duplicate start launched a successor")
        let selector: [String: JSONValue] = ["version": .integer(1), "serviceId": first.object!["serviceId"]!, "generation": first.object!["generation"]!]
        _ = try manager.acknowledgeReady(selector, defaultOwner: nil, operation: operation)
        var stale = selector; stale["generation"] = .string("stale")
        do { _ = try manager.acknowledgeReady(stale, defaultOwner: nil, operation: operation); throw Failure(message: "Stale explicit generation acknowledged") }
        catch let error as RPCFailure { try require(error.code == APIError.serviceSessionUnavailable, "Wrong stale readiness error") }
        try await wait { (try? manager.status("managed").object?["state"]) == .string("ready") }
        try require(manager.recipients.count == 1, "Live service missing settings recipient")
        let stopped = try await manager.stop("managed", operation: operation)
        try require(stopped.object?["state"] == .string("stopped") && stopped.object?["cleanupConfirmed"] == .bool(true), "Stop did not confirm cleanup")
        try require(manager.recipients.isEmpty, "Retired settings recipient survived")
        let second = try manager.start("managed", operation: operation)
        try require(second.object?["generation"] != first.object?["generation"], "Fresh start reused generation")
        catalog = []
        manager.remove("managed", operation: operation)
        catalog = [registration]
        do { _ = try manager.start("managed", operation: operation); throw Failure(message: "Replacement overlapped cleanup") }
        catch let error as RPCFailure { try require(error.code == APIError.conflict, "Wrong replacement error") }
        // The old reservation retires asynchronously; retry only explicit failed preflight,
        // never replay an accepted launch or an unknown transport outcome.
        var third: JSONValue?
        for _ in 0..<200 {
            do { third = try manager.start("managed", operation: operation); break }
            catch let error as RPCFailure where error.code == APIError.conflict { try await Task.sleep(for: .milliseconds(10)) }
        }
        try require(third != nil, "Confirmed replacement cleanup did not release reservation")
        confirmCleanup = false
        let uncertain = try await manager.stop("managed", operation: operation)
        try require(uncertain.object?["state"] == .string("failed") && uncertain.object?["cleanupConfirmed"] == .bool(false), "Unconfirmed cleanup was treated as stopped")
        let repeatedStop = try await manager.stop("managed", operation: operation)
        try require(repeatedStop.object?["state"] == .string("failed") && repeatedStop.object?["reason"] == .string("cleanupUnconfirmed"), "Repeated stop fabricated pending cleanup")
        do { _ = try manager.start("managed", operation: operation); throw Failure(message: "Unknown cleanup released capacity") }
        catch let error as RPCFailure { try require(error.code == APIError.conflict, "Wrong uncertain-cleanup error") }
        try require(states.contains("ready") && states.contains("stopping"), "Lifecycle facts missing")
        print("PASS manual service manager: publication preflight, idempotent/fresh starts, readiness, replacement reservation, stop and uncertain cleanup")
    }

    /// A stop that arrives while crash cleanup is still running must keep the crash as the final reason.
    static func crashThenStop(cli: String) async throws {
        final class Gate { var open = false }
        let registration = try JSONDecoder().decode(PluginRegistration.self, from: JSONSerialization.data(withJSONObject: [
            "id": "crashing", "title": "Crashing", "service": ["executable": "/usr/bin/true", "arguments": [], "readyTimeoutSeconds": 5]
        ]))
        let gate = Gate()
        let control = try OperationControl(epoch: UUID())
        let manager = BackgroundServices(appID: "app", cliPath: cli, operations: control,
            registrations: { [registration] }, settings: { _ in [:] }, request: { _, _, _, _ in
                throw Failure(message: "Unexpected crash fixture request")
            }, publish: { _, _, commit in commit() },
            retireOwned: { _ in Task { while !gate.open { try? await Task.sleep(for: .milliseconds(5)) }; return true } })
        defer { manager.close() }
        let operation = WorkspaceOperationContext(origin: .plugin(id: "trusted", instance: "page", view: "view"))
        _ = try manager.start("crashing", operation: operation)
        try await wait { (try? manager.status("crashing").object?["reason"]) == .string("processExit") }
        try require(try manager.status("crashing").object?["state"] == .string("stopping"), "Crash cleanup finished before the stop")
        let stop = Task { try await manager.stop("crashing", operation: operation) }
        try await Task.sleep(for: .milliseconds(20))
        gate.open = true
        let stopped = try await stop.value
        try require(stopped.object?["state"] == .string("failed") && stopped.object?["reason"] == .string("processExit"),
            "Stop during crash cleanup reported \(stopped)")
        print("PASS manual service manager: stop during crash cleanup keeps the crash reason")
    }
}
