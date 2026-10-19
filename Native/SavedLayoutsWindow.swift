import AppKit
import Combine
import SwiftUI
import SlateTermCore
import SlateTermSettings

@MainActor
final class SavedLayoutsModel: ObservableObject {
    struct Draft {
        var definition: SavedLayoutDefinition
        let original: SavedLayoutDefinition
        let revision: String
        var dirty: Bool { definition != original }
    }
    @Published var entries: [SavedLayoutEntry] = []
    @Published var selection: String?
    @Published var selectedTab = 0
    @Published var selectedPane: PaneID?
    @Published var drafts: [String: Draft] = [:]
    @Published var types: [SavedLayoutPaneType] = []
    @Published var error: String?
    let store: SavedLayoutStore
    let saveDefinition: (SavedLayoutDefinition, String?) throws -> SavedLayoutEntry
    var didSave: (() -> Void)?
    var createLauncher: ((UUID) throws -> Void)?
    var launcherUnavailable: String?

    func makeLauncher() {
        guard let definition else { return }
        do { try createLauncher?(definition.id); error = nil }
        catch { self.error = layoutErrorText(error) }
    }

    init(store: SavedLayoutStore, save: @escaping (SavedLayoutDefinition, String?) throws -> SavedLayoutEntry) {
        self.store = store; saveDefinition = save
    }
    var entry: SavedLayoutEntry? { entries.first { $0.file == selection } }
    var draft: Draft? { selection.flatMap { drafts[$0] } }
    var definition: SavedLayoutDefinition? { draft?.definition }
    var tab: SavedLayoutTab? { definition.flatMap { $0.tabs.indices.contains(selectedTab) ? $0.tabs[selectedTab] : nil } }
    var pane: SavedLayoutPane? { tab?.panes.first { $0.id == selectedPane } }
    var isDirty: Bool { draft?.dirty == true }
    var hasUnsavedChanges: Bool { drafts.values.contains(where: \.dirty) }
    var conflict: Bool { draft != nil && entry?.revision != draft?.revision }

    func refresh() {
        do {
            var next = try store.list()
            // Deleted files with unsaved drafts remain selectable, never silently discarded.
            for entry in entries where drafts[entry.file]?.dirty == true && !next.contains(where: { $0.file == entry.file }) {
                next.append(SavedLayoutEntry(file: entry.file, diagnostic: "The source file was removed. Your unsaved draft is retained."))
            }
            entries = next.sorted { ($0.definition?.name ?? $0.file).localizedStandardCompare($1.definition?.name ?? $1.file) == .orderedAscending }
            for entry in entries where drafts[entry.file]?.dirty != true {
                if let definition = entry.definition, let revision = entry.revision {
                    drafts[entry.file] = Draft(definition: definition, original: definition, revision: revision)
                } else { drafts.removeValue(forKey: entry.file) }
            }
            if selection == nil || !entries.contains(where: { $0.file == selection }) { selection = entries.first?.file }
            normalizeSelection()
        } catch { self.error = layoutErrorText(error) }
    }
    func select(_ file: String?) {
        selection = file; selectedTab = 0; selectedPane = nil; error = nil; normalizeSelection()
    }
    func normalizeSelection() {
        if definition?.tabs.indices.contains(selectedTab) != true { selectedTab = 0 }
        if tab?.panes.contains(where: { $0.id == selectedPane }) != true { selectedPane = tab?.layout.paneIDs.first }
    }
    func change(_ operation: (inout SavedLayoutDefinition) -> Void) {
        guard let selection, var draft = drafts[selection] else { return }
        operation(&draft.definition); drafts[selection] = draft; error = nil
    }
    func changePane(_ operation: (inout SavedLayoutPane) -> Void) {
        guard let paneIndex = tab?.panes.firstIndex(where: { $0.id == selectedPane }) else { return }
        change { operation(&$0.tabs[selectedTab].panes[paneIndex]) }
    }
    func setType(_ type: String) {
        guard pane?.type != type else { return }
        changePane { $0.type = type; $0.configuration = types.first { $0.id == type }?.defaults ?? [:] }
    }
    func split(_ axis: SlateTermCore.Axis) {
        guard var definition, let selectedPane else { return }
        do {
            let next = try definition.splitPane(selectedPane, axis: axis)
            change { $0 = definition }; self.selectedPane = next
        } catch { self.error = layoutErrorText(error) }
    }
    func removePane() {
        guard var definition, let selectedPane else { return }
        do {
            let next = try definition.removePane(selectedPane)
            change { $0 = definition }; self.selectedPane = next
        } catch { self.error = layoutErrorText(error) }
    }
    func selectTab(_ index: Int) {
        selectedTab = index; selectedPane = nil; normalizeSelection()
    }
    func addTab() {
        guard var definition else { return }
        do {
            let id = try definition.addTab()
            change { $0 = definition }
            selectedTab = definition.tabs.count - 1; selectedPane = id
        } catch { self.error = layoutErrorText(error) }
    }
    func removeTab(at index: Int) {
        guard var definition else { return }
        do {
            try definition.removeTab(at: index)
            change { $0 = definition }
            if selectedTab > index { selectedTab -= 1 }
            else if selectedTab == index { selectedTab = min(index, definition.tabs.count - 1); selectedPane = nil }
            normalizeSelection()
        } catch { self.error = layoutErrorText(error) }
    }
    func moveTab(from source: Int, to destination: Int) {
        guard var definition else { return }
        do {
            try definition.moveTab(from: source, to: destination)
            change { $0 = definition }
            if selectedTab == source { selectedTab = destination }
            else if source < selectedTab && selectedTab <= destination { selectedTab -= 1 }
            else if destination <= selectedTab && selectedTab < source { selectedTab += 1 }
            normalizeSelection()
        } catch { self.error = layoutErrorText(error) }
    }
    func tabDragID(at index: Int) -> String {
        guard let definition, definition.tabs.indices.contains(index) else { return "" }
        return "slate-layout-tab:\(definition.id):\(definition.tabs[index].layout.paneIDs[0])"
    }
    func dropTab(_ value: String, at destination: Int) -> Bool {
        guard let definition, let source = definition.tabs.indices.first(where: { tabDragID(at: $0) == value }),
              source != destination else { return false }
        moveTab(from: source, to: destination)
        return error == nil
    }
    func create() {
        do {
            let entry = try saveDefinition(.blank(), nil)
            refresh(); select(entry.file); didSave?()
        } catch { self.error = layoutErrorText(error) }
    }
    func save() {
        guard let draft else { return }
        do {
            let entry = try saveDefinition(draft.definition, draft.revision)
            drafts.removeValue(forKey: entry.file)
            error = nil; refresh(); didSave?()
        } catch { self.error = layoutErrorText(error); refresh() }
    }
    func saveAll() throws {
        for file in drafts.keys.sorted() {
            guard let draft = drafts[file], draft.dirty else { continue }
            do {
                _ = try saveDefinition(draft.definition, draft.revision)
                drafts.removeValue(forKey: file)
            } catch {
                self.error = layoutErrorText(error); refresh(); throw error
            }
        }
        error = nil; refresh(); didSave?()
    }
    func discardAll() {
        drafts.removeAll(); error = nil; refresh()
    }
    func revert() {
        guard let selection else { return }
        drafts.removeValue(forKey: selection); error = nil; refresh()
    }
    func hasDraft(id: UUID) -> Bool { drafts.values.contains { $0.definition.id == id && $0.dirty } }
}

func layoutErrorText(_ error: any Error) -> String { (error as? RPCFailure)?.message ?? error.localizedDescription }

struct SavedLayoutsView: View {
    @ObservedObject var model: SavedLayoutsModel
    @State private var previewSize = CGSize(width: 360, height: 260)
    @State private var inspectorHasMore = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Layout", selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                    if model.entries.isEmpty { Text("No Saved Layouts").tag(String?.none) }
                    ForEach(model.entries) { entry in
                        let name = model.drafts[entry.file]?.definition.name ?? entry.definition?.name ?? entry.file
                        Text(name + (model.drafts[entry.file]?.dirty == true ? " •" : "") + (entry.diagnostic != nil ? " (Needs Repair)" : ""))
                            .tag(Optional(entry.file))
                    }
                }
                Button(action: model.create) { Label("New Layout", systemImage: "plus") }
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            VStack(spacing: 0) {
                if let definition = model.definition {
                    editor(definition)
                } else {
                    ContentUnavailableView {
                        Label(model.entry == nil ? "No Saved Layouts" : "Layout Needs Repair",
                              systemImage: model.entry == nil ? "rectangle.split.2x2" : "exclamationmark.triangle")
                    } description: {
                        VStack(spacing: 12) {
                            Text(model.entry?.diagnostic ?? "Create a layout, or save a window from Search Commands.")
                            if let entry = model.entry { Text(entry.file).font(.caption.monospaced()) }
                        }.textSelection(.enabled)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                Divider()
                // Reserve status space so editing or reverting does not resize the preview.
                Text(model.conflict ? "File changed externally. Revert to reload." : "Unsaved changes")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 12)
                    .opacity(model.conflict || model.isDirty ? 1 : 0)
                    .accessibilityHidden(!model.conflict && !model.isDirty)
                HStack {
                    Button("Create Spotlight Launcher…", action: model.makeLauncher)
                        .disabled(model.definition == nil || model.isDirty || model.conflict || model.launcherUnavailable != nil)
                        .help(model.launcherUnavailable ?? "Create an app shortcut for the saved layout. Save changes first.")
                    Spacer()
                    Button("Revert", action: model.revert).disabled(!model.isDirty && !model.conflict)
                    Button("Save Changes", action: model.save).keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent).disabled(!model.isDirty)
                }.padding(16)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editor(_ definition: SavedLayoutDefinition) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Layout Name", text: Binding(get: { model.definition?.name ?? "" }, set: { value in model.change { $0.name = value } }))
                .font(.title2.weight(.semibold)).textFieldStyle(.plain).padding(24)
                .accessibilityLabel("Layout Name")
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    tabStrip(definition)
                    if let tab = model.tab {
                        SavedLayoutMap(tree: tab.layout, panes: tab.panes, types: model.types, selected: model.selectedPane) { model.selectedPane = $0 }
                            .frame(minHeight: 120, maxHeight: .infinity)
                            .onGeometryChange(for: CGSize.self, of: { $0.size }) { previewSize = $0 }
                        HStack(spacing: 8) {
                            splitButtons
                            Button("Remove Pane", action: model.removePane).disabled(tab.panes.count <= 1)
                        }.labelStyle(.titleOnly).fixedSize(horizontal: true, vertical: false)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                inspector.frame(width: 280)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func tabStrip(_ definition: SavedLayoutDefinition) -> some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
              ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(definition.tabs.indices, id: \.self) { index in
                        HStack(spacing: 4) {
                            Button { model.selectTab(index) } label: {
                                Text(definition.tabs[index].name).lineLimit(1)
                                    .font(.system(size: 12, weight: model.selectedTab == index ? .semibold : .regular))
                                    .padding(.vertical, 7).padding(.leading, 10).padding(.trailing, 4)
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(model.selectedTab == index ? .isSelected : [])
                            Button { model.removeTab(at: index) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                                    .frame(width: 22, height: 26).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(definition.tabs.count <= 1)
                                .help("Remove \(definition.tabs[index].name)")
                                .accessibilityLabel("Remove \(definition.tabs[index].name)")
                        }
                        .foregroundStyle(model.selectedTab == index ? Color.primary : Color.secondary)
                        .background(model.selectedTab == index ? Color(nsColor: .selectedControlColor) : Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        .id(index)
                        .draggable(model.tabDragID(at: index))
                        .dropDestination(for: String.self, action: { (items: [String], _: CGPoint) -> Bool in
                            items.first.map { model.dropTab($0, at: index) } ?? false
                        })
                        .contextMenu {
                            Button("Move Left") { model.moveTab(from: index, to: index - 1) }.disabled(index == 0)
                            Button("Move Right") { model.moveTab(from: index, to: index + 1) }.disabled(index == definition.tabs.count - 1)
                            Divider()
                            Button("Remove Tab") { model.removeTab(at: index) }.disabled(definition.tabs.count <= 1)
                        }
                        .accessibilityAction(named: "Move Left") { if index > 0 { model.moveTab(from: index, to: index - 1) } }
                        .accessibilityAction(named: "Move Right") { if index + 1 < definition.tabs.count { model.moveTab(from: index, to: index + 1) } }
                    }
                }
              }.scrollIndicators(.hidden)
                .onChange(of: model.selectedTab) { proxy.scrollTo(model.selectedTab, anchor: .center) }
                .onChange(of: definition.tabs.count) { proxy.scrollTo(model.selectedTab, anchor: .center) }
            }
            Button(action: model.addTab) { Image(systemName: "plus").frame(width: 24, height: 24) }
                .buttonStyle(.borderless).disabled(definition.tabs.count >= 8)
                .help("Add Tab").accessibilityLabel("Add Tab")
        }
    }
    @ViewBuilder private var splitButtons: some View {
        Button { model.split(.horizontal) } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
            .disabled(!canSplit(.horizontal))
        Button { model.split(.vertical) } label: { Label("Split Below", systemImage: "rectangle.split.1x2") }
            .disabled(!canSplit(.vertical))
    }
    private func canSplit(_ axis: SlateTermCore.Axis) -> Bool {
        guard let tab = model.tab, let selected = model.selectedPane, tab.panes.count < 8 else { return false }
        func size(_ tree: SlateTermCore.Layout, in available: CGSize) -> CGSize? {
            switch tree {
            case .pane(let id): return id == selected ? available : nil
            case .split(let axis, let fraction, let first, let second):
                var a = available, b = available
                if axis == .horizontal { a.width = (available.width - 8) * fraction; b.width = (available.width - 8) * (1 - fraction) }
                else { a.height = (available.height - 8) * fraction; b.height = (available.height - 8) * (1 - fraction) }
                return size(first, in: a) ?? size(second, in: b)
            }
        }
        guard let frame = size(tab.layout, in: previewSize) else { return false }
        return axis == .horizontal ? frame.width >= 144 : frame.height >= 120
    }
    private var inspector: some View {
        Form {
            if let pane = model.pane {
                Section("Pane") {
                    TextField("Name", text: Binding(get: { model.pane?.title ?? "" }, set: { value in model.changePane { $0.title = value } }), prompt: Text("Automatic"))
                    Toggle("Show pane bar", isOn: Binding(get: { model.pane?.headerVisible ?? true },
                                                          set: { value in model.changePane { $0.headerVisible = value } }))
                        .help("Show it again from Workspace → Show Pane Bar or Search Commands.")
                    Picker("Type", selection: Binding(get: { model.pane?.type ?? "terminal" }, set: model.setType)) {
                        ForEach(model.types) { type in Text(type.title).tag(type.id) }
                        if !model.types.contains(where: { $0.id == pane.type }) { Text("\(pane.type) (Missing)").tag(pane.type) }
                    }
                }
                if let type = model.types.first(where: { $0.id == pane.type }) {
                    if !type.fields.isEmpty {
                        Section("Starting Configuration") {
                            ForEach(type.fields) { field in fieldView(field) }
                        }
                    }
                    let unknown = pane.configuration.keys.filter { key in !type.fields.contains { $0.id == key } }
                    if !unknown.isEmpty { Text("Additional configuration is preserved in the file.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Section {
                        Label("Plugin unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("Install \(pane.type), or choose another type to replace this pane’s configuration.").font(.callout)
                    }
                }
            }
        }.formStyle(.grouped)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY + 1 < geometry.contentSize.height
            } action: { _, hasMore in inspectorHasMore = hasMore }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if inspectorHasMore {
                    Label("Scroll for more settings", systemImage: "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(8)
                        .background(.background)
                }
            }
    }
    @ViewBuilder private func fieldView(_ field: SavedLayoutField) -> some View {
        let text = Binding(get: { (model.pane?.configuration[field.id] ?? field.defaultValue)?.string ?? "" },
                           set: { value in model.changePane { $0.configuration[field.id] = .string(value) } })
        switch field.kind {
        case .boolean:
            Toggle(field.label, isOn: Binding(get: { (model.pane?.configuration[field.id] ?? field.defaultValue) == .bool(true) },
                                              set: { value in model.changePane { $0.configuration[field.id] = .bool(value) } }))
        case .choice:
            Picker(field.label, selection: text) {
                if !field.required { Text("None").tag("") }
                ForEach(field.options, id: \.self) { Text($0).tag($0) }
            }
        case .multiline:
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label)
                TextEditor(text: text).font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled().writingToolsBehavior(.disabled).frame(minHeight: 80, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary)).accessibilityLabel(field.label)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label)
                TextField(field.label, text: text, prompt: Text(field.kind == .directory ? "Default folder" : ""))
                    .labelsHidden().textFieldStyle(.roundedBorder).accessibilityLabel(field.label)
            }
        }
    }
}

private struct SavedLayoutMap: View {
    let tree: SlateTermCore.Layout
    let panes: [SavedLayoutPane]
    let types: [SavedLayoutPaneType]
    let selected: PaneID?
    let select: (PaneID) -> Void
    var body: some View {
        GeometryReader { geometry in
            render(tree, rect: CGRect(origin: .zero, size: geometry.size))
        }
    }
    private func render(_ tree: SlateTermCore.Layout, rect: CGRect) -> AnyView {
        switch tree {
        case .pane(let id):
            let pane = panes.first { $0.id == id }
            let type = types.first { $0.id == pane?.type }
            let active = id == selected
            return AnyView(Button { select(id) } label: {
                VStack(spacing: 0) {
                    if pane?.headerVisible != false {
                        HStack(spacing: 5) {
                            Image(systemName: "rectangle.split.2x1").font(.system(size: 9))
                            Text(pane?.title.isEmpty == false ? pane!.title : type?.title ?? pane?.type ?? "Pane")
                                .font(.system(size: 10, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }.foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 25)
                            .background(active ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
                        Divider()
                    }
                    VStack(spacing: 8) {
                        Image(systemName: pane?.type == "terminal" ? "terminal" : ["browser", "private-browser"].contains(pane?.type ?? "") ? "globe" : "puzzlepiece.extension")
                            .font(.system(size: 20, weight: .regular)).foregroundStyle(active ? Color.accentColor : .secondary)
                        if pane?.headerVisible == false {
                            Text(pane?.title.isEmpty == false ? pane!.title : type?.title ?? pane?.type ?? "Pane")
                                .font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                        }
                        if type == nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityLabel("Plugin unavailable") }
                    }.padding(8).frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(active ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: active ? 2 : 1))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).clipped().accessibilityAddTraits(active ? .isSelected : [])
                .frame(width: max(0, rect.width), height: max(0, rect.height)).position(x: rect.midX, y: rect.midY))
        case .split(let axis, let fraction, let first, let second):
            let gap = 8.0
            let length = (axis == .horizontal ? rect.width : rect.height) - gap
            var a = rect, b = rect
            if axis == .horizontal {
                a.size.width = length * fraction; b.origin.x = a.maxX + gap; b.size.width = length * (1 - fraction)
            } else {
                a.size.height = length * fraction; b.origin.y = a.maxY + gap; b.size.height = length * (1 - fraction)
            }
            return AnyView(ZStack(alignment: .topLeading) { render(first, rect: a); render(second, rect: b) })
        }
    }
}
