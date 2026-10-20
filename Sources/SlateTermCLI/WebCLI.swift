import ArgumentParser
import Foundation
import SlateTermCore

struct WebCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "web", abstract: "Inspect and interact with browser or registered-plugin documents.")
    enum Action: String, CaseIterable, ExpressibleByArgument {
        case get, snapshot, click, fill, select, scroll, wait, screenshot, focus, key, check, setValue = "set-value"
        case dialog, respondDialog = "respond-dialog"
        case fileChooser = "file-chooser", chooseFiles = "choose-files", cancelFileChooser = "cancel-file-chooser"
        var method: String {
            switch self {
            case .respondDialog: "web.respondDialog"
            case .setValue: "web.setValue"
            case .fileChooser: "web.fileChooser"
            case .chooseFiles: "web.chooseFiles"
            case .cancelFileChooser: "web.cancelFileChooser"
            default: "web." + rawValue
            }
        }
    }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @OptionGroup var target: Target
    @Option(help: "Automation view identity from web get or pane inspection.") var expectedViewId: String?
    @Option(help: "Automation document identity; not a plugin bridge document ID.") var expectedDocumentId: String?
    @Option(help: "Unique main-document CSS selector; mutations also require both identity flags.") var selector: String?
    @Option(help: "Opaque view/document-bound element reference from a current snapshot.") var ref: String?
    @Option var text: String?
    @Option(help: "Synthetic web key/chord; not native hardware input.") var key: String?
    @Option(help: "Desired checkbox/radio state: true or false.") var checked: Bool?
    @Option(help: "Select option value; repeat for multi-select.") var value: [String] = []
    @Option var x: Double?
    @Option var y: Double?
    @Option var maxElements: Int?
    @Option var state: String?
    @Option var timeoutMilliseconds: Int?
    @Option(help: "Absolute local PNG output path.") var path: String?

    @Option var popupId: String?
    @Option var dialogId: String?
    @Option(name: .customLong("response"), help: "Dialog response: accept or dismiss.") var response: String?
    @Option(help: "Pending chooser identity from web file-chooser.") var chooserId: String?
    @Option(help: "Absolute local file path; repeat for multiple files.") var file: [String] = []

    func run() throws {
        var params = try target.params(connection: connection)
        guard params["pane"] != nil else { throw ValidationError("web requires --pane or a launching pane; --tab/--active alone are not targets") }
        if let popupId { params["popupId"] = .string(popupId) }
        if let dialogId { params["dialogId"] = .string(dialogId) }
        if let response { params["action"] = .string(response) }
        if let expectedViewId { params["expectedViewId"] = .string(expectedViewId) }
        if let expectedDocumentId { params["expectedDocumentId"] = .string(expectedDocumentId) }
        if let selector { params["selector"] = .string(selector) }
        if let ref { params["ref"] = .string(ref) }
        if let text { params["text"] = .string(text) }
        if let key { params["key"] = .string(key) }
        if let checked { params["checked"] = .bool(checked) }
        if action == .setValue {
            guard value.count == 1 else { throw ValidationError("set-value requires exactly one --value") }
            params["value"] = .string(value[0])
        } else if action == .select || !value.isEmpty { params["values"] = .array(value.map(JSONValue.string)) }
        if let x { params["x"] = .number(x) }
        if let y { params["y"] = .number(y) }
        if let maxElements { params["maxElements"] = .integer(maxElements) }
        if let state { params["state"] = .string(state) }
        if let timeoutMilliseconds { params["timeoutMilliseconds"] = .integer(timeoutMilliseconds) }
        if let chooserId { params["chooserId"] = .string(chooserId) }
        if action == .chooseFiles || !file.isEmpty { params["paths"] = .array(file.map(JSONValue.string)) }
        if let path { params["path"] = .string(path) }
        try connection.call(action.method, params: params)
    }
}
