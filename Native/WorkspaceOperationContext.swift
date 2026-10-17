import Foundation
import SlateTermCore

/// Assigned by adapters, never decoded from request fields or inferred from process environment.
struct WorkspaceOperationContext: Sendable {
    enum Origin: Sendable {
        case native, administrative
        case plugin(id: String, instance: String, view: String)
        case service(ServiceIdentity)

        var value: JSONValue {
            switch self {
            case .native: .object(["kind": .string("native")])
            case .administrative: .object(["kind": .string("administrative")])
            case .plugin(let id, let instance, let view):
                .object(["kind": .string("plugin"), "pluginId": .string(id), "instanceId": .string(instance), "viewId": .string(view)])
            case .service(let owner):
                .object(["kind": .string("service"), "pluginId": .string(owner.pluginID),
                         "serviceId": .string(owner.serviceID), "generation": .string(owner.generation)])
            }
        }
    }
    let origin: Origin
    let lineage: OperationLineage
    /// Self-declared agent identity for presence display. Never used for admission or routing.
    let actor: PresenceActor?
    let validateCaller: @MainActor @Sendable () throws -> Void

    /// Ownership comes from the authenticated adapter, not causation, target command or environment.
    var serviceOwner: ServiceIdentity? {
        if case .service(let identity) = origin { identity } else { nil }
    }

    nonisolated init(origin: Origin, lineage: OperationLineage = OperationLineage(), actor: PresenceActor? = nil,
                     validateCaller: @escaping @MainActor @Sendable () throws -> Void = {}) {
        self.origin = origin
        self.lineage = lineage
        self.actor = actor
        self.validateCaller = validateCaller
    }

    func publication(_ change: WorkspaceChange) -> EventPublication {
        publication(topic: change.topic, payload: change.payload, tab: change.tab, pane: change.pane)
    }

    func publication(topic: String, payload fields: [String: JSONValue], tab: TabID? = nil, pane: PaneID? = nil) -> EventPublication {
        var payload = fields
        payload["operationId"] = .string(lineage.operationID.uuidString)
        payload["origin"] = origin.value
        payload["causalDepth"] = .integer(lineage.depth)
        if let parent = lineage.parentOperationID { payload["parentOperationId"] = .string(parent.uuidString) }
        // Never serialize the private root lineage or delivery audience. Settings and other
        // private domains need their own audience-safe projections, not this workspace helper.
        return EventPublication(topic: topic, payload: .object(payload), source: .host,
                                tab: tab, pane: pane, lineage: lineage)
    }
}
