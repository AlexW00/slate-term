import Darwin
import Foundation
import WebKit
import SlateTermCore
import SlateTermSettings

struct PluginControlConnection {
    let socketPath: String
    let appInstanceID: String
    let cliPath: String
}

/// A logical pane/tab/app-scoped plugin instance. Each visible pane owns a new
/// web view; only explicitly scoped service/storage state is shared.
@MainActor
final class PluginInstance {
    let id = UUID().uuidString
    let registration: PluginRegistration
    private(set) var entryURL: URL
    var origin: PluginOrigin { try! PluginOrigin(url: entryURL) }
    let scopeKey: String
    let tab: TabID?
    let dataStore = WKWebsiteDataStore.nonPersistent()
    private let storage: PrivateJSONStore
    private let connection: PluginControlConnection
    private var values: [String: JSONValue]
    private var process: PluginProcess?
    private var task: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var session: URLSession?
    private var generation = UUID()
    private var restartCount = 0
    private var closed = false
    private(set) var activated = false
    private(set) var state = "idle"
    private(set) var error: String?
    private var logTail = Data()
    var panes = Set<PaneID>()
    private var observers: [UUID: () -> Void] = [:]
    var onEvent: ((String, JSONValue) -> Void)?

    init(registration: PluginRegistration, scopeKey: String, tab: TabID?, directory: URL, connection: PluginControlConnection) throws {
        self.registration = registration; self.scopeKey = scopeKey; self.tab = tab
        self.connection = connection
        guard let entryURL = registration.entryURL else { throw RPCFailure(code: -32602, message: "Plugin does not provide a panel") }
        self.entryURL = entryURL
        storage = try PrivateJSONStore(url: directory.appendingPathComponent(registration.id).appendingPathComponent(scopeKey + ".json"), maximumBytes: 1_048_576)
        values = try storage.load([String: JSONValue].self) ?? [:]
    }

    isolated deinit { close() }
    func observe(_ callback: @escaping () -> Void) -> UUID { let token = UUID(); observers[token] = callback; callback(); return token }
    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }
    func activate() { guard !activated else { return }; activated = true; start() }
    var isReady: Bool { state == "ready" && ownsListener }
    private var ownsListener: Bool {
        guard registration.process != nil else { return true }
        guard let process, process.state == .running else { return false }
        return PluginListener.owns(port: UInt16(origin.port), group: process.pid)
    }
    var info: JSONValue {
        .object(["instanceId": .string(id), "type": .string(registration.id), "scope": .string(registration.scope.rawValue),
                 "scopeKey": .string(scopeKey), "url": .string(entryURL.absoluteString), "state": .string(state), "error": error.map(JSONValue.string) ?? .null,
                 "pid": process.map { .integer(Int($0.pid)) } ?? .null, "restartCount": .integer(restartCount),
                 "panes": .array(panes.sorted { $0.number < $1.number }.map { .string($0.description) })])
    }
    var logs: String { String(decoding: logTail, as: UTF8.self) }

    func storageGet(_ key: String?) -> JSONValue { key.map { values[$0] ?? .null } ?? .object(values) }
    func storageSet(_ key: String, value: JSONValue?) throws {
        guard !key.isEmpty, key.utf8.count <= 256 else { throw RPCFailure(code: -32602, message: "Storage key must contain 1–256 UTF-8 bytes") }
        var next = values
        next[key] = value
        guard next.count <= 1024 else { throw RPCFailure(code: -32602, message: "Plugin storage exceeds 1024 keys") }
        try storage.save(next)
        values = next
        onEvent?("storageChanged", .object(["key": .string(key)]))
    }

    func restart() async {
        guard !closed else { return }
        if let restartTask { await restartTask.value; return }
        let operation = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performRestart()
        }
        restartTask = operation
        await operation.value
        restartTask = nil
    }

    private func performRestart() async {
        guard !closed else { return }
        generation = UUID()
        let expected = generation
        task?.cancel(); session?.invalidateAndCancel(); session = nil
        update("stopping")
        let previous = process
        await previous?.stop()
        guard !closed, generation == expected else { return }
        process = nil
        restartCount = 0
        start()
    }

    func close() {
        guard !closed else { return }
        closed = true
        generation = UUID()
        task?.cancel(); task = nil
        restartTask?.cancel(); restartTask = nil
        session?.invalidateAndCancel(); session = nil
        process?.close(); process = nil
        state = "closed"
        observers.removeAll()
        onEvent = nil
    }

    private func start() {
        guard !closed else { return }
        task?.cancel(); session?.invalidateAndCancel()
        generation = UUID()
        let expected = generation
        guard let spec = registration.process else { update("ready"); return }
        update("starting")
        do {
            if origin.port == 0 {
                var components = URLComponents(url: entryURL, resolvingAgainstBaseURL: false)!
                components.port = Int(try PluginListener.availablePort())
                entryURL = components.url!
            }
            var environment = ProcessInfo.processInfo.environment
            environment.merge(spec.environment) { _, value in value }
            // Reserved identity/connection fields are authoritative, not inherited
            // from a parent terminal or supplied by a manifest.
            for key in environment.keys where key.hasPrefix("SLATE_TERM_") { environment.removeValue(forKey: key) }
            environment["SLATE_TERM_SOCKET"] = connection.socketPath
            environment["SLATE_TERM_CLI"] = connection.cliPath
            environment["SLATE_TERM_INSTANCE_ID"] = connection.appInstanceID
            environment["SLATE_TERM_PLUGIN_SCOPE"] = registration.scope.rawValue
            if let tab { environment["SLATE_TERM_TAB_ID"] = tab.description }
            if registration.scope == .pane { environment["SLATE_TERM_PANE_ID"] = scopeKey }
            let helperDirectory = URL(fileURLWithPath: connection.cliPath).deletingLastPathComponent().path
            environment["PATH"] = helperDirectory + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            environment["SLATE_TERM_PLUGIN_ID"] = registration.id
            environment["SLATE_TERM_PLUGIN_INSTANCE"] = id
            environment["SLATE_TERM_PLUGIN_HOST"] = "127.0.0.1"
            environment["SLATE_TERM_PLUGIN_PORT"] = String(origin.port)
            let helper = connection.cliPath
            // The worker is the group leader and watches this GUI's lifetime.
            // Its service stays in the same group, including after a GUI crash.
            let arguments = ["_plugin-worker", "--parent-pid", String(getpid()), spec.executable] + spec.arguments.map { $0 == "{port}" ? String(origin.port) : $0 }
            let child = try PluginProcess(executable: helper, arguments: arguments,
                                          directory: spec.directory.map { URL(fileURLWithPath: $0) }, environment: environment)
            process = child
            child.onOutput = { [weak self] stream, data in
                guard let self, self.generation == expected else { return }
                self.logTail.append(Data("[\(stream)] ".utf8)); self.logTail.append(data)
                if self.logTail.count > 65_536 { self.logTail.removeFirst(self.logTail.count - 65_536) }
            }
            child.onExit = { [weak self] status in
                guard let self, !self.closed, self.generation == expected else { return }
                self.task?.cancel(); self.session?.invalidateAndCancel(); self.session = nil
                self.process = nil
                self.update("failed", error: "Process exited: \(status)")
                guard self.restartCount < spec.restartLimit else { return }
                self.restartCount += 1
                let delay = min(8, 1 << (self.restartCount - 1))
                self.update("restarting", error: self.error)
                self.task = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard let self, !self.closed, self.generation == expected else { return }
                    self.start()
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = min(1, spec.readyTimeoutSeconds)
            configuration.timeoutIntervalForRequest = min(1, spec.readyTimeoutSeconds)
            let session = URLSession(configuration: configuration, delegate: PluginReadinessDelegate(origin: origin), delegateQueue: nil)
            self.session = session
            task = Task { [weak self] in
                guard let self else { return }
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(spec.readyTimeoutSeconds * 1000)))
                while !Task.isCancelled, !self.closed, self.generation == expected, ContinuousClock.now < deadline {
                    var request = URLRequest(url: self.entryURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
                    request.httpMethod = "HEAD"
                    do {
                        let (_, response) = try await session.data(for: request)
                        if let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                           response.url.map({ self.origin.matches($0) }) == true,
                           self.generation == expected, !Task.isCancelled, self.ownsListener {
                            self.update("ready")
                            session.finishTasksAndInvalidate()
                            self.session = nil
                            return
                        }
                    } catch {}
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                guard !Task.isCancelled, !self.closed, self.generation == expected else { return }
                self.process?.close(); self.process = nil
                session.invalidateAndCancel(); self.session = nil
                self.update("failed", error: "Readiness timed out after \(spec.readyTimeoutSeconds) seconds")
            }
        } catch { update("failed", error: String(describing: error)) }
    }

    private func update(_ state: String, error: String? = nil) {
        self.state = state; self.error = error
        for callback in Array(observers.values) { callback() }
        onEvent?("stateChanged", info)
    }
}

private final class PluginReadinessDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated let origin: PluginOrigin
    init(origin: PluginOrigin) { self.origin = origin }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, origin.matches(url) else { completionHandler(nil); return }
        var next = request
        next.httpMethod = "HEAD"
        completionHandler(next)
    }
}

@MainActor
final class PluginInstances {
    private var instances: [String: PluginInstance] = [:]
    private let directory: URL
    private var connection: PluginControlConnection?
    var onEvent: ((PluginInstance, String, JSONValue) -> Void)?
    init(directory: URL) { self.directory = directory }

    func connect(socketPath: String, appInstanceID: String) {
        connection = PluginControlConnection(socketPath: socketPath, appInstanceID: appInstanceID,
            cliPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/slate-term").path)
    }

    func acquire(_ registration: PluginRegistration, pane: PaneID, tab: TabID) throws -> PluginInstance {
        guard let connection else { throw RPCFailure(code: -32022, message: "Plugin control connection is not ready") }
        let scopeKey: String
        switch registration.scope {
        case .pane: scopeKey = pane.description
        case .tab: scopeKey = tab.description
        case .global: scopeKey = "global"
        }
        let key = registration.id + "/" + scopeKey
        let instance: PluginInstance
        if let existing = instances[key] { instance = existing }
        else {
            instance = try PluginInstance(registration: registration, scopeKey: scopeKey,
                                          tab: registration.scope == .global ? nil : tab, directory: directory, connection: connection)
            instance.onEvent = { [weak self, weak instance] name, payload in
                guard let instance else { return }
                self?.onEvent?(instance, name, payload)
            }
            instances[key] = instance
        }
        instance.panes.insert(pane)
        return instance
    }
    func release(_ instance: PluginInstance, pane: PaneID) { instance.panes.remove(pane) }
    func prune(workspace: Workspace) {
        let tabs = Set(workspace.tabs.map(\.id))
        for (key, instance) in instances {
            let gone = instance.registration.scope == .pane ? instance.panes.isEmpty : instance.registration.scope == .tab && !tabs.contains(instance.tab!)
            if gone || !instance.activated && instance.panes.isEmpty { instance.close(); instances.removeValue(forKey: key) }
        }
    }
    var all: [PluginInstance] { instances.values.sorted { $0.id < $1.id } }
    func remove(type: String) {
        for (key, instance) in instances where instance.registration.id == type { instance.close(); instances.removeValue(forKey: key) }
    }
    func close() { instances.values.forEach { $0.close() }; instances.removeAll() }
}
