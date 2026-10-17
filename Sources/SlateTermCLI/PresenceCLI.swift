import ArgumentParser
import Foundation
import SlateTermCore

struct PresenceCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "presence",
        abstract: "Keep an agent tag on a pane across many calls, release it, or list current agent activity.",
        discussion: "hold and release need an agent name from SLATE_TERM_ACTOR or --actor. A hold expires after --ttl seconds unless that agent keeps calling the pane.")
    enum Action: String, ExpressibleByArgument { case hold, release, list }
    @Argument var action: Action
    @Option(help: "Explicit pane ID, e.g. p1. Required for hold and release.") var pane: String?
    @Option(help: "Seconds before a hold expires without calls, 1–600. Default 60.") var ttl: Double?
    @OptionGroup var connection: Connection
    func run() throws {
        switch action {
        case .list:
            guard pane == nil, ttl == nil else { throw ValidationError("presence list takes no --pane or --ttl") }
            try connection.call("presence.list")
        case .hold, .release:
            // A hold on the agent's own pane would be hidden, so the target is never inherited.
            guard let pane else { throw ValidationError("presence \(action.rawValue) requires --pane") }
            var params: [String: JSONValue] = ["pane": .string(pane)]
            if action == .hold, let ttl { params["ttlSeconds"] = .number(ttl) }
            else if ttl != nil { throw ValidationError("Only presence hold takes --ttl") }
            try connection.call("presence.\(action.rawValue)", params: params)
        }
    }
}
