import ArgumentParser
import Foundation
import SlateTermCore
import SlateTermIPC
import SlateTermSettings

@main
struct SlateTermCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "slate-term", abstract: "Control a running Slate Terminal workspace.",
        subcommands: [Tabs.self, Panes.self, TerminalCommand.self, BrowserCommand.self, Plugins.self, Events.self, ContextCommand.self, ShellCommand.self, LayoutCommand.self, Commands.self, ConfigCommand.self, RPC.self, Version.self, PluginWorker.self])
}

struct Connection: ParsableArguments {
    @Option(help: "Unix socket path; defaults to SLATE_TERM_SOCKET.") var socket: String?
    @Flag(help: "Emit JSON (currently also the default output format).") var json = false

    func call(_ method: String, params: [String: JSONValue] = [:], timeoutSeconds: Int = 30) throws {
        try printJSON(request(method, params: params, timeoutSeconds: timeoutSeconds))
    }

    func request(_ method: String, params: [String: JSONValue] = [:], timeoutSeconds: Int = 30) throws -> JSONValue {
        guard let path = socket ?? ProcessInfo.processInfo.environment["SLATE_TERM_SOCKET"] else {
            throw ValidationError("Set SLATE_TERM_SOCKET or pass --socket. Run inside Slate Terminal for automatic discovery.")
        }
        let value: JSONValue
        do { value = try UnixClient(path: path, timeoutSeconds: timeoutSeconds).call(method, params: params) }
        catch let error as RPCFailure { throw ValidationError("\(error.message) (\(error.code))") }
        return value
    }
}

struct Target: ParsableArguments {
    @Option(help: "Explicit pane ID, e.g. p1.") var pane: String?
    @Option(help: "Explicit tab ID, e.g. t1.") var tab: String?
    @Flag(help: "Allow termination of foreground processes when closing.") var force = false
    var params: [String: JSONValue] {
        let environment = ProcessInfo.processInfo.environment
        var result: [String: JSONValue] = [:]
        if force { result["force"] = .bool(true) }
        if let pane = pane ?? (tab == nil ? environment["SLATE_TERM_PANE_ID"] : nil) { result["pane"] = .string(pane) }
        if let tab = tab ?? (pane == nil ? environment["SLATE_TERM_TAB_ID"] : nil) { result["tab"] = .string(tab) }
        return result
    }
}

struct Tabs: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create, list, close, or focus native tabs.")
    enum Action: String, ExpressibleByArgument { case list, new, close, focus }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    func run() throws {
        try connection.call(action == .list ? "tabs.list" : "command.run",
                            params: action == .list ? target.params : target.params.merging(["id": .string("tab.\(action.rawValue)")]) { _, new in new })
    }
}

struct Panes: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect or modify terminal panes.")
    enum Action: String, ExpressibleByArgument { case list, split, close, focus, send, capture, type }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    @Flag var left = false
    @Flag var right = false
    @Flag var up = false
    @Flag var down = false
    @Option(help: "Literal input text for send. No shell escaping is added.") var text: String?
    @Option(help: "New panel type for type: terminal, browser, or a registered type.") var type: String?
    @Option(help: "Require this terminal session for send/capture; rejects a replaced shell.") var sessionId: String?
    func run() throws {
        var params = target.params
        if let sessionId {
            guard action == .send || action == .capture else { throw ValidationError("session-id is only valid for send/capture") }
            params["sessionId"] = .string(sessionId)
        }
        switch action {
        case .type:
            guard let type else { throw ValidationError("type requires --type") }
            params["id"] = .string("pane.type")
            params["type"] = .string(type)
            try connection.call("command.run", params: params)
        case .list: try connection.call("panes.list", params: params)
        case .capture: try connection.call("panes.capture", params: params)
        case .send:
            guard let text else { throw ValidationError("send requires --text") }
            params["text"] = .string(text)
            try connection.call("panes.send", params: params)
        case .split:
            let directions = [(left, "left"), (right, "right"), (up, "up"), (down, "down")].filter(\.0)
            guard directions.count == 1 else { throw ValidationError("Choose exactly one of --left, --right, --up, --down") }
            params["id"] = .string("split.\(directions[0].1)")
            try connection.call("command.run", params: params)
        case .close, .focus:
            params["id"] = .string("pane.\(action.rawValue)")
            try connection.call("command.run", params: params)
        }
    }
}

struct TerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminal", abstract: "Generic terminal I/O and authenticated shell run/wait operations.")
    enum Action: String, ExpressibleByArgument { case send, key, capture, run, wait }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    @Option var scope: ContextCommand.Scope?
    @Option var sessionId: String?
    @Option var text: String?
    @Option var command: String?
    @Option(help: "Logical key, e.g. ctrl+c, alt+left, shift+tab; text entry uses send.") var key: String?
    @Option(help: "Wait for this literal screen text instead of a shell prompt.") var contains: String?
    @Option(help: "Require a later authenticated prompt sequence.") var afterSequence: Int?
    @Option(help: "Run/wait deadline in milliseconds, 1...295000; default 30000. Expiry does not stop the process.") var timeoutMilliseconds: Int?

    func run() throws {
        var params = target.params
        if let scope {
            params["scope"] = .string(scope.rawValue)
            if target.pane == nil, scope != .pane { params.removeValue(forKey: "pane") }
        }
        if let sessionId { params["sessionId"] = .string(sessionId) }
        if let text { params["text"] = .string(text) }
        if let command { params["command"] = .string(command) }
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
    static let configuration = CommandConfiguration(abstract: "Register trusted web panels. Registered pages can control your terminals.")
    enum Action: String, ExpressibleByArgument { case list, register, validate, unregister, status, restart, logs }
    @Argument var action: Action
    @Argument var id: String?
    @Option var manifest: String?
    @Option var instanceId: String?
    @Flag var replace = false
    @Flag var force = false
    @OptionGroup var connection: Connection
    func run() throws {
        var params: [String: JSONValue] = [:]
        if let id { params["id"] = .string(id) }
        if let instanceId { params["instanceId"] = .string(instanceId) }
        if force { params["force"] = .bool(true) }
        if replace { params["replace"] = .bool(true) }
        if action == .register || action == .validate {
            guard let manifest else { throw ValidationError("register and validate require --manifest") }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: manifest))
            defer { try? handle.close() }
            let registration = try PluginRegistration.parse(handle.read(upToCount: 262_145) ?? Data())
            if action == .validate {
                guard connection.socket == nil else { throw ValidationError("validate is offline; do not pass --socket") }
                try printJSON(.object(["valid": .bool(true), "registration": try .encoding(registration)]))
                return
            }
            params["manifest"] = try .encoding(registration)
        }
        try connection.call("plugins.\(action.rawValue)", params: params)
    }
}

struct Events: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Publish events or read a bounded, resumable event journal.")
    enum Action: String, ExpressibleByArgument { case head, emit, poll, watch }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @Option(help: "Exact topic or namespace wildcard; repeat to select multiple topics.") var topic: [String] = []
    @Option(help: "Resume after this cursor. Expired/restarted cursors require explicit resync.") var after: String?
    @Option(help: "JSON payload for emit; defaults to null.") var payload: String?
    @Option var tab: String?
    @Option var pane: String?
    @Option var targetInstanceId: String?
    @Option(help: "Maximum events per poll, 1...128.") var limit: Int?
    @Option(help: "Long-poll deadline, 0...25000 milliseconds; default 20000.") var waitMilliseconds: Int?

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let tab { params["tab"] = .string(tab) }
        if let pane { params["pane"] = .string(pane) }
        if action == .head {
            guard params.isEmpty, topic.isEmpty, after == nil, payload == nil, targetInstanceId == nil,
                  limit == nil, waitMilliseconds == nil else { throw ValidationError("head takes no event options") }
            try connection.call("events.head")
            return
        }
        if action == .emit {
            guard topic.count == 1, after == nil, limit == nil, waitMilliseconds == nil else {
                throw ValidationError("emit requires exactly one --topic and no polling options")
            }
            params["topic"] = .string(topic[0])
            if let payload { params["payload"] = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) }
            if let targetInstanceId { params["targetInstanceId"] = .string(targetInstanceId) }
            try connection.call("events.emit", params: params)
            return
        }
        guard payload == nil, targetInstanceId == nil else { throw ValidationError("payload and target-instance-id are only valid for emit") }
        if let after { params["after"] = .string(after) }
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
}

struct ContextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "context", abstract: "Read focus and active-terminal context.")
    enum Action: String, ExpressibleByArgument { case get }
    enum Scope: String, ExpressibleByArgument { case pane, tab, global }
    @Argument var action: Action = .get
    @Option var scope: Scope = .tab
    @OptionGroup var target: Target
    @OptionGroup var connection: Connection
    func run() throws {
        var params = target.params
        params["scope"] = .string(scope.rawValue)
        try connection.call("context.get", params: params)
    }
}

struct ShellCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "shell", abstract: "Shell integration and authenticated context reporting.")
    enum Action: String, ExpressibleByArgument { case update, integration; case runInput = "run-input" }
    enum State: String, ExpressibleByArgument { case prompt, running }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @Option var state: State?
    @Option var pid: Int?
    @Option var sequence: Int?
    @Option var cwd: String?
    @Option var command: String?
    @Option var exitCode: Int?
    @Flag var emptyBuffer = false
    func run() throws {
        if action == .integration { print(ShellIntegration.zshHooks); return }
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
        // Telemetry must not strand an interactive prompt if its host is gone.
        try connection.call("shell.update", params: params, timeoutSeconds: 1)
    }
}

struct BrowserCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "browser", abstract: "Control an embedded browser pane.")
    enum Action: String, ExpressibleByArgument { case get, navigate, eval, screenshot, snapshot, click, fill, select, scroll, wait }
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
        var params = target.params
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
        try connection.call("browser.\(action.rawValue)", params: params)
    }
}

struct LayoutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "layout", abstract: "Read the authoritative layout.")
    enum Action: String, ExpressibleByArgument { case get }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    func run() throws { try connection.call("layout.get", params: target.params) }
}

struct Commands: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "command", abstract: "Invoke the same commands as native menus.")
    enum Action: String, ExpressibleByArgument { case list, run }
    @Argument var action: Action
    @Argument var id: String?
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    func run() throws {
        var params = target.params
        if action == .run {
            guard let id else { throw ValidationError("command run requires an ID") }
            params["id"] = .string(id)
        }
        try connection.call("command.\(action.rawValue)", params: params, timeoutSeconds: id?.hasPrefix("plugin.") == true ? 300 : 30)
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Inspect, reload, or validate TOML configuration.")
    enum Action: String, ExpressibleByArgument { case get, reload, validate }
    @Argument var action: Action
    @Option(help: "File for offline validation; defaults to SLATE_TERM_CONFIG_FILE or ~/.config/slate-term/config.toml.") var file: String?
    @OptionGroup var connection: Connection
    func run() throws {
        if action != .validate {
            guard file == nil else { throw ValidationError("--file applies only to config validate") }
            try connection.call(action == .reload ? "command.run" : "config.get",
                                params: action == .reload ? ["id": .string("config.reload")] : [:])
            return
        }
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
