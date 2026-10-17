import Foundation
import SlateTermCore

/// Manual, session-only service control. No startup activation or automatic retry.
@MainActor
final class BackgroundServices {
    typealias Publish = ([String: JSONValue], WorkspaceOperationContext, () -> Void) throws -> Void
    private final class Entry {
        let registration: PluginRegistration
        let id = UUID().uuidString
        var generation: BackgroundServiceGeneration?
        var state = "stopped"
        var reason = "notStarted"
        var retirement: Task<Void, Never>?
        var finishRequest: (state: String, reason: String, operation: WorkspaceOperationContext)?
        init(_ registration: PluginRegistration) { self.registration = registration }
    }
    private let appID: String
    private let cliPath: String
    private let operations: OperationControl
    private let registrations: () -> [PluginRegistration]
    private let settings: (String) -> [String: JSONValue]
    private let request: BackgroundServiceGeneration.Request
    private let publish: Publish
    private let retireOwned: (ServiceIdentity) -> Task<Bool, Never>
    private var entries: [String: Entry] = [:]
    // Includes detached/replaced registrations until cleanup is positively confirmed.
    private var reservations: [String: BackgroundServiceGeneration] = [:]
    private var closed = false

    init(appID: String, cliPath: String, operations: OperationControl,
         registrations: @escaping () -> [PluginRegistration], settings: @escaping (String) -> [String: JSONValue],
         request: @escaping BackgroundServiceGeneration.Request, publish: @escaping Publish,
         retireOwned: @escaping (ServiceIdentity) -> Task<Bool, Never>) {
        self.appID = appID; self.cliPath = cliPath; self.operations = operations
        self.registrations = registrations; self.settings = settings; self.request = request
        self.publish = publish; self.retireOwned = retireOwned
    }

    var recipients: [(plugin: String, target: ServiceEventRecipient)] {
        entries.values.compactMap { entry in
            guard let generation = entry.generation, generation.state != .retired,
                  registrations().contains(entry.registration),
                  let target = try? ServiceEventRecipient(serviceID: generation.identity.serviceID, generation: generation.identity.generation) else { return nil }
            return (entry.registration.id, target)
        }
    }

    func connection(for owner: ServiceIdentity) throws -> PluginControlConnection {
        guard let entry = entries[owner.pluginID], entry.generation?.identity == owner,
              registrations().contains(entry.registration), let generation = entry.generation else {
            throw RPCFailure(code: APIError.serviceSessionUnavailable, message: "Service session unavailable")
        }
        return try generation.commandConnection()
    }

    func acknowledgeReady(_ params: [String: JSONValue], defaultOwner: ServiceIdentity?, operation: WorkspaceOperationContext) throws -> JSONValue {
        guard Set(params.keys).isSubset(of: ["version", "serviceId", "generation"]), params["version"] == .integer(1) else {
            throw RPCFailure(code: -32602, message: "service.ready requires version 1 and a live generation selector")
        }
        let serviceID: String
        let generationID: String
        if params["serviceId"] != nil || params["generation"] != nil {
            guard let service = params["serviceId"]?.string, let generation = params["generation"]?.string else {
                throw RPCFailure(code: -32602, message: "serviceId and generation must be supplied together")
            }
            serviceID = service; generationID = generation
        } else {
            guard let defaultOwner else { throw RPCFailure(code: -32602, message: "serviceId and generation are required") }
            serviceID = defaultOwner.serviceID; generationID = defaultOwner.generation
        }
        guard let generation = entries.values.compactMap(\.generation).first(where: {
            $0.identity.serviceID == serviceID && $0.identity.generation == generationID
        }) else { throw RPCFailure(code: APIError.serviceSessionUnavailable, message: "Service generation unavailable") }
        return try generation.acknowledgeReady(operation: operation)
    }

    func list() throws -> JSONValue {
        .array(try registrations().filter { $0.service != nil }.map { .object(info(try entry($0.id))) })
    }
    func status(_ id: String) throws -> JSONValue { .object(info(try entry(id))) }
    func logs(_ id: String) throws -> JSONValue {
        let generation = try entry(id).generation
        return .object([
            "stdout": .string(String(decoding: generation?.process?.stdoutTail ?? generation?.stdout ?? Data(), as: UTF8.self)),
            "stderr": .string(String(decoding: generation?.process?.stderrTail ?? generation?.stderr ?? Data(), as: UTF8.self))
        ])
    }

    func start(_ id: String, operation: WorkspaceOperationContext) throws -> JSONValue {
        try validateOperation(operation)
        let entry = try entry(id)
        if ["starting", "ready"].contains(entry.state) { return .object(info(entry)) }
        guard entry.state != "stopping", !reservations.values.contains(where: { $0.identity.pluginID == id }) else {
            throw RPCFailure(code: APIError.conflict, message: "Service cleanup is pending or unconfirmed")
        }
        guard reservations.count < 16 else { throw RPCFailure(code: APIError.unavailable, message: "At most 16 service reservations are allowed") }
        let identity = try ServiceIdentity(appInstanceID: appID, pluginID: id, serviceID: entry.id, generation: UUID().uuidString)
        let generation = try BackgroundServiceGeneration(identity: identity, cliPath: cliPath, spec: entry.registration.service!, packageRoot: entry.registration.packageRoot,
            isCurrent: { [weak self, weak entry] in
                guard let self, let entry else { return false }
                return !self.closed && self.entries[id] === entry && entry.generation?.identity == identity
                    && self.registrations().contains(entry.registration)
            }, operations: operations, request: request, ready: { [weak self, weak entry] operation in
                guard let self, let entry, self.entries[id] === entry, entry.generation?.identity == identity else {
                    throw RPCFailure(code: APIError.serviceSessionUnavailable, message: "Service generation unavailable")
                }
                try self.transition(entry, to: "ready", reason: "ready", operation: operation)
            }, retireOwned: retireOwned, failed: { [weak self, weak entry] failure in
                guard let self, let entry, entry.generation?.identity == identity else { return }
                self.retire(entry, finalState: "failed", reason: failure.rawValue, operation: .init(origin: .native))
            })
        let previous = entry.generation
        entry.retirement = nil
        entry.generation = generation
        reservations[identity.generation] = generation
        do { try transition(entry, to: "starting", reason: "start", operation: operation) }
        catch {
            entry.generation = previous
            reservations.removeValue(forKey: identity.generation)
            throw error
        }
        do { try generation.start(settings: settings(id)) }
        catch { retire(entry, finalState: "failed", reason: "startFailed", operation: operation) }
        return .object(info(entry)) // Observed acceptance, not a claim of readiness.
    }

    func stop(_ id: String, operation: WorkspaceOperationContext) async throws -> JSONValue {
        try validateOperation(operation)
        let entry = try entry(id)
        guard let generation = entry.generation else { return .object(info(entry)) }
        if entry.state == "failed", entry.reason == "cleanupUnconfirmed" { return .object(info(entry)) }
        if generation.cleanupConfirmed {
            if entry.state != "stopped" { try transition(entry, to: "stopped", reason: "stop", operation: operation) }
            return .object(info(entry))
        }
        if entry.state != "stopping" { try transition(entry, to: "stopping", reason: "stop", operation: operation) }
        let cleanup = retire(entry, finalState: "stopped", reason: "stop", operation: operation)
        // Accepted lifecycle work is host-owned even if this requesting peer disconnects.
        await cleanup.value
        var result = info(entry)
        result["superseded"] = .bool(entries[id] !== entry || entry.generation !== generation)
        return .object(result)
    }

    /// Called synchronously AFTER successful catalog persistence. No stale registration
    /// can admit work while cleanup awaits; retained reservations forbid overlapping replacement.
    func remove(_ id: String, operation: WorkspaceOperationContext) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        _ = retire(entry, finalState: "stopped", reason: "registrationRemoved", operation: operation)
    }

    @discardableResult
    private func retire(_ entry: Entry, finalState: String, reason: String, operation: WorkspaceOperationContext) -> Task<Void, Never> {
        guard let generation = entry.generation else { return Task {} }
        if let retirement = entry.retirement {
            // A later stop or removal must not report an in-flight failure as a clean stop.
            if entry.finishRequest?.state != "failed" { entry.finishRequest = (finalState, reason, operation) }
            return retirement
        }
        entry.finishRequest = (finalState, reason, operation)
        // Resource retirement must proceed even if an observed-exit publication fails.
        if entry.state != "stopping" {
            do { try transition(entry, to: "stopping", reason: reason, operation: operation) }
            catch { entry.state = "stopping"; entry.reason = reason }
        }
        let cleanup = generation.retire()
        let task = Task { [weak self, entry, generation] in
            await cleanup.value
            guard let self else { return }
            if generation.cleanupConfirmed { self.reservations.removeValue(forKey: generation.identity.generation) }
            guard !self.closed, entry.generation === generation, entry.state == "stopping" else { return }
            let requested = entry.finishRequest!
            let state = generation.cleanupConfirmed ? requested.state : "failed"
            let resultReason = generation.cleanupConfirmed ? requested.reason : "cleanupUnconfirmed"
            do { try self.transition(entry, to: state, reason: resultReason, operation: requested.operation) }
            catch { entry.state = state; entry.reason = resultReason }
        }
        entry.retirement = task
        return task
    }

    private func transition(_ entry: Entry, to state: String, reason: String, operation: WorkspaceOperationContext) throws {
        var fields = info(entry)
        fields["state"] = .string(state); fields["reason"] = .string(reason)
        try publish(fields, operation) { entry.state = state; entry.reason = reason }
    }
    private func info(_ entry: Entry) -> [String: JSONValue] {
        ["pluginId": .string(entry.registration.id), "serviceId": .string(entry.id),
         "generation": entry.generation.map { .string($0.identity.generation) } ?? .null,
         "state": .string(entry.state), "reason": .string(entry.reason), "mode": .string("manual"),
         "pid": entry.generation?.process.map { .integer(Int($0.pid)) } ?? .null,
         "cleanupConfirmed": .bool(entry.generation?.cleanupConfirmed ?? true),
         "reservationHeld": .bool(reservations.values.contains { $0.identity.pluginID == entry.registration.id })]
    }
    private func entry(_ id: String) throws -> Entry {
        guard !closed, let registration = registrations().first(where: { $0.id == id && $0.service != nil }) else {
            throw RPCFailure(code: -32602, message: "A registered background service is required")
        }
        if let entry = entries[id], entry.registration == registration { return entry }
        guard entries[id] == nil else { throw RPCFailure(code: APIError.conflict, message: "Service registration changed") }
        let entry = Entry(registration); entries[id] = entry
        return entry
    }
    private func validateOperation(_ operation: WorkspaceOperationContext) throws {
        try Task.checkCancellation(); try operation.validateCaller()
    }
    func close() {
        guard !closed else { return }
        closed = true
        for generation in reservations.values { generation.close() }
        reservations.removeAll(); entries.removeAll()
    }
    isolated deinit { close() }
}
