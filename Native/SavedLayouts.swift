import AppKit
import Combine
import SwiftUI
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
    var open: ((SavedLayoutDefinition, WorkspaceOperationContext) throws -> JSONValue)?
    var invoke: ((String, [String: JSONValue], WorkspaceOperationContext) throws -> JSONValue)?
    var onChange: (() -> Void)?
    private(set) var editorModel: SavedLayoutsModel?
    var showSettings: (() -> Void)?
    var isVisible: () -> Bool = { false }
    private var refreshTimer: Timer?
    var runDialog: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    init(directory: URL) {
        self.directory = directory
        // Child-file writes need rescanning; retain drafts and refresh only active UI.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible() else { return }
                self.refresh()
            }
        }
    }
    var usesDefaultLibrary: Bool {
        directory.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/slate-term/layouts").standardizedFileURL
    }
    var store: SavedLayoutStore { get throws { try SavedLayoutStore(directory: directory) } }
    func close() { refreshTimer?.invalidate(); refreshTimer = nil }

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
        case "layouts.open": allowed = ["id"]
        case "layouts.launcher": allowed = ["id", "path", "name", "icon"]
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
            guard let open, let definition = saved.definition else { throw RPCFailure(code: -32022, message: "Workspace is unavailable") }
            let problems = definition.problems(types: types())
            guard problems.isEmpty else { throw RPCFailure(code: -32602, message: problems.joined(separator: "\n")) }
            return try open(definition, operation)
        case "layouts.launcher":
            guard usesDefaultLibrary else { throw RPCFailure(code: -32602, message: "Spotlight launchers require the default ~/.config/slate-term/layouts library") }
            let saved = try entry()
            let path = try string("path")
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw RPCFailure(code: -32602, message: "path must be an absolute new .app destination") }
            guard let definition = saved.definition else { throw RPCFailure(code: -32602, message: "Layout is unavailable") }
            let options = try SavedLayoutLauncherOptions(name: params["name"] == nil ? definition.name : string("name"),
                                                        icon: params["icon"] == nil ? "slate" : string("icon"))
            try LayoutLauncher.create(at: URL(fileURLWithPath: path), layoutID: definition.id, name: options.name, icon: options.icon)
            return .object(["id": .string(definition.id.uuidString), "path": .string(path)])
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

    func makeEditorModel() throws -> SavedLayoutsModel {
        if let editorModel { return editorModel }
        let model = SavedLayoutsModel(store: try store) { [weak self] definition, revision in
            guard let self else { throw RPCFailure(code: -32022, message: "Layouts are unavailable") }
            return try self.save(definition, revision: revision)
        }
        model.createLauncher = { [weak self] id in
            try self?.createLauncher(id: id, operation: .init(origin: .native))
        }
        model.launcherUnavailable = usesDefaultLibrary ? nil : "Spotlight launchers require the default layout library."
        editorModel = model
        refresh()
        return model
    }
    func showEditor() throws {
        _ = try makeEditorModel()
        refresh()
        showSettings?()
    }
    func refresh() { editorModel?.types = types(); editorModel?.refresh(); onChange?() }

    private func request(_ method: String, params: [String: JSONValue], operation: WorkspaceOperationContext) throws -> JSONValue {
        // A modal loop can outlive its socket request even while the caller's service stays live.
        try Task.checkCancellation()
        guard let invoke else { throw RPCFailure(code: APIError.unavailable, message: "Workspace is unavailable") }
        return try invoke(method, params, operation)
    }

    func perform(_ command: String, source: LayoutSourceWindow? = nil, operation: WorkspaceOperationContext) throws {
        try operation.validateCaller()
        if command == "layouts.launcher", !usesDefaultLibrary {
            throw RPCFailure(code: -32602, message: "Spotlight launchers currently require the default ~/.config/slate-term/layouts library. Custom-config instances cannot be routed safely on a cold launch.")
        }
        switch command {
        case "layouts.edit": try showEditor()
        case "layouts.folder": NSWorkspace.shared.open(try store.directory)
        case "layouts.captureWindow": try captureWindow(source: source, operation: operation)
        case "layouts.openWindow", "layouts.launcher":
            let entries = try store.list().filter { $0.definition != nil && $0.diagnostic == nil }
            guard !entries.isEmpty else { try showEditor(); return }
            guard let index = choose(title: command == "layouts.launcher" ? "Create Spotlight Launcher" : "Open Layout in New Window", prompt: "Layout", choices: entries.map { $0.definition!.name }) else { return }
            let id = entries[index].definition!.id
            guard editorModel?.hasDraft(id: id) != true else { throw RPCFailure(code: -32602, message: "Save or revert this layout’s unsaved changes first") }
            if command == "layouts.launcher" { try createLauncher(id: id, operation: operation); return }
            _ = try request("layouts.open", params: ["id": .string(id.uuidString)], operation: operation)
        default: throw RPCFailure(code: -32601, message: "Unknown saved layout command")
        }
    }
    private func captureWindow(source: LayoutSourceWindow?, operation: WorkspaceOperationContext) throws {
        guard let source else { throw RPCFailure(code: -32602, message: "Choose a workspace window before saving a layout") }
        let alert = NSAlert()
        alert.messageText = "Save Window as Layout"
        alert.informativeText = "Save this window’s tabs and panes. Running commands and terminal history are not captured."
        alert.addButton(withTitle: "Save Layout"); alert.addButton(withTitle: "Cancel")
        let name = NSTextField(string: "Untitled Layout")
        name.placeholderString = "Layout Name"
        name.setAccessibilityLabel("Layout Name")
        let stack = NSStackView(views: [NSTextField(labelWithString: "Layout Name"), name])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 54)
        stack.widthAnchor.constraint(equalToConstant: 380).isActive = true
        name.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = name
        guard runDialog(alert) == .alertFirstButtonReturn else { return }
        let result = try request("layouts.capture", params: ["window": .string(source.id), "name": .string(name.stringValue),
                                "expectedWorkspaceRevision": .string(source.workspaceRevision)], operation: operation)
        try showEditor()
        editorModel?.select(result.object?["file"]?.string)
    }
    private func choose(title: String, prompt: String, choices: [String]) -> Int? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = prompt
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        let chooser = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 26), pullsDown: false)
        chooser.addItems(withTitles: choices); alert.accessoryView = chooser
        return alert.runModal() == .alertFirstButtonReturn ? chooser.indexOfSelectedItem : nil
    }
    private func createLauncher(id: UUID, operation: WorkspaceOperationContext) throws {
        guard usesDefaultLibrary else { throw RPCFailure(code: -32602, message: "Spotlight launchers require the default layout library") }
        guard editorModel?.hasDraft(id: id) != true else { throw RPCFailure(code: -32602, message: "Save or revert this layout’s unsaved changes first") }
        let entry = try store.get(id: id)
        guard let definition = entry.definition else { throw RPCFailure(code: -32602, message: "Layout is unavailable") }
        let dialog = LayoutLauncherDialog(name: definition.name)
        guard runDialog(dialog.alert) == .alertFirstButtonReturn else { return }
        let options = try SavedLayoutLauncherOptions(name: dialog.name.stringValue, icon: dialog.selection.icon)
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        try Task.checkCancellation()
        try operation.validateCaller()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(options.name + ".app")
        _ = try request("layouts.launcher", params: ["id": .string(id.uuidString), "path": .string(url.path),
                        "name": .string(options.name), "icon": .string(options.icon)], operation: operation)
    }
}

@MainActor
enum LayoutLauncher {
    static func create(at destination: URL, layoutID: UUID, name: String, icon: String = "slate") throws {
        let options = try SavedLayoutLauncherOptions(name: name, icon: icon)
        guard destination.pathExtension == "app", !FileManager.default.fileExists(atPath: destination.path) else {
            throw RPCFailure(code: -32602, message: "Choose a new .app destination; existing launchers are not overwritten")
        }
        let manager = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".slate-launcher-\(UUID().uuidString).app")
        try manager.createDirectory(at: staging.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/slate-layout-launcher"), to: staging.appendingPathComponent("Contents/MacOS/Launcher"))
        let resources = staging.appendingPathComponent("Contents/Resources")
        try manager.createDirectory(at: resources, withIntermediateDirectories: true)
        try iconData(symbol: options.icon).write(to: resources.appendingPathComponent("LayoutIcon.icns"))
        let info: [String: Any] = ["CFBundleExecutable": "Launcher", "CFBundleName": options.name, "CFBundleDisplayName": options.name,
                                  "CFBundleIconFile": "LayoutIcon", "SlateLauncherIcon": options.icon,
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
    private static func iconData(symbol: String) throws -> Data {
        var chunks = Data()
        func integer(_ value: Int) -> Data {
            var value = UInt32(value).bigEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        for (size, kind) in [(128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
                if symbol == "slate" {
                    NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath).draw(in: bounds)
                    return true
                }
                let tile = bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08)
                NSColor(calibratedRed: 0.22, green: 0.28, blue: 0.40, alpha: 1).setFill()
                NSBezierPath(roundedRect: tile, xRadius: bounds.width * 0.19, yRadius: bounds.height * 0.19).fill()
                let config = NSImage.SymbolConfiguration(pointSize: bounds.width * 0.44, weight: .medium)
                    .applying(.init(paletteColors: [.white]))
                if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let scale = min(bounds.width * 0.5 / glyph.size.width, bounds.height * 0.5 / glyph.size.height)
                    let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
                    glyph.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                          width: size.width, height: size.height))
                }
                return true
            }
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw RPCFailure(code: -32000, message: "Could not render the launcher icon")
            }
            chunks.append(Data(kind.utf8)); chunks.append(integer(png.count + 8)); chunks.append(png)
        }
        return Data("icns".utf8) + integer(chunks.count + 8) + chunks
    }

}

@MainActor
final class LayoutLauncherIconSelection: ObservableObject {
    @Published var icon = "slate"
}

@MainActor
final class LayoutLauncherDialog {
    let alert = NSAlert()
    let name: NSTextField
    let selection = LayoutLauncherIconSelection()

    init(name: String) {
        self.name = NSTextField(string: name)
        self.name.placeholderString = "Launcher Name"
        self.name.setAccessibilityLabel("Launcher Name")
        alert.messageText = "Create Spotlight Launcher"
        alert.informativeText = "Open this layout from Spotlight. The launcher will be saved in ~/Applications."
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        let icons = NSHostingView(rootView: LayoutLauncherIconPicker(selection: selection))
        let stack = NSStackView(views: [NSTextField(labelWithString: "Name"), self.name,
                                      NSTextField(labelWithString: "Icon"), icons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 244)
        stack.widthAnchor.constraint(equalToConstant: 360).isActive = true
        self.name.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        icons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        icons.heightAnchor.constraint(equalToConstant: 168).isActive = true
        alert.accessoryView = stack
        alert.window.initialFirstResponder = self.name
    }
}

private struct LayoutLauncherIconPicker: View {
    @ObservedObject var selection: LayoutLauncherIconSelection
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(Array(SavedLayoutLauncherOptions.icons.enumerated()), id: \.element) { index, icon in
                Button { selection.icon = icon } label: {
                    Group {
                        if icon == "slate" {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                                .resizable().interpolation(.high).frame(width: 34, height: 34)
                        } else {
                            Image(systemName: icon).font(.system(size: 22, weight: .medium))
                        }
                    }.frame(maxWidth: .infinity).frame(height: 48)
                        .foregroundStyle(selection.icon == icon ? Color.accentColor : .secondary)
                        .background(selection.icon == icon ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection.icon == icon ? Color.accentColor : .clear, lineWidth: 2))
                }.buttonStyle(.plain).accessibilityLabel(SavedLayoutLauncherOptions.iconNames[index])
                    .accessibilityAddTraits(selection.icon == icon ? .isSelected : [])
                    .help(SavedLayoutLauncherOptions.iconNames[index])
            }
        }.padding(2)
    }
}
