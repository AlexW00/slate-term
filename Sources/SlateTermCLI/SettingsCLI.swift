import ArgumentParser
import Darwin
import Foundation
import SlateTermCore

struct AppearanceCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "appearance", abstract: "Read the resolved terminal colors and font, or persist application appearance without restarting terminals.")
    enum Action: String, ExpressibleByArgument { case get, set, light, dark, auto }
    @Argument var action: Action
    @Argument var mode: String?
    @OptionGroup var connection: Connection
    func run() throws {
        if action == .get {
            guard mode == nil else { throw ValidationError("appearance get takes no mode argument") }
            try connection.call("appearance.get")
            return
        }
        var params: [String: JSONValue] = ["id": .string("appearance.\(action.rawValue)")]
        if action == .set {
            guard let mode else { throw ValidationError("appearance set requires light, dark, or auto") }
            params["mode"] = .string(mode)
        } else if mode != nil { throw ValidationError("Only appearance set takes a mode argument") }
        try connection.call("command.run", params: params)
    }
}

struct AgentActivityCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "agent-activity", abstract: "Show, hide or toggle agent activity frames and tags on panes. Read the current value with config get.")
    enum Action: String, ExpressibleByArgument { case show, hide, toggle }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    func run() throws {
        try connection.call("command.run", params: ["id": .string("agents.activity.\(action.rawValue)")])
    }
}

struct PaletteCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "palette", abstract: "List palettes or import validated colors without activating them.")
    enum Action: String, ExpressibleByArgument { case list, `import`, set }
    @Argument var action: Action
    @Option var path: String?
    @Option var slot: String?
    @Option var name: String?
    @OptionGroup var connection: Connection
    func run() throws {
        switch action {
        case .list: try connection.call("palette.list")
        case .import:
            guard let path else { throw ValidationError("palette import requires --path") }
            try connection.call("palette.import", params: ["path": .string(path)])
        case .set:
            guard let slot, let name else { throw ValidationError("palette set requires --slot light|dark and --name") }
            try connection.call("command.run", params: ["id": .string("terminal.palette.set"), "slot": .string(slot), "name": .string(name)])
        }
    }
}

struct SkillCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "skill",
        abstract: "Set up, list, install or remove the Slate Terminal agent skill, or show it in Finder.",
        discussion: "setup interactively guides installation. install and uninstall take one or more --agent IDs; skill list shows the IDs and each agent's skills folder.")
    enum Action: String, ExpressibleByArgument { case setup, list, install, uninstall, reveal }
    @Argument var action: Action
    @Option(name: .customLong("agent"), help: "Agent ID, such as agents (the shared ~/.agents/skills) or claude. Repeat for several.") var agents: [String] = []
    @OptionGroup var connection: Connection
    func run() throws {
        switch action {
        case .setup:
            guard agents.isEmpty, !connection.json else {
                throw ValidationError("skill setup is interactive and takes no --agent or --json; use skill install --agent ID for automation")
            }
            guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                throw ValidationError("skill setup requires an interactive terminal; use skill install --agent ID for automation")
            }
            var bound = connection
            let descriptor = try connection.request("api.describe")
            guard let instance = descriptor.object?["appInstanceId"]?.string else {
                throw ValidationError("Host did not provide an app instance ID")
            }
            let environment = ProcessInfo.processInfo.environment
            if bound.expectedInstanceId == nil {
                let inherited = connection.socket == nil || connection.socket == environment["SLATE_TERM_SOCKET"]
                    ? environment["SLATE_TERM_INSTANCE_ID"] : nil
                bound.expectedInstanceId = inherited ?? instance
            }
            var size = winsize()
            let columns = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
            try SkillSetup.run(columns: columns, request: { try bound.request($0, params: $1) }, readInput: { Swift.readLine() }, write: {
                FileHandle.standardOutput.write(Data($0.utf8))
            })
        case .list, .reveal:
            guard agents.isEmpty else { throw ValidationError("skill \(action.rawValue) takes no --agent") }
            if action == .list { try connection.call("skills.list") }
            else { try connection.call("command.run", params: ["id": .string("skills.reveal")]) }
        case .install, .uninstall:
            guard !agents.isEmpty else { throw ValidationError("skill \(action.rawValue) requires at least one --agent") }
            let params: [String: JSONValue] = ["agents": .array(agents.map(JSONValue.string))]
            // Literal method names keep the CLI alias parity test meaningful.
            if action == .install { try connection.call("skills.install", params: params) }
            else { try connection.call("skills.uninstall", params: params) }
        }
    }
}
