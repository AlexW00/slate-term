import AppKit
import UniformTypeIdentifiers
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
    var open: ((SavedLayoutDefinition, Bool, WorkspaceOperationContext) throws -> JSONValue)?
    var invoke: ((String, [String: JSONValue], WorkspaceOperationContext) throws -> JSONValue)?
    var invokeAsync: ((String, [String: JSONValue], WorkspaceOperationContext) async throws -> JSONValue)?
    private var launcherTask: Task<Void, Never>?
    private var launcherDialogBusy = false
    var onChange: (() -> Void)?
    private(set) var editorModel: SavedLayoutsModel?
    var showSettings: (() -> Void)?
    var layoutApps: LayoutApps?
    var isVisible: () -> Bool = { false }
    private var refreshTimer: Timer?
    var runDialog: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    var runSavePanel: (NSSavePanel) -> NSApplication.ModalResponse = { $0.runModal() }

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
        !ApplicationLaunchContext.current.isLayoutApp && (ProcessInfo.processInfo.environment["SLATE_TERM_INTEGRATION"] == "1" || directory.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/slate-term/layouts").standardizedFileURL)
    }
    var store: SavedLayoutStore { get throws { try SavedLayoutStore(directory: directory) } }
    func close() { refreshTimer?.invalidate(); refreshTimer = nil; launcherTask?.cancel(); launcherTask = nil }

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
        case "layouts.open": allowed = ["id", "focus"]
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
            let focus = params["focus"]?.string ?? "preserve"
            guard params["focus"] == nil || params["focus"]?.string != nil,
                  ["new", "preserve"].contains(focus) else { throw RPCFailure(code: -32602, message: "focus must be new or preserve") }
            return try open(definition, focus == "new", operation)
        default: preconditionFailure("Operation checked above")
        }
    }

    func callLauncher(params: [String: JSONValue], operation: WorkspaceOperationContext,
                      validate: @escaping @MainActor () throws -> Void) async throws -> JSONValue {
        try operation.validateCaller()
        try ApplicationLaunchContext.current.requireParent()
        guard usesDefaultLibrary else { throw RPCFailure(code: -32602, message: "Layout apps require the default layout library") }
        guard Set(params.keys).isSubset(of: ["id", "path", "name", "icon", "copyPluginData"]) else {
            throw RPCFailure(code: -32602, message: "Unknown parameter for layouts.launcher")
        }
        func string(_ key: String) throws -> String {
            guard let value = params[key]?.string, !value.isEmpty else { throw RPCFailure(code: -32602, message: "\(key) is required") }
            return value
        }
        guard let id = UUID(uuidString: try string("id")) else { throw RPCFailure(code: -32602, message: "id must be a layout UUID") }
        let saved = try store.get(id: id)
        let path = try string("path")
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw RPCFailure(code: -32602, message: "path must be an absolute new .app destination") }
        guard let definition = saved.definition else { throw RPCFailure(code: -32602, message: "Layout is unavailable") }
        let options = try SavedLayoutLauncherOptions(name: params["name"] == nil ? definition.name : string("name"),
                                                    icon: params["icon"] == nil ? "slate" : string("icon"))
        guard params["copyPluginData"] == nil || params["copyPluginData"] == .bool(true) || params["copyPluginData"] == .bool(false) else {
            throw RPCFailure(code: -32602, message: "copyPluginData must be a boolean")
        }
        guard let layoutApps else { throw RPCFailure(code: -32022, message: "App creation is unavailable") }
        return try await layoutApps.create(at: URL(fileURLWithPath: path), layoutID: id, name: options.name,
            icon: options.icon, copyPluginData: params["copyPluginData"] != .bool(false), operation: operation) { [weak self] in
                try validate()
                guard let self, try self.store.get(id: id).revision == saved.revision else {
                    throw RPCFailure(code: APIError.conflict, message: "The layout changed during app preparation; inspect it again")
                }
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
        model.parentManaged = ApplicationLaunchContext.current.isLayoutApp
        model.createLauncher = { [weak self, weak model] id in
            guard let self, self.launcherTask == nil else { return }
            self.launcherTask = Task { [weak self, weak model] in
                defer { self?.launcherTask = nil }
                do { try await self?.createLauncher(id: id, operation: .init(origin: .native)) }
                catch is CancellationError { }
                catch { model?.error = String(describing: error) }
            }
        }
        model.launcherUnavailable = usesDefaultLibrary ? nil : "Layout apps require the default layout library."
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
        switch command {
        case "layouts.edit": try showEditor()
        case "layouts.folder": NSWorkspace.shared.open(try store.directory)
        case "layouts.captureWindow": try captureWindow(source: source, operation: operation)
        case "layouts.openWindow":
            let entries = try store.list().filter { $0.definition != nil && $0.diagnostic == nil }
            guard !entries.isEmpty else { try showEditor(); return }
            guard let index = choose(title: "Open Layout in New Window", prompt: "Layout", choices: entries.map { $0.definition!.name }) else { return }
            let id = entries[index].definition!.id
            guard editorModel?.hasDraft(id: id) != true else { throw RPCFailure(code: -32602, message: "Save or revert this layout’s unsaved changes first") }
            _ = try request("layouts.open", params: ["id": .string(id.uuidString), "focus": .string("new")], operation: operation)
        default: throw RPCFailure(code: -32601, message: "Unknown saved layout command")
        }
    }
    func performLauncher(operation: WorkspaceOperationContext) async throws {
        guard !launcherDialogBusy else { throw RPCFailure(code: APIError.conflict, message: "App creation is already pending") }
        launcherDialogBusy = true
        defer { launcherDialogBusy = false }
        try operation.validateCaller()
        try ApplicationLaunchContext.current.requireParent()
        guard usesDefaultLibrary else { throw RPCFailure(code: -32602, message: "Layout apps require the default layout library") }
        let entries = try store.list().filter { $0.definition != nil && $0.diagnostic == nil }
        guard !entries.isEmpty else { try showEditor(); return }
        guard let index = choose(title: "Create App", prompt: "Layout", choices: entries.map { $0.definition!.name }) else { return }
        try await showLauncherDialog(id: entries[index].definition!.id, operation: operation)
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
    func createLauncher(id: UUID, operation: WorkspaceOperationContext) async throws {
        guard !launcherDialogBusy else { throw RPCFailure(code: APIError.conflict, message: "App creation is already pending") }
        launcherDialogBusy = true
        defer { launcherDialogBusy = false }
        try await showLauncherDialog(id: id, operation: operation)
    }

    private func showLauncherDialog(id: UUID, operation: WorkspaceOperationContext) async throws {
        try ApplicationLaunchContext.current.requireParent()
        guard usesDefaultLibrary else { throw RPCFailure(code: -32602, message: "Layout apps require the default layout library") }
        guard editorModel?.hasDraft(id: id) != true else { throw RPCFailure(code: -32602, message: "Save or revert this layout’s unsaved changes first") }
        let entry = try store.get(id: id)
        guard let definition = entry.definition else { throw RPCFailure(code: -32602, message: "Layout is unavailable") }
        guard let layoutApps else { throw RPCFailure(code: -32022, message: "App creation is unavailable") }
        let unavailable = try await layoutApps.creationUnavailablePlugins()
        try Task.checkCancellation()
        try operation.validateCaller()
        guard try store.get(id: id).revision == entry.revision else {
            throw RPCFailure(code: APIError.conflict, message: "The layout changed while preparing the dialog")
        }
        let dialog = LayoutLauncherDialog(name: definition.name, unavailablePlugins: unavailable)
        guard runDialog(dialog.alert) == .alertFirstButtonReturn else { return }
        func validateSource() throws {
            try Task.checkCancellation()
            try operation.validateCaller()
            guard try store.get(id: id).revision == entry.revision, editorModel?.hasDraft(id: id) != true else {
                throw RPCFailure(code: APIError.conflict, message: "The layout changed while the app dialog was open")
            }
        }
        try validateSource()
        let panel = NSSavePanel()
        panel.title = "Create App"
        panel.prompt = "Create"
        panel.nameFieldLabel = "App Name:"
        panel.nameFieldStringValue = definition.name + ".app"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        guard runSavePanel(panel) == .OK, let url = panel.url else { return }
        try validateSource()
        let options = try SavedLayoutLauncherOptions(name: url.deletingPathExtension().lastPathComponent,
                                                     icon: dialog.selection.icon)
        guard let invokeAsync else { throw RPCFailure(code: APIError.unavailable, message: "Workspace is unavailable") }
        _ = try await invokeAsync("layouts.launcher", ["id": .string(id.uuidString), "path": .string(url.path),
                        "name": .string(options.name), "icon": .string(options.icon), "copyPluginData": .bool(dialog.copyPluginData.state == .on)], operation)
    }
}

@MainActor
enum LayoutLauncher {
    static func iconData(symbol: String) throws -> Data {
        var chunks = Data()
        func integer(_ value: Int) -> Data {
            var value = UInt32(value).bigEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        for (size, kind) in [(128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
            let image = iconImage(symbol: symbol, size: CGFloat(size))
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw RPCFailure(code: -32000, message: "Could not render the app icon")
            }
            chunks.append(Data(kind.utf8)); chunks.append(integer(png.count + 8)); chunks.append(png)
        }
        return Data("icns".utf8) + integer(chunks.count + 8) + chunks
    }

    // Preview and packaged icons use the same drawing, including the Slate app icon.
    static func iconImage(symbol: String, size: CGFloat) -> NSImage {
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
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
    }

}

@MainActor
final class LayoutLauncherIconSelection {
    var icon = "slate" { didSet { onChange?() } }
    var onChange: (() -> Void)?
}

@MainActor
final class LayoutLauncherDialog {
    let alert = NSAlert()
    let preview = NSImageView()
    let selection = LayoutLauncherIconSelection()
    let copyPluginData = NSButton(checkboxWithTitle: "Copy plugin data from Slate Terminal", target: nil, action: nil)

    init(name: String, unavailablePlugins: [LayoutAppCreationPreflight.UnavailablePlugin] = []) {
        alert.messageText = "Create App"
        alert.informativeText = "Create an independent app from \(name). It follows Slate’s settings and plugins, with its own session, browser logins, and plugin data."
        copyPluginData.state = .on
        alert.addButton(withTitle: "Continue…"); alert.addButton(withTitle: "Cancel")
        preview.image = LayoutLauncher.iconImage(symbol: selection.icon, size: 256)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityLabel("App icon preview")
        preview.setAccessibilityIdentifier("layoutApp.iconPreview")
        preview.widthAnchor.constraint(equalToConstant: 96).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let selection = self.selection
        let icons = LayoutLauncherIconPicker(selection: selection) { [weak preview, weak selection] in
            guard let selection else { return }
            preview?.image = LayoutLauncher.iconImage(symbol: selection.icon, size: 256)
        }
        var views: [NSView] = [preview, NSTextField(labelWithString: "Icon"), icons, copyPluginData,
                               NSTextField(wrappingLabelWithString: "Data is copied once. Afterwards each app keeps its own changes.")]
        let unavailableListHeight = min(76, max(24, CGFloat(unavailablePlugins.count) * 18 + 8))
        if !unavailablePlugins.isEmpty {
            views.append(NSTextField(wrappingLabelWithString: "These plugins will not be copied. Layouts that require them cannot create an app."))
            let list = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: unavailableListHeight))
            list.string = unavailablePlugins.map(\.id).joined(separator: "\n")
            list.isEditable = false; list.isSelectable = true; list.drawsBackground = false
            list.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            list.textColor = .secondaryLabelColor
            list.isVerticallyResizable = true; list.isHorizontallyResizable = false
            list.textContainer?.widthTracksTextView = true
            list.setAccessibilityLabel("Unavailable plugins")
            list.toolTip = unavailablePlugins.map { "\($0.id): \($0.reason)" }.joined(separator: "\n")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: unavailableListHeight))
            scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = list
            scroll.widthAnchor.constraint(equalToConstant: 360).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: unavailableListHeight).isActive = true
            views.append(scroll)
        }
        for case let label as NSTextField in views where label.cell?.wraps == true {
            label.preferredMaxLayoutWidth = 360
            label.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        // Size the accessory from its wrapped content so it cannot crowd the alert description.
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 0, right: 12)
        stack.widthAnchor.constraint(equalToConstant: 384).isActive = true
        icons.widthAnchor.constraint(equalToConstant: 360).isActive = true
        icons.heightAnchor.constraint(equalToConstant: 168).isActive = true
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(NSSize(width: 384, height: ceil(stack.fittingSize.height)))
        alert.accessoryView = stack
        alert.window.initialFirstResponder = icons
    }
}

@MainActor
private final class LayoutLauncherIconPicker: NSView {
    private let selection: LayoutLauncherIconSelection
    private var buttons: [LayoutLauncherIconButton] = []
    override var isFlipped: Bool { true }

    init(selection: LayoutLauncherIconSelection, onChange: @escaping () -> Void) {
        self.selection = selection
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 168))
        for (index, icon) in SavedLayoutLauncherOptions.icons.enumerated() {
            let button = LayoutLauncherIconButton(icon: icon, name: SavedLayoutLauncherOptions.iconNames[index])
            button.target = self
            button.action = #selector(selectIcon(_:))
            addSubview(button)
            buttons.append(button)
        }
        // Native actions and selection updates must complete inside NSAlert's modal run loop.
        selection.onChange = { [weak self] in self?.updateSelection(); onChange() }
        updateSelection()
        needsLayout = true
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = (bounds.width - 4 - 16) / 3
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 2 + CGFloat(index % 3) * (width + 8),
                                  y: 4 + CGFloat(index / 3) * 56, width: width, height: 48)
        }
    }

    @objc private func selectIcon(_ sender: LayoutLauncherIconButton) {
        selection.icon = sender.icon
    }

    private func updateSelection() {
        for button in buttons {
            let selected = button.icon == selection.icon
            button.state = selected ? .on : .off
            button.setAccessibilitySelected(selected)
            button.needsDisplay = true
        }
    }
}

@MainActor
private final class LayoutLauncherIconButton: NSButton {
    let icon: String
    private let glyph: NSImage?

    init(icon: String, name: String) {
        self.icon = icon
        glyph = icon == "slate" ? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
            : NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .medium))
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.pushOnPushOff)
        setAccessibilityLabel(name)
        setAccessibilityIdentifier("layoutApp.icon.\(icon)")
        toolTip = name
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let tint = selected ? NSColor.controlAccentColor : NSColor.labelColor
        let background = selected ? NSColor.controlAccentColor.withAlphaComponent(0.12) : .quaternarySystemFill
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        if selected {
            tint.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            border.lineWidth = 2
            border.stroke()
        }
        let image = icon == "slate" ? glyph : glyph?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            .applying(.init(paletteColors: [tint])))
        if let image {
            let size = icon == "slate" ? NSSize(width: 34, height: 34) : image.size
            image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                 width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: isHighlighted ? 0.7 : 1,
                       respectFlipped: true, hints: nil)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
