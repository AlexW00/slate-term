import ArgumentParser
import SlateTermCore

struct WarningsCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "warnings", abstract: "Set native warning preferences without changing API destructive-operation consent.")
    enum Kind: String, ExpressibleByArgument { case close, type }
    @Argument var kind: Kind
    @Option(help: "Suppress native warnings: true or false.") var suppressed: Bool
    @OptionGroup var connection: Connection
    func run() throws {
        try connection.call("command.run", params: ["id": .string("warnings.\(kind.rawValue).set"), "suppressed": .bool(suppressed)])
    }
}
