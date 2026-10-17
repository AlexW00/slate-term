import ArgumentParser
import Foundation
import SlateTermCore

struct PresenceCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "presence",
        abstract: "List agent activity, hold/release a pill, or focus its originating terminal.",
        discussion: "hold and release need SLATE_TERM_ACTOR or --actor. focus requires --activity-id and is a no-op without a live Slate terminal origin.")
    enum Action: String, CaseIterable, ExpressibleByArgument { case hold, release, list, focus }
    @Argument var action: Action
    @Option(help: "Explicit pane ID, e.g. p1. Required for hold and release.") var pane: String?
    @Option(help: "Seconds before a hold expires without calls, 1–600. Default 60.") var ttl: Double?
    @Option(help: "Activity ID from presence list. Required for focus.") var activityId: String?
    @OptionGroup var connection: Connection

    var request: (method: String, params: [String: JSONValue]) {
        get throws {
            switch action {
            case .list:
                guard pane == nil, ttl == nil, activityId == nil else { throw ValidationError("presence list takes no target arguments") }
                return ("presence.list", [:])
            case .focus:
                guard pane == nil, ttl == nil, let activityId else { throw ValidationError("presence focus requires --activity-id, without --pane or --ttl") }
                _ = try PresenceFocusRequest(["activityId": .string(activityId)])
                return ("presence.focus", ["activityId": .string(activityId)])
            case .hold, .release:
                // A hold on the agent's own pane would be hidden; never inherit its target.
                guard let pane, activityId == nil else { throw ValidationError("presence \(action.rawValue) requires --pane, without --activity-id") }
                var params: [String: JSONValue] = ["pane": .string(pane)]
                if action == .hold, let ttl { params["ttlSeconds"] = .number(ttl) }
                else if ttl != nil { throw ValidationError("Only presence hold takes --ttl") }
                return ("presence.\(action.rawValue)", params)
            }
        }
    }

    func run() throws {
        let request = try request
        try connection.call(request.method, params: request.params)
    }
}
