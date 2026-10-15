import ArgumentParser
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
        abstract: "List, install or remove the Slate Terminal agent skill, or show it in Finder.",
        discussion: "install and uninstall take one or more --agent IDs; skill list shows the IDs and each agent's skills folder.")
    enum Action: String, ExpressibleByArgument { case list, install, uninstall, reveal }
    @Argument var action: Action
    @Option(name: .customLong("agent"), help: "Agent ID, such as agents (the shared ~/.agents/skills) or claude. Repeat for several.") var agents: [String] = []
    @OptionGroup var connection: Connection
    func run() throws {
        switch action {
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
