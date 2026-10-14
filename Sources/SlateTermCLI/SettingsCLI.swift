import ArgumentParser
import SlateTermCore

struct AppearanceCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "appearance", abstract: "Persist application appearance without restarting terminals.")
    enum Action: String, ExpressibleByArgument { case set, light, dark, auto }
    @Argument var action: Action
    @Argument var mode: String?
    @OptionGroup var connection: Connection
    func run() throws {
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
