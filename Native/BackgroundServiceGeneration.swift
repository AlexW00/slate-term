import Darwin
import Foundation
import SlateTermCore
import SlateTermIPC

/// One host-bound process lifetime. Registration intent, reservations and restart policy
/// belong to the manager; this capsule is never reused or overwritten by a successor.
@MainActor
final class BackgroundServiceGeneration {
    enum State: String { case starting, ready, retired }
    enum Failure: String { case readinessTimeout, processExit }
    typealias Request = @MainActor (String, [String: JSONValue], RPCMetadata?, AutomationCaller) async throws -> JSONValue

    let identity: ServiceIdentity
    let audience: CausationAudience
    private(set) var state: State = .starting
    private(set) var cleanupConfirmed = false
    private(set) var process: PluginProcess?
    private(set) var stdout = Data()
    private(set) var stderr = Data()
    private let cliPath: String
    private let spec: PluginProcessSpec
    private let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString)")
    private let isCurrent: () -> Bool
    private let request: Request
    private let ready: (WorkspaceOperationContext) throws -> Void
    private let retireOwned: (ServiceIdentity) -> Task<Bool, Never>
    private let failed: (Failure) -> Void
    private var server: UnixServer?
    private var deadline: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var ownedCleanup: Task<Bool, Never>?
    private var ownershipRetired = false
    private var forcedClosed = false
    private var started = false
    private var ownsDirectory = false
    private var polling = false

    init(identity: ServiceIdentity, cliPath: String, spec: PluginProcessSpec,
         isCurrent: @escaping () -> Bool, operations: OperationControl, request: @escaping Request,
         ready: @escaping (WorkspaceOperationContext) throws -> Void,
         retireOwned: @escaping (ServiceIdentity) -> Task<Bool, Never>, failed: @escaping (Failure) -> Void) throws {
        self.identity = identity
        audience = .service(epoch: operations.epoch, registrationID: identity.pluginID,
                            recipient: try ServiceEventRecipient(serviceID: identity.serviceID, generation: identity.generation))
        self.cliPath = cliPath; self.spec = spec; self.isCurrent = isCurrent
        self.request = request; self.ready = ready
        self.retireOwned = retireOwned; self.failed = failed
    }

    func validateLive() throws {
        guard state != .retired, isCurrent() else { throw unavailable() }
    }

    /// Readiness is health state, not an automation capability gate.
    func commandConnection() throws -> PluginControlConnection {
        try validateLive()
        guard let server else { throw unavailable() }
        return PluginControlConnection(socketPath: server.path, appInstanceID: identity.appInstanceID,
                                       cliPath: cliPath, service: identity)
    }

    /// Called only after the manager's state/event/capacity preflight. No registration
    /// or persistence operation implicitly calls this method.
    func start(settings: [String: JSONValue]) throws {
        try validateLive()
        guard !started else { throw RPCFailure(code: APIError.conflict, message: "Service generation already started") }
        started = true
        do {
            // mkdir must actually create the owned directory; never adopt/remove an existing one.
            guard mkdir(directory.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            ownsDirectory = true
            let endpoint = try UnixServer(directory: directory, service: identity) { [weak self] method, params, metadata in
                guard let self else { throw RPCFailure(code: APIError.serviceSessionUnavailable, message: "Service session unavailable") }
                return try await self.handle(method, params: params, metadata: metadata)
            }
            server = endpoint
            let connection = PluginControlConnection(socketPath: endpoint.path, appInstanceID: identity.appInstanceID,
                                                      cliPath: cliPath, service: identity)
            var environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, value in value }
            for key in environment.keys where key.hasPrefix("SLATE_TERM_") { environment.removeValue(forKey: key) }
            environment.merge(try connection.commandEnvironment(owner: identity)) { _, value in value }
            environment["SLATE_TERM_PLUGIN_SETTINGS"] = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
            environment["PATH"] = URL(fileURLWithPath: cliPath).deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            try validateLive()
            let process = try PluginProcess(executable: cliPath,
                arguments: ["_plugin-worker", "--parent-pid", String(getpid()), spec.executable] + spec.arguments,
                directory: spec.directory.map { URL(fileURLWithPath: $0) }, environment: environment)
            self.process = process
            process.onExit = { [weak self] _ in self?.fail(.processExit) }
            let timeout = spec.readyTimeoutSeconds
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(Int64(timeout * 1000))) }
                catch { return }
                guard let self, self.state == .starting else { return }
                self.fail(.readinessTimeout)
            }
        } catch {
            _ = retire()
            throw error
        }
    }

    func acknowledgeReady(operation: WorkspaceOperationContext) throws -> JSONValue {
        try validateLive()
        try operation.validateCaller()
        if state == .starting {
            try ready(operation)
            try validateLive()
            state = .ready
            deadline?.cancel(); deadline = nil
        }
        return .object(["version": .integer(1), "serviceId": .string(identity.serviceID),
                        "generation": .string(identity.generation), "state": .string(state.rawValue)])
    }

    private func handle(_ method: String, params: [String: JSONValue], metadata: RPCMetadata?) async throws -> JSONValue {
        try Task.checkCancellation()
        try validateLive()
        let caller = AutomationCaller(origin: .service(identity), audience: audience, defaults: .init(pluginID: identity.pluginID)) { [weak self] in
            guard let self else { throw RPCFailure(code: APIError.serviceSessionUnavailable, message: "Service session unavailable") }
            try self.validateLive()
        }
        if method == "events.poll" {
            guard !polling else { throw RPCFailure(code: -32032, message: "A service poll is already pending") }
            polling = true
        }
        defer { if method == "events.poll" { polling = false } }
        let result = try await request(method, params, metadata, caller)
        try Task.checkCancellation()
        try caller.validate()
        return result
    }

    private func fail(_ reason: Failure) {
        guard state != .retired else { return }
        _ = retire() // Revoke and cancel owned work before the manager can schedule a successor.
        failed(reason)
    }

    /// Reentrant callers share the same cancellation-independent cleanup task.
    /// retireOwned must synchronously revoke jobs and return bounded cleanup confirmation;
    /// false prevents the manager from treating uncertain cleanup as a released reservation.
    @discardableResult
    func retire() -> Task<Void, Never> {
        if let cleanup { return cleanup }
        state = .retired
        deadline?.cancel(); deadline = nil
        server?.close(); server = nil
        let process = process
        let task = Task { [self] in
            let ownedConfirmed = await ownedCleanup?.value ?? false
            await process?.stop()
            if let process {
                stdout = process.stdoutTail; stderr = process.stderrTail
                if case .exited = process.state { cleanupConfirmed = ownedConfirmed }
            } else { cleanupConfirmed = ownedConfirmed && !forcedClosed }
            self.process = nil
            if ownsDirectory { try? FileManager.default.removeItem(at: directory); ownsDirectory = false }
        }
        cleanup = task
        revokeOwnedJobs()
        return task
    }

    func stop() async { await retire().value }

    /// App shutdown may not have an asynchronous runloop left. Never claim reaping succeeded.
    func close() {
        if state != .retired {
            state = .retired
            deadline?.cancel(); deadline = nil
            server?.close(); server = nil
            revokeOwnedJobs()
        }
        if let process {
            forcedClosed = true
            cleanupConfirmed = false
            stdout = process.stdoutTail; stderr = process.stderrTail
            process.close(); self.process = nil
        }
        if ownsDirectory { try? FileManager.default.removeItem(at: directory); ownsDirectory = false }
    }

    isolated deinit { close() }

    private func revokeOwnedJobs() {
        guard !ownershipRetired else { return }
        ownershipRetired = true // Consume before callbacks can reenter close/stop.
        ownedCleanup = retireOwned(identity)
    }

    private func unavailable() -> RPCFailure {
        RPCFailure(code: APIError.serviceSessionUnavailable, message: "Service session unavailable")
    }
}
