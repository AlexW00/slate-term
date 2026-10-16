import ArgumentParser
import Foundation
import SlateTermCore

struct NotifyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "notify", abstract: "Post an ephemeral notification anchored to the launching pane, if available.")
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    @Option var title: String
    @Option var body = ""
    @Option(help: "Replace the outstanding notification with this key from the same source and lifetime.") var key: String?
    @Option(help: "Require this terminal session at the selected pane.") var sessionId: String?
    func run() throws {
        guard !target.force else { throw ValidationError("notify does not accept --force") }
        var params = try target.params(connection: connection)
        if target.active { params["active"] = .bool(true) }
        if let sessionId { params["expectedAnchorSessionId"] = .string(sessionId) }
        params["title"] = .string(title); params["body"] = .string(body)
        if let key { params["key"] = .string(key) }
        try connection.call("notifications.post", params: params)
    }
}

struct NotificationsCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "notifications", abstract: "Inspect or dismiss outstanding notifications; navigate to their sources.")
    enum Action: String, ExpressibleByArgument { case list, status, dismiss, next, open }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @Option(help: "Notification ID for dismiss or open.") var id: String?
    @Flag(help: "Dismiss all outstanding notifications.") var all = false
    func run() throws {
        switch action {
        case .list, .status, .next:
            guard id == nil, !all else { throw ValidationError("list/status/next take no selection flags") }
            if action == .next { try connection.call("command.run", params: ["id": .string("notifications.next")]) }
            else { try connection.call("notifications.\(action.rawValue)") }
        case .dismiss:
            guard (id != nil) != all else { throw ValidationError("dismiss requires exactly one of --id or --all") }
            try connection.call("notifications.dismiss", params: id.map { ["id": .string($0)] } ?? ["all": .bool(true)])
        case .open:
            guard let id, !all else { throw ValidationError("open requires --id") }
            try connection.call("command.run", params: ["id": .string("notifications.open"), "notificationId": .string(id)])
        }
    }
}
