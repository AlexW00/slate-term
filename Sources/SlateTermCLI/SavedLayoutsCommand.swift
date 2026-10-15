import ArgumentParser
import Foundation
import SlateTermCore

struct SavedLayoutsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "layouts", abstract: "Inspect, edit, capture and open file-backed saved layouts.")
    enum Action: String, CaseIterable, ExpressibleByArgument {
        case list, get, fields, validate, create, update, windows, capture, open, configuration, startupStatus = "startup-status"
        var method: String {
            if self == .configuration { return "layout.configuration" }
            return "layouts." + (self == .startupStatus ? "startupStatus" : rawValue)
        }
    }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @Option(help: "Saved layout UUID (get/open).") var id: String?
    @Option(help: "Inspect fields for one pane type, e.g. terminal or a plugin ID.") var type: String?
    @Option(help: "JSON definition file (validate/create/update).") var file: String?
    @Option(help: "Document revision from get; required for update.") var expectedSavedLayoutRevision: String?
    @Option(help: "Workspace revision from layouts windows; required when replacing a window group.") var expectedWorkspaceRevision: String?
    @Option(help: "Explicit pane for configuration; page callers may default to their own pane.") var pane: String?
    @Option(help: "Opaque window-group ID from layouts windows, not window list; required for capture.") var window: String?
    @Option(help: "Name for the captured layout.") var name: String?
    @Option(help: "Explicit window to replace; omitted means a new window, never merge.") var replaceWindow: String?
    @Flag(help: "Allow termination of processes in the explicitly replaced window.") var force = false
    @Flag(help: "Include previously configured startup commands, not running shell commands.") var includeCommands = false
    @Flag(help: "Omit current terminal directories from capture.") var omitDirectories = false
    @Flag(help: "Omit current browser URLs from capture.") var omitUrls = false

    func run() throws {
        var params: [String: JSONValue] = [:]
        if let id { params["id"] = .string(id) }
        if let type { params["type"] = .string(type) }
        if let file {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 262_145) ?? Data()
            let definition = try SavedLayoutDefinition.parse(data)
            params["definition"] = try .encoding(definition)
        }
        if let expectedSavedLayoutRevision { params["expectedSavedLayoutRevision"] = .string(expectedSavedLayoutRevision) }
        if let expectedWorkspaceRevision { params["expectedWorkspaceRevision"] = .string(expectedWorkspaceRevision) }
        if let pane { params["pane"] = .string(pane) }
        if let window { params["window"] = .string(window) }
        if let name { params["name"] = .string(name) }
        if let replaceWindow { params["replaceWindow"] = .string(replaceWindow) }
        if force { params["force"] = .bool(true) }
        if includeCommands { params["includeCommands"] = .bool(true) }
        if omitDirectories { params["includeDirectories"] = .bool(false) }
        if omitUrls { params["includeURLs"] = .bool(false) }
        // No inherited pane/tab hints: capture and replacement always require explicit window groups.
        try connection.call(action.method, params: params)
    }
}
