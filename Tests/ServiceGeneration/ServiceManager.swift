import Foundation
import SlateTermCore

extension ServiceGenerationTest {
    static func managerLifecycle(cli: String) async throws {
        let script = "import os,subprocess,time; subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc','service.ready','--params','{\"version\":1}'],check=True); print('service-output',flush=True); time.sleep(20)"
        let registration = try JSONDecoder().decode(PluginRegistration.self, from: JSONSerialization.data(withJSONObject: [
            "id": "managed", "title": "Managed", "service": ["executable": "/usr/bin/python3", "arguments": ["-c", script], "readyTimeoutSeconds": 5]
        ]))
        var catalog = [registration]
        var rejectPublication = true
        var confirmCleanup = true
        var states: [String] = []
        let control = try OperationControl(epoch: UUID())
        let manager = BackgroundServices(appID: "app", cliPath: cli, operations: control,
            registrations: { catalog }, settings: { _ in [:] }, request: { method, _, _ in
                guard method == "api.describe" else { throw Failure(message: "Unexpected manager fixture request") }
                return .object(["identityGuards": .bool(true), "guards": .array([.string("expectedInstanceId")])])
            }, publish: { fields, _, commit in
                if rejectPublication { throw Failure(message: "Rejected publication") }
                commit(); states.append(fields["state"]!.string!)
            }, retireOwned: { _ in let confirmed = confirmCleanup; return Task { confirmed } })
        defer { manager.close() }
        let operation = WorkspaceOperationContext(origin: .administrative)
        do { _ = try manager.start("managed", operation: operation); throw Failure(message: "Preflight did not reject") }
        catch let error as Failure { try require(error.message == "Rejected publication", "Wrong preflight failure") }
        try require(try manager.status("managed").object?["state"] == .string("stopped"), "Failed publication changed service state")
        rejectPublication = false
        let first = try manager.start("managed", operation: operation)
        try require(first.object?["generation"] == manager.start("managed", operation: operation).object?["generation"], "Duplicate start launched a successor")
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
}
