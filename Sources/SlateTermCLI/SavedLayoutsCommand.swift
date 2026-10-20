import ArgumentParser
import Foundation
import SlateTermCore

struct SavedLayoutsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "layouts", abstract: "Inspect, edit, capture and open file-backed saved layouts.")
    enum Action: String, CaseIterable, ExpressibleByArgument {
        case list, get, fields, validate, create, update, windows, capture, open, launcher, configuration, startupStatus = "startup-status", restoreOriginal = "restore-original"
        var method: String {
            if self == .restoreOriginal { return "layouts.restoreOriginal" }
            if self == .configuration { return "layout.configuration" }
            return "layouts." + (self == .startupStatus ? "startupStatus" : rawValue)
        }
    }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @Option(help: "Saved layout UUID (get/open/launcher).") var id: String?
    @Option(help: "preserve (default) or new for open.") var focusPolicy: String?
    @Option(help: "Inspect fields for one pane type, e.g. terminal or a plugin ID.") var type: String?
    @Option(help: "JSON definition file (validate/create/update).") var file: String?
    @Option(help: "Document revision from get; required for update.") var expectedSavedLayoutRevision: String?
    @Option(help: "Optional workspace revision guard for capture/open.") var expectedWorkspaceRevision: String?
    @Option(help: "Explicit pane for configuration; page callers may default to their own pane.") var pane: String?
    @Option(help: "Opaque window-group ID from layouts windows, not window list; required for capture.") var window: String?
    @Option(help: "Name for the captured layout or launcher.") var name: String?
    @Option(help: "New absolute .app destination for launcher creation; never overwritten.") var path: String?
    @Option(help: "Launcher icon from api.describe savedLayouts.launcherIcons.") var icon: String?
    @Flag(inversion: .prefixedNo, help: "Copy plugin data once into the new app (launcher only; defaults on).") var copyPluginData = true
    @Flag(help: "Terminate running processes when restoring the layout app’s original layout.") var force = false
    @Flag(help: "Include previously configured startup commands, not running shell commands.") var includeCommands = false
    @Flag(help: "Omit current terminal directories from capture.") var omitDirectories = false
    @Flag(help: "Omit current browser URLs from capture.") var omitUrls = false

    func validate() throws {
        if force && action != .restoreOriginal { throw ValidationError("--force requires restore-original") }
    }

    func run() throws {
        var params: [String: JSONValue] = [:]
        if force { params["force"] = .bool(true) }
        if let id { params["id"] = .string(id) }
        if let focusPolicy {
            guard action == .open else { throw ValidationError("--focus-policy requires open") }
            params["focus"] = .string(focusPolicy)
        }
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
        if let icon { params["icon"] = .string(icon) }
        if let path { params["path"] = .string(path) }
        if includeCommands { params["includeCommands"] = .bool(true) }
        if omitDirectories { params["includeDirectories"] = .bool(false) }
        if omitUrls { params["includeURLs"] = .bool(false) }
        if action == .launcher { params["copyPluginData"] = .bool(copyPluginData) }
        else if !copyPluginData { throw ValidationError("--no-copy-plugin-data requires launcher") }
        // No inherited pane/tab hints: capture requires an explicit window group; open creates a new one.
        try connection.call(action.method, params: params)
    }
}
