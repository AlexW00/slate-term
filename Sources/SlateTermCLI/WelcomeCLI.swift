import ArgumentParser
import Foundation
import SlateTermCore

struct WelcomeCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "welcome",
        abstract: "Show Slate's welcome message, mark it read, or re-enable it in future terminal sessions.")
    @Flag(help: "Persist acknowledgement and remove current native welcome messages.") var read = false
    @Flag(name: [.long, .customLong("reset")], help: "Mark unread and re-enable the welcome message for future terminal sessions; does not reopen existing messages.") var unread = false
    @OptionGroup var connection: Connection

    mutating func validate() throws {
        guard !(read && unread) else { throw ValidationError("Choose either --read or --unread/--reset, not both.") }
    }

    var request: (method: String, params: [String: JSONValue]) {
        if read { return ("command.run", ["id": .string("welcome.read")]) }
        if unread { return ("command.run", ["id": .string("welcome.unread")]) }
        return ("welcome.get", [:])
    }

    func run() throws {
        if connection.json { try connection.call(request.method, params: request.params); return }
        let value = try connection.request(request.method, params: request.params)
        if read { print("Welcome message marked as read. New terminal sessions will open without it."); return }
        if unread { print("Welcome message marked as unread; re-enabled for future terminal sessions."); return }
        let snapshot = try JSONDecoder().decode(WelcomeSnapshot.self, from: JSONEncoder().encode(value))
        print(snapshot.content.text, terminator: "")
    }
}
