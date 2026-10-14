import ArgumentParser
import Foundation
import SlateTermCore

struct APICLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "api", abstract: "Discover supported production methods and safety contracts.")
    enum Action: String, ExpressibleByArgument { case describe }
    @Argument var action: Action = .describe
    @OptionGroup var connection: Connection
    func run() throws { try connection.call("api.describe") }
}

struct WorkspaceCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "workspace", abstract: "Read authoritative topology or bounded revision-consistent inspection pages.")
    enum Action: String, ExpressibleByArgument { case get, snapshot }
    @Argument var action: Action = .snapshot
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    @Option var scope: ContextCommand.Scope = .global
    @Option var cursor: String?
    @Option var limit: Int?
    func run() throws {
        var params = try target.params(connection: connection, inheritingTarget: scope != .global)
        if action == .snapshot {
            params["scope"] = .string(scope.rawValue)
            if let cursor { params["cursor"] = .string(cursor) }
            if let limit { params["limit"] = .integer(limit) }
        }
        try connection.call("workspace.\(action.rawValue)", params: params)
    }
}
