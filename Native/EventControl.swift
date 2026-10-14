import Foundation
import SlateTermCore

/// The transport boundary chooses source/recipient identities; callers cannot supply them.
@MainActor
final class EventControl {
    private let hub: EventHub

    init(epoch: UUID) throws { hub = try EventHub(epoch: epoch) }
    var head: JSONValue {
        .object(["cursor": .string(hub.cursor), "pendingPolls": .integer(hub.pendingCount)])
    }
    func close() { hub.close() }

    func poll(_ params: [String: JSONValue], boundTab: TabID? = nil,
              recipientInstanceId: String? = nil) async throws -> JSONValue {
        do {
            try Self.checkKeys(params, allowed: ["after", "topics", "tab", "pane", "limit", "waitMilliseconds"])
            let after = try Self.string("after", in: params)
            let tab = try Self.string("tab", in: params).map { try TabID(parsing: $0) }
            let pane = try Self.string("pane", in: params).map { try PaneID(parsing: $0) }
            if let boundTab, let tab, boundTab != tab {
                throw RPCFailure(code: -32602, message: "This plugin's subscriptions are scoped to its owning tab")
            }
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
            let filter = try EventFilter(topics: topics, tab: boundTab ?? tab, pane: pane, recipientInstanceId: recipientInstanceId)
            let batch = try await hub.poll(after: after, filter: filter,
                limit: Self.integer("limit", in: params, default: 128),
                waitMilliseconds: Self.integer("waitMilliseconds", in: params, default: 20_000))
            return try .encoding(batch)
        } catch { throw Self.failure(error) }
    }

    func emit(_ params: [String: JSONValue], source: EventSource,
              sourceTab: TabID? = nil, sourcePane: PaneID? = nil,
              knownInstances: Set<String>) throws -> JSONValue {
        do {
            let client = source == .client
            try Self.checkKeys(params, allowed: client
                ? ["topic", "payload", "tab", "pane", "targetInstanceId"]
                : ["topic", "payload", "targetInstanceId"])
            guard let topic = try Self.string("topic", in: params) else {
                throw RPCFailure(code: -32602, message: "topic is required")
            }
            let tab = try Self.string("tab", in: params).map { try TabID(parsing: $0) } ?? sourceTab
            let pane = try Self.string("pane", in: params).map { try PaneID(parsing: $0) } ?? sourcePane
            let target = try Self.string("targetInstanceId", in: params)
            if let target, !knownInstances.contains(target) {
                throw RPCFailure(code: -32602, message: "targetInstanceId must identify a live plugin instance")
            }
            return try .encoding(hub.publish(topic: topic, payload: params["payload"] ?? .null,
                source: source, tab: tab, pane: pane, targetInstanceId: target))
        } catch { throw Self.failure(error) }
    }

    func publishHost(_ topic: String, payload: JSONValue = .null, tab: TabID? = nil,
                     pane: PaneID? = nil, targetInstanceId: String? = nil) {
        do {
            try hub.publish(topic: topic, payload: payload, source: .host,
                            tab: tab, pane: pane, targetInstanceId: targetInstanceId)
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
