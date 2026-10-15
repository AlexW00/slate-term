import Foundation
import SlateTermCore

/// The transport stamps source identity and causation audience. Recipient selection
/// is a shared query option, independent of the caller's provenance.
@MainActor
final class EventControl {
    private let hub: EventHub
    private let operations: OperationControl

    init(epoch: UUID, operations: OperationControl) throws {
        self.operations = operations
        hub = try EventHub(epoch: epoch, reservedDeliveryBytes: EventJournal.maximumDeliveryMetadataBytes)
    }
    var head: JSONValue {
        .object(["cursor": .string(hub.cursor), "pendingPolls": .integer(hub.pendingCount)])
    }
    func close() { hub.close() }

    /// Workspace values and their prepared journal are assigned without suspension. Do not
    /// place renderer callbacks, persistence or other fallible work in updatingModel.
    func commitWorkspace(_ publications: [EventPublication], beforeCommit: () throws -> Void = {}, updatingModel: () -> Void) throws {
        do {
            let prepared = try hub.prepare(publications)
            try hub.commit(prepared, preparingEffects: beforeCommit, updatingModel: updatingModel)
        } catch { throw Self.failure(error) }
    }

    /// Bounds/encoding preflight only; external effects do not hold a journal cursor
    /// reservation. Final observed facts are prepared again without suspension.
    func preflight(_ publications: [EventPublication]) throws {
        do { _ = try hub.prepare(publications) }
        catch { throw Self.failure(error) }
    }

    func publishOperation(_ publication: EventPublication) throws {
        try commitWorkspace([publication], updatingModel: {})
    }

    func poll(_ params: [String: JSONValue], audience: CausationAudience, boundTab: TabID? = nil,
              validateCaller: @MainActor () throws -> Void = {}) async throws -> JSONValue {
        do {
            try Self.checkKeys(params, allowed: ["after", "topics", "tab", "pane", "scope", "recipient", "limit", "waitMilliseconds"])
            let after = try Self.string("after", in: params)
            let tab = try Self.string("tab", in: params).map { try TabID(parsing: $0) }
            let pane = try Self.string("pane", in: params).map { try PaneID(parsing: $0) }
            let scope = try Self.string("scope", in: params)
            guard scope == nil || scope == "global" || scope == "tab" else { throw RPCFailure(code: -32602, message: "Event scope must be global or tab") }
            let selectedTab = tab ?? (scope == "global" || pane != nil ? nil : boundTab)
            if scope == "tab", selectedTab == nil { throw RPCFailure(code: -32602, message: "Tab scope requires a tab") }
            var topics: [String] = []
            if let value = params["topics"] {
                guard case .array(let values) = value, values.count <= 64 else {
                    throw RPCFailure(code: -32602, message: "topics must be an array of at most 64 topic patterns")
                }
                topics = try values.map {
                    guard let value = $0.string else { throw RPCFailure(code: -32602, message: "Each topic pattern must be a string") }
                    return value
                }
            }
            let defaultObserver: EventObserver
            switch audience {
            case .administrative: defaultObserver = .administrator
            case .plugin(_, _, let instance, _, _): defaultObserver = .plugin(instanceID: instance)
            case .service(_, _, let recipient): defaultObserver = .service(recipient)
            }
            let observer = try EventObserver.selecting(params["recipient"], default: defaultObserver)
            let filter = try EventFilter(topics: topics, tab: selectedTab, pane: pane, observer: observer)
            let delivery = try await hub.pollDelivery(after: after, filter: filter,
                limit: Self.integer("limit", in: params, default: 128),
                waitMilliseconds: Self.integer("waitMilliseconds", in: params, default: 20_000))
            try Task.checkCancellation()
            try validateCaller()
            let events = try delivery.batch.events.map { event in
                var fields = try JSONValue.encoding(event).object!
                if let lineage = delivery.lineages[event.cursor] {
                    fields["deliveryContext"] = .string(try operations.deliveryContext(cursor: event.cursor, lineage: lineage, audience: audience))
                }
                return JSONValue.object(fields)
            }
            return .object(["cursor": .string(delivery.batch.cursor), "events": .array(events)])
        } catch { throw Self.failure(error) }
    }

    func emit(_ params: [String: JSONValue], source: EventSource, operation: WorkspaceOperationContext,
              sourceTab: TabID? = nil, sourcePane: PaneID? = nil,
              knownInstances: Set<String>, knownServices: Set<ServiceEventRecipient> = []) throws -> JSONValue {
        do {
            try Self.checkKeys(params, allowed: ["topic", "payload", "tab", "pane", "targetInstanceId", "targetService"])
            guard let topic = try Self.string("topic", in: params) else {
                throw RPCFailure(code: -32602, message: "topic is required")
            }
            let tab = try Self.string("tab", in: params).map { try TabID(parsing: $0) } ?? sourceTab
            let pane = try Self.string("pane", in: params).map { try PaneID(parsing: $0) } ?? sourcePane
            let target = try Self.string("targetInstanceId", in: params)
            if let target, !knownInstances.contains(target) {
                throw RPCFailure(code: -32602, message: "targetInstanceId must identify a live plugin instance")
            }
            var service: ServiceEventRecipient?
            if let value = params["targetService"] {
                guard target == nil, case .service(let recipient) = try EventObserver.selecting(value, default: .administrator),
                      knownServices.contains(recipient) else {
                    throw RPCFailure(code: -32602, message: "targetService must identify one live generation and excludes targetInstanceId")
                }
                service = recipient
            }
            return try .encoding(hub.publish(topic: topic, payload: params["payload"] ?? .null,
                source: source, tab: tab, pane: pane, targetInstanceId: target, targetService: service, lineage: operation.lineage))
        } catch { throw Self.failure(error) }
    }

    func publishHost(_ topic: String, payload: JSONValue = .null, tab: TabID? = nil,
                     pane: PaneID? = nil, targetInstanceId: String? = nil, lineage: OperationLineage? = nil) {
        do {
            try hub.publish(topic: topic, payload: payload, source: .host,
                            tab: tab, pane: pane, targetInstanceId: targetInstanceId, lineage: lineage ?? OperationLineage())
        } catch EventHubError.closed {
            // Shutdown can close the journal before already-owned native callbacks finish.
        } catch { NSLog("Host event publication failed: %@", String(describing: error)) }
    }

    private static func string(_ key: String, in params: [String: JSONValue]) throws -> String? {
        guard let value = params[key] else { return nil }
        guard let string = value.string else { throw RPCFailure(code: -32602, message: "\(key) must be a string") }
        return string
    }
    private static func integer(_ key: String, in params: [String: JSONValue], default fallback: Int) throws -> Int {
        guard let value = params[key] else { return fallback }
        guard case .integer(let number) = value else { throw RPCFailure(code: -32602, message: "\(key) must be an integer") }
        return number
    }
    private static func checkKeys(_ params: [String: JSONValue], allowed: Set<String>) throws {
        if let key = params.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw RPCFailure(code: -32602, message: "Unknown event parameter: \(key)")
        }
    }
    private static func failure(_ error: any Error) -> any Error {
        if let failure = error as? RPCFailure { return failure }
        if error is CancellationError { return error }
        if let error = error as? EventJournalError {
            switch error {
            case .epochMismatch, .expiredCursor:
                return RPCFailure(code: -32031, message: "Event history is unavailable; resync workspace/context and obtain a new cursor from events.head (\(error))")
            default: return RPCFailure(code: -32602, message: boundedDescription(error))
            }
        }
        if let error = error as? EventHubError {
            let code: Int
            switch error {
            case .closed: code = -32022
            case .preparationConflict: code = APIError.conflict
            case .invalidTimeout: code = -32602
            case .overloaded: code = -32032
            }
            return RPCFailure(code: code, message: error.localizedDescription)
        }
        return RPCFailure(code: -32602, message: boundedDescription(error))
    }
    private static func boundedDescription(_ error: any Error) -> String {
        String(decoding: String(describing: error).utf8.prefix(2_048), as: UTF8.self)
    }
}
