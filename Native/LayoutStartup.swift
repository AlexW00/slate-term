import Foundation
import SlateTermCore

/// Starts commands only after the new shell reports an authenticated idle prompt.
/// Pane/session ownership prevents delayed work from reaching a replacement terminal.
@MainActor
final class LayoutStartup {
    private struct Pending {
        let session: String
        let command: String
        let operation: WorkspaceOperationContext
        var state: String
        var message: String?
        var task: Task<Void, Never>?
    }
    private var pending: [PaneID: Pending] = [:]
    var run: ((PaneID, String, String) async throws -> JSONValue)?
    var failed: ((PaneID, String, WorkspaceOperationContext) -> Void)?
    var status: JSONValue {
        .array(pending.keys.sorted { $0.description < $1.description }.map { pane in
            let item = pending[pane]!
            return .object(["paneId": .string(pane.description), "sessionId": .string(item.session),
                            "state": .string(item.state), "message": item.message.map(JSONValue.string) ?? .null])
        })
    }
    func enqueue(pane: PaneID, session: String, command: String, operation: WorkspaceOperationContext) {
        pending[pane]?.task?.cancel()
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.pending[pane]?.session == session, self.pending[pane]?.state == "waitingForPrompt" else { return }
            self.fail(pane, message: "Startup command was not run: no authenticated shell prompt arrived within 30 seconds.")
        }
        // Keep attribution, not the initiating caller's liveness closure. This work is now session-owned.
        let attribution = WorkspaceOperationContext(origin: operation.origin, lineage: operation.lineage)
        pending[pane] = Pending(session: session, command: command, operation: attribution, state: "waitingForPrompt", task: timer)
    }
    func observe(pane: PaneID, session: String, report: ShellReport) {
        guard let item = pending[pane], item.session == session else { return }
        if item.state == "starting", report.state == .running, report.command.map(ShellKind.isRunMarker) == true {
            pending[pane]?.state = "running"
        }
        guard item.state == "waitingForPrompt", report.state == .prompt else { return }
        pending[pane]?.task?.cancel()
        pending[pane]?.state = "starting"
        pending[pane]?.task = Task { [weak self] in
            guard let self, let run = self.run else { return }
            do {
                let result = try await run(pane, session, item.command)
                guard self.pending[pane]?.session == session else { return }
                if case .integer(let code) = result.object?["exitCode"], code != 0 {
                    self.fail(pane, message: "Startup command exited with status \(code).")
                } else { self.pending[pane]?.state = "finished" }
            } catch is CancellationError { return }
            catch {
                guard self.pending[pane]?.session == session else { return }
                if let error = error as? RPCFailure, error.code == -32024 {
                    self.pending[pane]?.state = "completionUnobserved"
                    self.pending[pane]?.message = "Completion tracking expired; the command was not stopped or retried."
                } else { self.fail(pane, message: "Startup command failed: \(layoutErrorText(error))") }
            }
            self.pending[pane]?.task = nil
        }
    }
    private func fail(_ pane: PaneID, message: String) {
        pending[pane]?.state = "failed"; pending[pane]?.message = message
        if let operation = pending[pane]?.operation { failed?(pane, message, operation) }
    }
    func retain(_ sessions: [PaneID: String]) {
        for pane in Array(pending.keys) where sessions[pane] != pending[pane]?.session {
            pending.removeValue(forKey: pane)?.task?.cancel()
        }
    }
    func close() { pending.values.forEach { $0.task?.cancel() }; pending.removeAll() }
}
