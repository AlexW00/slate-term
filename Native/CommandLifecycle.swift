import Foundation
import SlateTermCore

extension WorkspaceHost {
    func publishCommandLifecycle(_ record: CommandLifecycle, context: CommandLifecycleContext) throws {
        let tab = record.tab.flatMap { id in workspace.tabs.first { $0.id == id } }
        let available = tab.map { tab in record.pane.map { tab.layout.paneIDs.contains($0) } ?? true } ?? false
        let layout = available ? record.tab.flatMap(revisions.layoutRevision) : nil
        let fields: [String: JSONValue] = [
            "actionKind": .string(record.commandID), "invocationId": .string(record.invocationID), "commandId": .string(record.commandID),
            "state": .string(record.state.rawValue), "exitCode": record.exitCode.map(JSONValue.integer) ?? .null,
            "signal": record.signal.map(JSONValue.integer) ?? .null, "terminationReason": record.reason.map { .string($0.rawValue) } ?? .null,
            "paneId": record.pane.map { .string($0.description) } ?? .null, "tabId": record.tab.map { .string($0.description) } ?? .null,
            "targetAvailable": record.tab == nil && record.pane == nil ? .null : .bool(available),
            "beforeWorkspaceRevision": .string(revisions.revision), "workspaceRevision": .string(revisions.revision),
            "beforeLayoutRevision": layout.map(JSONValue.string) ?? .null, "layoutRevision": layout.map(JSONValue.string) ?? .null,
            "launchWorkspaceRevision": .string(context.launchWorkspaceRevision),
            "launchLayoutRevision": context.launchLayoutRevision.map(JSONValue.string) ?? .null
        ]
        // This is a fact about an admitted job, including cancellation after its caller
        // retires. Do not revalidate the caller or re-derive an expired reference here.
        try events.publishOperation(context.operation.publication(topic: "host.command.\(record.phase.rawValue)", payload: fields,
                                                                  tab: record.tab, pane: record.pane))
    }
}
