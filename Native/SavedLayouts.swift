import AppKit
import SlateTermCore
import SlateTermSettings

struct LayoutSourceWindow: Codable, Identifiable {
    let id: String
    let title: String
    let tabs: [String]
    let groupId: String
    let windowIds: [String]
    let workspaceRevision: String
}

/// Shared file operations for the editor, command picker, CLI and registered page bridge.
@MainActor
final class SavedLayouts {
    let directory: URL
    var types: () -> [SavedLayoutPaneType] = { [] }
    var windows: () -> [LayoutSourceWindow] = { [] }
    var capture: ((String, Bool, Bool, Bool) throws -> SavedLayoutDefinition)?
    var open: ((SavedLayoutDefinition, String?, Bool, WorkspaceOperationContext) throws -> JSONValue)?
    var invoke: ((String, [String: JSONValue], WorkspaceOperationContext) throws -> JSONValue)?
    var onChange: (() -> Void)?
    private(set) var editor: SavedLayoutsWindowController?
    private var refreshTimer: Timer?

    init(directory: URL) { self.directory = directory }
    var usesDefaultLibrary: Bool {
        directory.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/slate-term/layouts").standardizedFileURL
    }
    var store: SavedLayoutStore { get throws { try SavedLayoutStore(directory: directory) } }
    func close() { refreshTimer?.invalidate(); refreshTimer = nil; editor?.close() }

    func call(_ method: String, params: [String: JSONValue], operation: WorkspaceOperationContext) throws -> JSONValue {
        try operation.validateCaller()
        let allowed: Set<String>
        switch method {
        case "layouts.list", "layouts.windows": allowed = []
        case "layouts.fields": allowed = ["type"]
        case "layouts.get": allowed = ["id"]
        case "layouts.validate", "layouts.create": allowed = ["definition"]
        case "layouts.update": allowed = ["definition", "expectedSavedLayoutRevision"]
        case "layouts.capture": allowed = ["window", "name", "includeDirectories", "includeURLs", "includeCommands"]
        case "layouts.open": allowed = ["id", "replaceWindow", "force"]
        default: throw RPCFailure(code: -32601, message: "Unknown saved layout operation")
        }
        guard params.keys.allSatisfy(allowed.contains) else { throw RPCFailure(code: -32602, message: "Unknown parameter for \(method)") }
        func string(_ key: String) throws -> String {
            guard let value = params[key]?.string, !value.isEmpty else { throw RPCFailure(code: -32602, message: "\(key) is required") }
            return value
        }
        func flag(_ key: String, default fallback: Bool) throws -> Bool {
            guard let value = params[key] else { return fallback }
            guard case .bool(let value) = value else { throw RPCFailure(code: -32602, message: "\(key) must be a boolean") }
            return value
        }
        func definition() throws -> SavedLayoutDefinition {
            guard let value = params["definition"] else { throw RPCFailure(code: -32602, message: "definition is required") }
            return try SavedLayoutDefinition.parse(JSONEncoder().encode(value))
        }
        func entry() throws -> SavedLayoutEntry {
            guard let id = UUID(uuidString: try string("id")) else { throw RPCFailure(code: -32602, message: "id must be a layout UUID") }
            return try store.get(id: id)
        }
        switch method {
        case "layouts.list":
            // Keep catalog responses bounded: full recipes are available through get.
            return .array(try store.list().map { entry in
                .object(["file": .string(entry.file), "id": entry.definition.map { .string($0.id.uuidString) } ?? .null,
                         "name": entry.definition.map { .string(Self.summary($0.name, bytes: 512)) } ?? .null, "revision": entry.revision.map(JSONValue.string) ?? .null,
                         "diagnostics": .array(([entry.diagnostic].compactMap { $0 } + (entry.definition?.problems(types: types()) ?? [])).prefix(3).map { .string(Self.summary($0, bytes: 256)) })])
            })
        case "layouts.get": return try .encoding(entry())
        case "layouts.fields":
            let available = types()
            let result: [SavedLayoutPaneType]
            if params["type"] != nil {
                let id = try string("type")
                guard let type = available.first(where: { $0.id == id }) else { throw RPCFailure(code: -32602, message: "Pane type is unavailable: \(id)") }
                result = [type]
            } else { result = available }
            guard try JSONEncoder().encode(result).count < 900_000 else {
                throw RPCFailure(code: -32602, message: "Schemas exceed the response limit; request one type with the type parameter. Available IDs: " + available.map(\.id).joined(separator: ", "))
            }
            return try .encoding(result)
        case "layouts.windows": return try .encoding(windows())
        case "layouts.validate":
            let definition = try definition()
            let problems = definition.problems(types: types())
            return .object(["valid": .bool(problems.isEmpty), "diagnostics": .array(problems.map(JSONValue.string))])
        case "layouts.create", "layouts.update":
            let definition = try definition()
            let result = try save(definition, revision: method == "layouts.update" ? string("expectedSavedLayoutRevision") : nil)
            return try .encoding(result)
        case "layouts.capture":
            guard let capture else { throw RPCFailure(code: -32022, message: "Workspace is unavailable") }
            var definition = try capture(string("window"), flag("includeDirectories", default: true), flag("includeURLs", default: true), flag("includeCommands", default: false))
            definition.name = try string("name")
            return try .encoding(save(definition, revision: nil))
        case "layouts.open":
            let saved = try entry()
            if let value = params["replaceWindow"], value.string == nil { throw RPCFailure(code: -32602, message: "replaceWindow must be a window ID") }
            guard let open, let definition = saved.definition else { throw RPCFailure(code: -32022, message: "Workspace is unavailable") }
            let problems = definition.problems(types: types())
            guard problems.isEmpty else { throw RPCFailure(code: -32602, message: problems.joined(separator: "\n")) }
            return try open(definition, params["replaceWindow"]?.string, flag("force", default: false), operation)
        default: preconditionFailure("Operation checked above")
        }
    }

    private static func summary(_ text: String, bytes: Int) -> String {
        let printable = String(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined())
        return printable.utf8.count <= bytes ? printable : String(decoding: printable.utf8.prefix(bytes), as: UTF8.self) + "…"
    }

    func save(_ definition: SavedLayoutDefinition, revision: String?) throws -> SavedLayoutEntry {
        _ = try definition.validated()
        // Missing plugins stay editable without losing their opaque configuration.
        // Installed schemas are enforced for writes; all dependencies are required for opening.
        let known = Set(types().map(\.id))
        let problems = definition.problems(types: types()).filter { !$0.hasPrefix("Missing plugin:") }
        guard problems.isEmpty else { throw RPCFailure(code: -32602, message: problems.joined(separator: "\n")) }
        if revision == nil, definition.tabs.flatMap(\.panes).contains(where: { !known.contains($0.type) }) {
            throw RPCFailure(code: -32602, message: "Install the referenced plugins before creating this layout")
        }
        let entry = try revision.map { try store.update(definition, expectedRevision: $0) } ?? store.create(definition)
        onChange?()
        return entry
    }

    func showEditor() throws {
        if editor == nil {
            let model = SavedLayoutsModel(store: try store) { [weak self] definition, revision in
                guard let self else { throw RPCFailure(code: -32022, message: "Layouts are unavailable") }
                return try self.save(definition, revision: revision)
            }
            editor = SavedLayoutsWindowController(model: model)
            // A directory vnode does not report in-place writes to its children.
            // Rescan only while visible; save still checks exact content revisions.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.editor?.window?.isVisible == true else { return }
                    self.refresh()
                }
            }
        }
        refresh()
        editor?.showWindow(nil)
        editor?.window?.makeKeyAndOrderFront(nil)
    }
    func refresh() { editor?.model.types = types(); editor?.model.refresh(); onChange?() }

    private func request(_ method: String, params: [String: JSONValue], operation: WorkspaceOperationContext) throws -> JSONValue {
        // A modal loop can outlive its socket request even while the caller's service stays live.
        try Task.checkCancellation()
        guard let invoke else { throw RPCFailure(code: APIError.unavailable, message: "Workspace is unavailable") }
        return try invoke(method, params, operation)
    }

    func perform(_ command: String, operation: WorkspaceOperationContext) throws {
        try operation.validateCaller()
        if command == "layouts.launcher", !usesDefaultLibrary {
            throw RPCFailure(code: -32602, message: "Spotlight launchers currently require the default ~/.config/slate-term/layouts library. Custom-config instances cannot be routed safely on a cold launch.")
        }
        switch command {
        case "layouts.edit": try showEditor()
        case "layouts.folder": NSWorkspace.shared.open(try store.directory)
        case "layouts.captureWindow": try captureWindow(operation: operation)
        case "layouts.openWindow", "layouts.replaceWindow", "layouts.launcher":
            let entries = try store.list().filter { $0.definition != nil && $0.diagnostic == nil }
            guard !entries.isEmpty else { try showEditor(); return }
            guard let index = choose(title: command == "layouts.launcher" ? "Create Spotlight Launcher" : "Open Saved Layout", prompt: "Layout", choices: entries.map { $0.definition!.name }) else { return }
            let id = entries[index].definition!.id
            guard editor?.model.hasDraft(id: id) != true else { throw RPCFailure(code: -32602, message: "Save or revert this layout’s unsaved changes first") }
            if command == "layouts.launcher" { try createLauncher(id: id, operation: operation); return }
            var params: [String: JSONValue] = ["id": .string(id.uuidString)]
            if command == "layouts.replaceWindow" {
                let sources = windows()
                guard !sources.isEmpty else { throw RPCFailure(code: -32602, message: "No workspace windows are open") }
                guard let target = choose(title: "Replace a Window", prompt: "Window", choices: sources.map { "\($0.title) · \($0.tabs.count) tabs" }) else { return }
                let source = sources[target]
                // Always confirm replacement; the selected identity survives modal focus changes.
                let alert = NSAlert()
                alert.messageText = "Replace \(source.title)?"
                alert.informativeText = "Its panes and running processes will close."
                alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Replace")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                guard windows().contains(where: { $0.id == source.id && $0.tabs == source.tabs }) else { throw RPCFailure(code: -32022, message: "The selected window changed or closed; select it again") }
                params["replaceWindow"] = .string(source.id); params["force"] = .bool(true)
                params["expectedWorkspaceRevision"] = .string(source.workspaceRevision)
            }
            _ = try request("layouts.open", params: params, operation: operation)
        default: throw RPCFailure(code: -32601, message: "Unknown saved layout command")
        }
    }
    private func captureWindow(operation: WorkspaceOperationContext) throws {
        let sources = windows()
        guard !sources.isEmpty else { throw RPCFailure(code: -32602, message: "No workspace windows are open") }
        let alert = NSAlert()
        alert.messageText = "Save a Window as a Layout"
        alert.informativeText = "Choose the workspace window to capture. Running commands and terminal history are not captured."
        alert.addButton(withTitle: "Save Layout"); alert.addButton(withTitle: "Cancel")
        let chooser = NSPopUpButton(frame: .zero, pullsDown: false)
        chooser.addItems(withTitles: sources.map { "\($0.title) · \($0.tabs.count) tabs" })
        let name = NSTextField(string: "Untitled Layout")
        name.placeholderString = "Layout Name"
        let stack = NSStackView(views: [NSTextField(labelWithString: "Source Window"), chooser, NSTextField(labelWithString: "Layout Name"), name])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 110)
        chooser.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        name.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let source = sources[chooser.indexOfSelectedItem]
        let result = try request("layouts.capture", params: ["window": .string(source.id), "name": .string(name.stringValue),
                                "expectedWorkspaceRevision": .string(source.workspaceRevision)], operation: operation)
        try showEditor()
        editor?.model.select(result.object?["file"]?.string)
    }
    private func choose(title: String, prompt: String, choices: [String]) -> Int? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = prompt
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        let chooser = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26), pullsDown: false)
        chooser.addItems(withTitles: choices); alert.accessoryView = chooser
        return alert.runModal() == .alertFirstButtonReturn ? chooser.indexOfSelectedItem : nil
    }
    private func createLauncher(id: UUID, operation: WorkspaceOperationContext) throws {
        let entry = try store.get(id: id)
        let panel = NSSavePanel()
        panel.title = "Create Spotlight Launcher"
        panel.message = "This shortcut opens the latest saved layout in Slate Terminal. Slate must remain installed."
        panel.nameFieldStringValue = (entry.definition?.name ?? "Layout") + ".app"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try Task.checkCancellation()
        try operation.validateCaller()
        try LayoutLauncher.create(at: url, layoutID: id, name: entry.definition!.name)
    }
}

@MainActor
enum LayoutLauncher {
    static func create(at destination: URL, layoutID: UUID, name: String) throws {
        guard destination.pathExtension == "app", !FileManager.default.fileExists(atPath: destination.path) else {
            throw RPCFailure(code: -32602, message: "Choose a new .app destination; existing launchers are not overwritten")
        }
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".slate-launcher-\(UUID().uuidString).app")
        try manager.createDirectory(at: staging.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/slate-layout-launcher"), to: staging.appendingPathComponent("Contents/MacOS/Launcher"))
        let info: [String: Any] = ["CFBundleExecutable": "Launcher", "CFBundleName": name, "CFBundleDisplayName": name,
                                  "CFBundleIdentifier": "com.slateterm.layout.\(layoutID.uuidString.lowercased())", "CFBundlePackageType": "APPL",
                                  "CFBundleVersion": "1", "LSUIElement": true, "SlateLayoutID": layoutID.uuidString,
                                  "SlateApplicationPath": Bundle.main.bundlePath, "SlateApplicationID": Bundle.main.bundleIdentifier ?? ""]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: staging.appendingPathComponent("Contents/Info.plist"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", staging.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RPCFailure(code: -32000, message: "Could not sign the local layout launcher") }
        try manager.moveItem(at: staging, to: destination)
    }
}
