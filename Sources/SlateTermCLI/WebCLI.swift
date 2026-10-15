import ArgumentParser
import Foundation
import SlateTermCore

struct WebCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "web", abstract: "Inspect and interact with browser or registered-plugin documents.")
    enum Action: String, ExpressibleByArgument { case get, snapshot, click, fill, select, scroll, wait, screenshot }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    @Option(help: "Automation view identity from web get or pane inspection.") var expectedViewId: String?
    @Option(help: "Automation document identity; not a plugin bridge document ID.") var expectedDocumentId: String?
    @Option(help: "Unique main-document CSS selector; mutations also require both identity flags.") var selector: String?
    @Option(help: "Opaque view/document-bound element reference from a current snapshot.") var ref: String?
    @Option var text: String?
    @Option(help: "Select option value; repeat for multi-select.") var value: [String] = []
    @Option var x: Double?
    @Option var y: Double?
    @Option var maxElements: Int?
    @Option var state: String?
    @Option var timeoutMilliseconds: Int?
    @Option(help: "Absolute local PNG output path (administrative only).") var path: String?

    func run() throws {
        var params = try target.params(connection: connection)
        guard params["pane"] != nil else { throw ValidationError("web requires --pane or a launching pane; --tab/--active alone are not targets") }
        if let expectedViewId { params["expectedViewId"] = .string(expectedViewId) }
        if let expectedDocumentId { params["expectedDocumentId"] = .string(expectedDocumentId) }
        if let selector { params["selector"] = .string(selector) }
        if let ref { params["ref"] = .string(ref) }
        if let text { params["text"] = .string(text) }
        if action == .select || !value.isEmpty { params["values"] = .array(value.map(JSONValue.string)) }
        if let x { params["x"] = .number(x) }
        if let y { params["y"] = .number(y) }
        if let maxElements { params["maxElements"] = .integer(maxElements) }
        if let state { params["state"] = .string(state) }
        if let timeoutMilliseconds { params["timeoutMilliseconds"] = .integer(timeoutMilliseconds) }
        if let path { params["path"] = .string(path) }
        try connection.call("web.\(action.rawValue)", params: params)
    }
}
