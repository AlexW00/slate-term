import ArgumentParser
import Foundation
import SlateTermCore
import SlateTermIPC
import SlateTermSettings

@main
struct SlateTermCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "slate-term", abstract: "Control a running Slate Terminal workspace.",
        subcommands: [WarningsCLI.self, NotifyCLI.self, NotificationsCLI.self, Tabs.self, Panes.self, WindowsCLI.self, TerminalCommand.self, BrowserCommand.self, WebCLI.self, Plugins.self, Events.self, ContextCommand.self, ShellCommand.self, LayoutCommand.self, SavedLayoutsCommand.self, Commands.self, ConfigCommand.self, WorkspaceCLI.self, APICLI.self, AppearanceCLI.self, AgentActivityCLI.self, PresenceCLI.self, PaletteCLI.self, SkillCLI.self, WelcomeCLI.self, RPC.self, Version.self, PluginWorker.self])

    static func main() {
        do {
            var command = try parseAsRoot()
            try command.run()
        } catch {
            if CommandLine.arguments.contains("--json"), exitCode(for: error) != .success {
                let failure = error as? RPCFailure
                let object: JSONValue = .object(["error": .object([
                    "code": .integer(failure?.code ?? -32602), "message": .string(failure?.message ?? message(for: error)),
                    "data": failure?.data ?? .null,
                    "outcome": .string(failure.map { [-32600, -32601, -32602, APIError.conflict, APIError.forbidden, APIError.incompatible].contains($0.code) ? "rejected" : "unknown" } ?? (error is SocketError ? "unknown" : "rejected"))
                ])])
                if let data = try? JSONEncoder().encode(object) { FileHandle.standardError.write(data + Data([10])) }
                Foundation.exit(1)
            }
            exit(withError: error)
        }
    }
}

struct Connection: ParsableArguments {
    @Option(help: "Unix socket path; defaults to SLATE_TERM_SOCKET.") var socket: String?
    @Flag(help: "Emit JSON results and machine-readable JSON errors.") var json = false
    @Option(help: "Require this app instance; rejects a restarted/replaced host.") var expectedInstanceId: String?
    @Option(help: "Opaque deliveryContext from an event poll for this caller; never inferred from environment.") var cause: String?
    @Option(help: "Agent name shown on panes this call touches; defaults to SLATE_TERM_ACTOR. Display only.") var actor: String?
    @Option(help: "Short reason shown next to the agent name, at most 80 characters. Requires an actor.") var note: String?

    func call(_ method: String, params: [String: JSONValue] = [:], timeoutSeconds: Int = 30) throws {
        try printJSON(request(method, params: params, timeoutSeconds: timeoutSeconds))
    }

    func request(_ method: String, params: [String: JSONValue] = [:], timeoutSeconds: Int = 30) throws -> JSONValue {
        let environment = ProcessInfo.processInfo.environment
        let service = try ServiceIdentity.inherited(from: environment)
        if let service {
            guard let inheritedSocket = environment["SLATE_TERM_SOCKET"],
                  inheritedSocket.hasPrefix("/"), !inheritedSocket.contains("\0"),
                  socket == nil || socket == inheritedSocket,
                  expectedInstanceId == nil || expectedInstanceId == service.appInstanceID,
                  params["expectedInstanceId"] == nil || params["expectedInstanceId"] == .string(service.appInstanceID) else {
                throw RPCFailure(code: APIError.serviceSessionUnavailable, message: "Service session unavailable")
            }
        }
        guard let path = socket ?? environment["SLATE_TERM_SOCKET"] else {
            throw ValidationError("Set SLATE_TERM_SOCKET or pass --socket. Run inside Slate Terminal for automatic discovery.")
        }
        var guarded = params
        if method != "api.describe", !method.hasPrefix("shell."), guarded["expectedInstanceId"] == nil,
           socket == nil || socket == environment["SLATE_TERM_SOCKET"], let inherited = environment["SLATE_TERM_INSTANCE_ID"] {
            guarded["expectedInstanceId"] = .string(inherited)
        }
        if let expectedInstanceId { guarded["expectedInstanceId"] = .string(expectedInstanceId) }
        // Shell hooks and discovery never show presence and must not pay for capability negotiation.
        let presence = method.hasPrefix("shell.") || method == "api.describe" ? nil : try presenceActor(environment: environment, service: service)
        let metadata: RPCMetadata?
        do { metadata = cause == nil && presence == nil ? nil : try RPCMetadata(cause: cause, actor: presence) }
        catch { throw ValidationError("--cause must be an opaque delivery reference of 1–64 ASCII letters, digits, hyphens or underscores") }
        let client = UnixClient(path: path, timeoutSeconds: timeoutSeconds, service: service)
        let contributed = method == "command.run" && guarded["id"]?.string?.hasPrefix("plugin.") == true
        let requested = Set(guarded.keys.filter { $0.hasPrefix("expected") && (!contributed || APIGuards.names.contains($0)) })
        return try client.withSession { session in
            if !requested.isEmpty {
                let capabilities: JSONValue
                do { capabilities = try session.call("api.describe", params: [:]) }
                catch let failure as RPCFailure where failure.code == -32601 {
                    throw RPCFailure(code: APIError.incompatible, message: "Host cannot enforce identity/revision guards; upgrade the host")
                }
                let supported = try APIGuards.supported(by: capabilities)
                guard requested.isSubset(of: supported) else { throw RPCFailure(code: APIError.incompatible, message: "Host cannot enforce requested guards: \(requested.subtracting(supported).sorted().joined(separator: ", "))") }
            }
            return try session.call(method, params: guarded, metadata: metadata)
        }
    }
}

extension Connection {
    /// Agents identify themselves once with SLATE_TERM_ACTOR; scripts and services never do.
    func presenceActor(environment: [String: String], service: ServiceIdentity?) throws -> PresenceActor? {
        guard service == nil else {
            if actor != nil || note != nil { throw ValidationError("--actor and --note are not available to background services") }
            return nil
        }
        var name = actor
        if name == nil, let inherited = environment["SLATE_TERM_ACTOR"], !inherited.isEmpty {
            // Presence is display only, so a bad inherited name must never break the call itself.
            if PresenceActor.isValidName(inherited) { name = inherited }
            else if note == nil {
                FileHandle.standardError.write(Data("slate-term: ignoring invalid SLATE_TERM_ACTOR; use 1–32 ASCII letters, digits, '.', '_', '-' or ':'\n".utf8))
            }
        }
        guard let name else {
            if note != nil { throw ValidationError("--note requires a valid agent name; set SLATE_TERM_ACTOR or pass --actor") }
            return nil
        }
        // Origin stays tied to the launching app/session, never the explicit action target.
        let inherited = (socket == nil || socket == environment["SLATE_TERM_SOCKET"])
            && (expectedInstanceId == nil || expectedInstanceId == environment["SLATE_TERM_INSTANCE_ID"])
        let home = inherited ? environment["SLATE_TERM_PANE_ID"].flatMap { PresenceActor.isValidHome($0) ? $0 : nil } : nil
        let origin: PresenceOrigin?
        if home != nil, let instance = environment["SLATE_TERM_INSTANCE_ID"], let session = environment["SLATE_TERM_SESSION_ID"] {
            origin = try? PresenceOrigin(instanceID: instance, sessionID: session)
        } else { origin = nil }
        do { return try PresenceActor(name: name, note: note, home: home, origin: origin) }
        catch { throw ValidationError("Invalid agent identity: \(error)") }
    }
}

struct Target: ParsableArguments {
    @Option(help: "Explicit pane ID, e.g. p1.") var pane: String?
    @Option(help: "Explicit tab ID, e.g. t1.") var tab: String?
    @Flag(help: "Allow termination of foreground processes when closing.") var force = false
    @Flag(help: "Intentionally target current focus, ignoring inherited pane/tab/session.") var active = false
    @Option var expectedWorkspaceRevision: String?
    @Option var expectedLayoutRevision: String?
    func params(connection: Connection, scope: String? = nil, inheritingTarget: Bool = true) throws -> [String: JSONValue] {
        let unanchored = !inheritingTarget && pane == nil && tab == nil
        var result = try APITarget.resolve(pane: pane, tab: tab, active: active || unanchored, socket: connection.socket,
                                          instance: connection.expectedInstanceId, scope: scope, environment: ProcessInfo.processInfo.environment)
        if force { result["force"] = .bool(true) }
        if let expectedWorkspaceRevision { result["expectedWorkspaceRevision"] = .string(expectedWorkspaceRevision) }
        if let expectedLayoutRevision { result["expectedLayoutRevision"] = .string(expectedLayoutRevision) }
        return result
    }
}

struct TerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminal", abstract: "Generic terminal I/O and authenticated shell run/wait operations.")
    enum Action: String, CaseIterable, ExpressibleByArgument { case send, key, capture, run, wait }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    @Option var scope: ContextCommand.Scope?
    @Option var sessionId: String?
    @Option var text: String?
    @Option var command: String?
    @Option(help: "Language the run command is written in; refuse if the pane runs another shell.") var shell: ShellKind?
    @Option(help: "Logical key, e.g. ctrl+c, alt+left, shift+tab; text entry uses send.") var key: String?
    @Option(help: "Wait for this literal screen text instead of a shell prompt.") var contains: String?
    @Option(help: "Require a later authenticated prompt sequence.") var afterSequence: Int?
    @Option(help: "Run/wait deadline in milliseconds, 1...295000; default 30000. Expiry does not stop the process.") var timeoutMilliseconds: Int?

    func run() throws {
        var params = try target.params(connection: connection, scope: scope?.rawValue)
        if let sessionId { params["sessionId"] = .string(sessionId); params.removeValue(forKey: "expectedAnchorSessionId") }
        if let text { params["text"] = .string(text) }
        if let command { params["command"] = .string(command) }
        if let shell {
            guard action == .run else { throw ValidationError("--shell applies only to terminal run") }
            params["shell"] = .string(shell.rawValue)
        }
        if let key { params["key"] = .string(key) }
        if let contains { params["contains"] = .string(contains) }
        if let afterSequence { params["afterSequence"] = .integer(afterSequence) }
        let timeout = timeoutMilliseconds ?? 30_000
        guard (1...295_000).contains(timeout) else { throw ValidationError("timeout-milliseconds must be in 1...295000") }
        if let timeoutMilliseconds { params["timeoutMilliseconds"] = .integer(timeoutMilliseconds) }
        try connection.call("terminal.\(action.rawValue)", params: params, timeoutSeconds: (timeout + 5_999) / 1000)
    }
}

struct Plugins: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Install trusted plugin ZIPs. Plugins can control your terminals and files.")
    enum Action: String, CaseIterable, ExpressibleByArgument { case list, register, validate, unregister, enable, disable, status, restart, logs, settings, service, data; case panelState = "panel-state" }
    @Argument var action: Action
    @Argument var id: String?
    @Argument(help: "Plugin namespace for settings get/patch or service controls.") var namespace: String?
    @Option(help: "JSON set/delete operation array for settings or persistence patch.") var operations: String?
    @Option var expectedWriteRevision: String?
    @Option var expectedDataRevision: String?
    @Option var expectedPanelId: String?
    @Option var expectedStateRevision: String?
    @Option var pane: String?
    @Option var tab: String?
    @Option var expectedWorkspaceRevision: String?
    @Option(help: "Plugin ZIP to install or validate.") var package: String?
    @Option var instanceId: String?
    @Flag var replace = false
    @Flag var force = false
    @OptionGroup var connection: Connection
    func run() throws {
        if action == .data || action == .panelState { try runPersistence(); return }
        guard expectedDataRevision == nil, expectedPanelId == nil, expectedStateRevision == nil, pane == nil, tab == nil, expectedWorkspaceRevision == nil else {
            throw ValidationError("Persistence options require plugins data or panel-state")
        }
        if action == .service {
            guard let id, let method = AutomationMethod(rawValue: "plugins.service.\(id)"), method.family == .services,
                  (id == "list" ? namespace == nil : namespace != nil),
                  package == nil, instanceId == nil, !replace, !force, operations == nil, expectedWriteRevision == nil else {
                throw ValidationError("Use plugins service list or plugins service start|stop|status|logs PLUGIN-ID; no registration/settings options")
            }
            try connection.call(method.rawValue, params: namespace.map { ["id": .string($0)] } ?? [:])
            return
        }
        if action == .settings {
            guard let id, ["get", "patch"].contains(id), let namespace, package == nil, instanceId == nil, !replace, !force else {
                throw ValidationError("Use plugins settings get|patch PLUGIN-ID; registration/process options do not apply")
            }
            var params: [String: JSONValue] = ["id": .string(namespace)]
            if id == "patch" {
                guard let operations, let expectedWriteRevision else { throw ValidationError("settings patch requires --operations and --expected-write-revision") }
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(operations.utf8))
                guard case .array = value else { throw ValidationError("--operations must be a JSON array") }
                params["operations"] = value
                params["expectedWriteRevision"] = .string(expectedWriteRevision)
            } else if operations != nil || expectedWriteRevision != nil { throw ValidationError("get does not take patch options") }
            try connection.call("plugins.settings.\(id)", params: params)
            return
        }
        guard namespace == nil, operations == nil, expectedWriteRevision == nil else { throw ValidationError("Settings options require plugins settings get|patch") }
        var params: [String: JSONValue] = [:]
        if let id { params["id"] = .string(id) }
        if let instanceId { params["instanceId"] = .string(instanceId) }
        if force { params["force"] = .bool(true) }
        if replace { params["replace"] = .bool(true) }
        if action == .register || action == .validate {
            guard let package, id == nil, instanceId == nil, !force, action != .validate || !replace else {
                throw ValidationError("register and validate require --package ZIP; only register accepts --replace")
            }
            let url = URL(fileURLWithPath: package).standardizedFileURL
            if action == .validate {
                guard connection.socket == nil else { throw ValidationError("validate is offline; do not pass --socket") }
                try printJSON(PluginPackageStore.validate(url))
                return
            }
            params["packagePath"] = .string(url.path)
        } else if package != nil || replace {
            throw ValidationError("--package and --replace require plugins register (or --package for validate)")
        }
        try connection.call("plugins.\(action.rawValue)", params: params)
    }
}

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Publish events or read a bounded, resumable event journal.")
    enum Action: String, CaseIterable, ExpressibleByArgument { case head, emit, poll, watch }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @Option(help: "Exact topic or namespace wildcard; repeat to select multiple topics.") var topic: [String] = []
    @Option(help: "Resume after this cursor. Expired/restarted cursors require explicit resync.") var after: String?
    @Option(help: "JSON payload for emit; defaults to null.") var payload: String?
    @Option var tab: String?
    @Option var pane: String?
    @Option var targetInstanceId: String?
    @Option(help: "Emit to one live service generation: SERVICE-ID:GENERATION.") var targetService: String?
    @Option(help: "Directed-event projection: all, instance:INSTANCE-ID or service:SERVICE-ID:GENERATION.") var recipient: String?
    @Option(help: "global drops the default tab filter; tab requires a tab.") var scope: String?
    @Option(help: "Maximum events per poll, 1...128.") var limit: Int?
    @Option(help: "Long-poll deadline, 0...25000 milliseconds; default 20000.") var waitMilliseconds: Int?

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let tab { params["tab"] = .string(tab) }
        if let pane { params["pane"] = .string(pane) }
        if action == .head {
            guard params.isEmpty, topic.isEmpty, after == nil, payload == nil, targetInstanceId == nil, targetService == nil,
                  recipient == nil, scope == nil, limit == nil, waitMilliseconds == nil else { throw ValidationError("head takes no event options") }
            try connection.call("events.head")
            return
        }
        if action == .emit {
            guard topic.count == 1, after == nil, recipient == nil, scope == nil, limit == nil, waitMilliseconds == nil else {
                throw ValidationError("emit requires exactly one --topic and no polling options")
            }
            params["topic"] = .string(topic[0])
            if let payload { params["payload"] = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) }
            if let targetInstanceId { params["targetInstanceId"] = .string(targetInstanceId) }
            if let targetService { params["targetService"] = try Self.serviceRecipient(targetService) }
            try connection.call("events.emit", params: params)
            return
        }
        guard payload == nil, targetInstanceId == nil, targetService == nil else {
            throw ValidationError("payload, target-instance-id and target-service are only valid for emit")
        }
        if let after { params["after"] = .string(after) }
        if let recipient { params["recipient"] = try Self.recipient(recipient) }
        if let scope { params["scope"] = .string(scope) }
        if !topic.isEmpty { params["topics"] = .array(topic.map(JSONValue.string)) }
        if let limit { params["limit"] = .integer(limit) }
        if let waitMilliseconds { params["waitMilliseconds"] = .integer(waitMilliseconds) }
        if action == .poll {
            try connection.call("events.poll", params: params)
            return
        }
        guard waitMilliseconds != 0 else { throw ValidationError("watch requires a positive wait-milliseconds to avoid busy polling") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while true {
            let batch = try connection.request("events.poll", params: params)
            guard let value = batch.object, let cursor = value["cursor"]?.string,
                  case .array(let events) = value["events"] else { throw ValidationError("Invalid event batch from app") }
            for event in events {
                var line = try encoder.encode(event)
                line.append(10)
                try FileHandle.standardOutput.write(contentsOf: line)
            }
            params["after"] = .string(cursor)
        }
    }

    /// Converts the CLI recipient spelling into the host's JSON selector; the host validates identities.
    static func recipient(_ text: String) throws -> JSONValue {
        if text == "all" { return .string("all") }
        if text.hasPrefix("instance:"), text.count > "instance:".count {
            return .object(["instanceId": .string(String(text.dropFirst("instance:".count)))])
        }
        if text.hasPrefix("service:") { return try serviceRecipient(String(text.dropFirst("service:".count))) }
        throw ValidationError("recipient must be all, instance:INSTANCE-ID or service:SERVICE-ID:GENERATION")
    }

    /// Splits at the last colon because generations are UUIDs without colons.
    static func serviceRecipient(_ text: String) throws -> JSONValue {
        guard let separator = text.lastIndex(of: ":"), separator != text.startIndex, text.index(after: separator) != text.endIndex else {
            throw ValidationError("service recipients must be SERVICE-ID:GENERATION")
        }
        return .object(["serviceId": .string(String(text[..<separator])), "generation": .string(String(text[text.index(after: separator)...]))])
    }
}

struct ContextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "context", abstract: "Read focus and active-terminal context.")
    enum Action: String, CaseIterable, ExpressibleByArgument { case get, inspect }
    enum Scope: String, ExpressibleByArgument { case pane, tab, global }
    @Argument var action: Action = .get
    @Option var scope: Scope = .tab
    @Flag(name: .customLong("self"), help: "Require the inherited or explicitly supplied caller pane.") var ownContext = false
    @OptionGroup var target: Target
    @OptionGroup var connection: Connection
    func run() throws {
        var params = try target.params(connection: connection)
        if ownContext && params["pane"] == nil { throw ValidationError("--self requires a pane identity; services without one must select a view") }
        params["scope"] = .string(scope.rawValue)
        try connection.call("context.\(action.rawValue)", params: params)
    }
}

struct ShellCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shell", abstract: "Shell integration and authenticated context reporting.")
    enum Action: String, ExpressibleByArgument { case update, integration; case runInput = "run-input" }
    enum State: String, ExpressibleByArgument { case prompt, running }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @Option var state: State?
    @Option(help: "Shell whose hooks send the report, or whose hooks to print.") var shell: ShellKind?
    @Option(help: "Whether the shell can check its edit line before a run (false on bash 3.2).") var runInput: Bool?
    @Option var pid: Int?
    @Flag(help: .hidden) var deliver = false
    @Option var sequence: Int?
    @Option var cwd: String?
    @Option var command: String?
    @Option var exitCode: Int?
    @Flag var emptyBuffer = false
    func run() throws {
        if action == .integration { print(ShellIntegration.hooks(for: shell ?? .zsh)); return }
        if deliver { return try ShellReportDelivery.deliver(connection: connection) }
        let environment = ProcessInfo.processInfo.environment
        if action == .runInput {
            guard let pane = environment["SLATE_TERM_PANE_ID"], let token = environment["SLATE_TERM_CONTEXT_TOKEN"], let pid else {
                throw ValidationError("Run input requires an authenticated shell and pid")
            }
            let value = try connection.request("shell.runInput", params: ["pane": .string(pane), "token": .string(token), "pid": .integer(pid), "emptyBuffer": .bool(emptyBuffer)], timeoutSeconds: 1)
            guard let input = value.string else { throw ValidationError("Invalid shell run input") }
            print(input)
            return
        }
        guard let pane = environment["SLATE_TERM_PANE_ID"], let token = environment["SLATE_TERM_CONTEXT_TOKEN"],
              let state, let pid, let sequence, let cwd else { throw ValidationError("Shell reporting requires a Slate Terminal session and state, pid, sequence, cwd") }
        var params: [String: JSONValue] = ["pane": .string(pane), "token": .string(token), "state": .string(state.rawValue),
                                          "pid": .integer(pid), "sequence": .integer(sequence), "cwd": .string(cwd)]
        if let command { params["command"] = .string(command) }
        if let exitCode { params["exitCode"] = .integer(exitCode) }
        if let shell { params["shell"] = .string(shell.rawValue) }
        if let runInput { params["runInput"] = .bool(runInput) }
        // A command's start is reported before it runs, so the host never sends a run key into
        // a program reading input. A busy host, as at launch, must not stall the prompt: prompts,
        // and starts the host cannot take within a second, go to a detached copy instead.
        if state == .running {
            do { return try connection.call("shell.update", params: params, timeoutSeconds: 1) }
            catch is SocketError {}
        }
        try ShellReportDelivery.spawn(params, connection: connection)
    }
}

struct BrowserCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "browser", abstract: "Control an embedded browser pane.")
    enum Action: String, CaseIterable, ExpressibleByArgument { case get, navigate, eval, screenshot, snapshot, click, fill, select, scroll, wait
        case clearData = "clear-data", clearSiteData = "clear-site-data"
        var method: String {
            switch self {
            case .clearData: "browser.clearData"
            case .clearSiteData: "browser.clearSiteData"
            default: "browser.\(rawValue)"
            }
        }
    }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    @Option var url: String?
    @Option var script: String?
    @Option var path: String?
    @Option(help: "A unique main-document CSS selector.") var selector: String?
    @Option(help: "An element reference from a snapshot of this document.") var ref: String?
    @Option var text: String?
    @Option(help: "Option value for select; repeat for multi-select.") var value: [String] = []
    @Option var x: Double?
    @Option var y: Double?
    @Option var maxElements: Int?
    @Option(help: "Wait state: attached, detached, visible, or hidden.") var state: String?
    @Option var timeoutMilliseconds: Int?
    func run() throws {
        var params = try target.params(connection: connection, inheritingTarget: action != .clearData)
        if let url { params["url"] = .string(url) }
        if let script { params["script"] = .string(script) }
        if let path { params["path"] = .string(path) }
        if let selector { params["selector"] = .string(selector) }
        if let ref { params["ref"] = .string(ref) }
        if let text { params["text"] = .string(text) }
        if action == .select || !value.isEmpty { params["values"] = .array(value.map(JSONValue.string)) }
        if let x { params["x"] = .number(x) }
        if let y { params["y"] = .number(y) }
        if let maxElements { params["maxElements"] = .integer(maxElements) }
        if let state { params["state"] = .string(state) }
        if let timeoutMilliseconds { params["timeoutMilliseconds"] = .integer(timeoutMilliseconds) }
        try connection.call(action.method, params: params)
    }
}

struct Commands: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "command", abstract: "Invoke the same commands as native menus.")
    enum Action: String, CaseIterable, ExpressibleByArgument { case list, run }
    @Argument var action: Action
    @Argument var id: String?
    @Option(help: "JSON object of action arguments; routing uses --pane/--tab and revision flags.") var params: String = "{}"
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    func run() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(self.params.utf8))
        guard let arguments = value.object, Set(arguments.keys).isDisjoint(with: ["id", "pane", "tab", "force", "contextPane", "expectedInstanceId", "expectedAnchorSessionId", "expectedWorkspaceRevision", "expectedLayoutRevision"]) else {
            throw ValidationError("--params must be an object of action arguments; use routing flags for pane/tab/guards")
        }
        var params = try target.params(connection: connection, inheritingTarget: id.map { !CommandContract.forCommand($0).workspaceIndependent } ?? true)
        params.merge(arguments) { _, new in new }
        if action == .run {
            guard let id else { throw ValidationError("command run requires an ID") }
            params["id"] = .string(id)
        }
        try connection.call("command.\(action.rawValue)", params: params, timeoutSeconds: id?.hasPrefix("plugin.") == true ? 300 : 30)
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Inspect, reload, or validate TOML configuration.")
    enum Action: String, CaseIterable, ExpressibleByArgument { case get, reload, validate, set, patch }
    @Argument var action: Action
    @Option var key: String?
    @Option(help: "JSON value for set, or an object of dotted application keys for patch.") var value: String?
    @Option var expectedSourceRevision: String?
    @Option(help: "File for offline validation; defaults to SLATE_TERM_CONFIG_FILE or ~/.config/slate-term/config.toml.") var file: String?
    @OptionGroup var connection: Connection
    func run() throws {
        if action == .set || action == .patch {
            guard file == nil, let value, let expectedSourceRevision else { throw ValidationError("config set/patch requires --value and --expected-source-revision; --file is offline-only") }
            let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))
            let values: [String: JSONValue]
            if action == .set {
                guard let key else { throw ValidationError("config set requires --key") }
                values = [key: decoded]
            } else {
                guard key == nil, let object = decoded.object else { throw ValidationError("config patch requires an object value, not --key") }
                values = object
            }
            try connection.call("config.patch", params: ["values": .object(values), "expectedSourceRevision": .string(expectedSourceRevision)])
            return
        }
        guard key == nil, value == nil else { throw ValidationError("--key/--value apply only to config set/patch") }
        if action != .validate {
            guard file == nil else { throw ValidationError("--file applies only to config validate") }
            var params: [String: JSONValue] = action == .reload ? ["id": .string("config.reload")] : [:]
            if let expectedSourceRevision {
                guard action == .reload else { throw ValidationError("--expected-source-revision is not supported for config get") }
                params["expectedSourceRevision"] = .string(expectedSourceRevision)
            }
            try connection.call(action == .reload ? "command.run" : "config.get", params: params)
            return
        }
        guard expectedSourceRevision == nil else { throw ValidationError("Offline config validate does not accept a source revision") }
        guard connection.socket == nil else { throw ValidationError("config validate is offline; do not pass --socket") }
        let url = (file ?? ProcessInfo.processInfo.environment["SLATE_TERM_CONFIG_FILE"]).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/slate-term/config.toml")
        do {
            let configuration = try file == nil ? AppConfiguration.load(from: url)
                : AppConfiguration.parse(String(contentsOf: url, encoding: .utf8))
            try configuration.validateShellExecutable()
            _ = try configuration.terminal.resolvePalettes(directory: url.deletingLastPathComponent().appendingPathComponent("palettes"))
            try printJSON(.object(["valid": .bool(true), "path": .string(url.path), "configuration": try .encoding(configuration)]))
        } catch { throw ValidationError(String(describing: error)) }
    }
}

private func printJSON(_ value: JSONValue) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

struct RPC: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rpc", abstract: "Call a protocol method directly.")
    @Argument var method: String
    @Option var params = "{}"
    @OptionGroup var connection: Connection
    func run() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(params.utf8))
        guard let object = value.object else { throw ValidationError("--params must be a JSON object") }
        try connection.call(method, params: object)
    }
}

struct Version: ParsableCommand {
    @OptionGroup var connection: Connection
    func run() throws { try connection.call("version") }
}

extension ShellKind: ExpressibleByArgument {}

/// Detached delivery for shell reports. posix_spawn, not fork: a forked Swift process must
/// not run Foundation or Dispatch code. The copy starts its own session with no terminal, so
/// the shell's job table, prompt and Ctrl-C never see it. It receives the report on stdin,
/// which keeps command text out of its arguments, where other processes could read it.
enum ShellReportDelivery {
    static let timeoutSeconds: TimeInterval = 10
    static let maximumBytes = 65_536

    static func spawn(_ params: [String: JSONValue], connection: Connection) throws {
        guard let executable = Bundle.main.executablePath else { throw ValidationError("Cannot locate the slate-term executable") }
        let payload = try JSONEncoder().encode(JSONValue.object(params))
        guard payload.count <= maximumBytes else { throw ValidationError("Shell report is too large") }
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else { throw ValidationError("Could not start shell report delivery") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipe[0], 0)
        for descriptor: Int32 in [1, 2] {
            posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", O_WRONLY, 0)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Close every other inherited descriptor, such as the terminal and the pipe's write end.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let arguments = [executable, "shell", "update", "--deliver"] + (connection.socket.map { ["--socket", $0] } ?? [])
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child = pid_t()
        let status = posix_spawn(&child, executable, &actions, &attributes, argv, environ)
        Darwin.close(pipe[0])
        defer { Darwin.close(pipe[1]) }
        guard status == 0 else { throw ValidationError("Could not start shell report delivery: \(String(cString: strerror(status)))") }
        // Well below the pipe buffer, so this never waits for the copy. It is not waited for:
        // the copy is reparented when this process exits a moment later.
        _ = payload.withUnsafeBytes { Darwin.write(pipe[1], $0.baseAddress, $0.count) }
    }

    /// Runs in the detached copy. The host checks credentials when it accepts a connection, so
    /// the copy stays connected for the reply. A full listen queue refuses at once; retry until
    /// the deadline rather than lose a report while the host is busy.
    static func deliver(connection: Connection) throws {
        let input = FileHandle.standardInput.readData(ofLength: maximumBytes + 1)
        guard input.count <= maximumBytes, case .object(let params) = try JSONDecoder().decode(JSONValue.self, from: input) else {
            throw ValidationError("Invalid shell report")
        }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while true {
            let remaining = Int(deadline.timeIntervalSinceNow.rounded(.up))
            do { return try connection.call("shell.update", params: params, timeoutSeconds: max(1, remaining)) }
            catch SocketError.system("connect", let code) where [ECONNREFUSED, EAGAIN, ENOENT].contains(code) && Date() < deadline {
                usleep(50_000)
            }
        }
    }
}
