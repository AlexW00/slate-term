import ArgumentParser
import SlateTermCore

struct UpdatesCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "updates",
        abstract: "Inspect, download, and explicitly install Slate updates.",
        discussion: "download, cancel, and install require --update-id from the current update snapshot. install also requires --confirm.")
    @Argument var action: UpdateAction
    @Option(help: "Update ID from updates get; required for download, cancel, and install.") var updateId: String?
    @Flag(help: "Explicitly authorize installation and relaunch; only valid with install.") var confirm = false
    @OptionGroup var connection: Connection

    var request: (method: String, params: [String: JSONValue]) {
        get throws {
            var params: [String: JSONValue] = [:]
            if let updateId { params["updateId"] = .string(updateId) }
            if confirm { params["confirm"] = .bool(true) }
            if let instance = connection.expectedInstanceId { params["expectedInstanceId"] = .string(instance) }
            _ = try UpdateRequest(action: action, params: params)
            return (action.method, params)
        }
    }

    mutating func validate() throws { _ = try request }

    func run() throws {
        let request = try request
        try connection.call(request.method, params: request.params)
    }
}

extension UpdateAction: ExpressibleByArgument {}
