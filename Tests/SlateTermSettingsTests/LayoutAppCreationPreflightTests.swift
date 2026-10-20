import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

private final class CreationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-creation-\(UUID().uuidString)")
    let parent: URL
    let state: WorkspaceStore
    var catalog: PluginCatalog
    init() throws {
        parent = root.appendingPathComponent("parent")
        state = try WorkspaceStore(directory: parent.appendingPathComponent("state"))
        catalog = try PluginCatalog(directory: parent.appendingPathComponent("plugins"))
    }
    deinit { try? FileManager.default.removeItem(at: root); withExtendedLifetime(state) {} }
    var base: URL { root.appendingPathComponent("new-app") }
    func install(_ id: String = "notes", enabled: Bool = true) throws {
        let source = try packageFixture("{\"id\":\"\(id)\",\"title\":\"Notes\",\"source\":{\"kind\":\"directory\",\"path\":\".\",\"entry\":\"index.html\"}}", files: ["index.html": "<p>Notes</p>"])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        try catalog.register(catalog.packages.prepare(source), replace: false)
        try catalog.setEnabled(id, enabled: enabled)
    }
    func recipe(_ type: String = "notes") -> SavedLayoutDefinition {
        .init(name: "Notes", tabs: [.init(name: "Notes", layout: .pane(PaneID(1)), panes: [.init(id: PaneID(1), type: type)])])
    }
    func data(_ id: String = "notes") throws -> PluginDataStore {
        try PluginDataStore(directory: parent.appendingPathComponent("state/plugin-data-v2"), id: id)
    }
    func archive(_ id: String = "notes") -> URL {
        catalog.packages.root(catalog.records.first { $0.id == id }!).deletingLastPathComponent().appendingPathComponent("package.zip")
    }
    func prepare(recipe: SavedLayoutDefinition? = nil, copy: Bool = true) throws -> LayoutAppCreationPreflight {
        try .prepare(base: base, parentBase: parent, recipe: recipe, copyPluginData: copy)
    }
}

@Test func layoutCreationPreflightCopiesVerifiedInventoryAndOnlySyncedData() throws {
    let fixture = try CreationFixture()
    try fixture.install()
    try fixture.install("disabled", enabled: false)
    let source = try fixture.data()
    let document = try source.document.changing(operations: .array([.object(["op": .string("set"), "key": .string("draft"), "value": .string("Parent note")])]), expectedRevision: source.document.revision)
    try source.persist(document)
    let stale = try fixture.data("removed")
    try Data("invalid unrelated data".utf8).write(to: stale.url)
    let parentRegistry = try Data(contentsOf: fixture.parent.appendingPathComponent("plugins/registry.json"))
    var prepared: LayoutAppCreationPreflight? = try fixture.prepare(recipe: fixture.recipe())
    #expect(prepared?.syncedPluginIDs == ["disabled", "notes"])
    #expect(prepared?.unavailablePlugins.isEmpty == true)
    #expect(prepared?.copiedPluginDataIDs == ["notes"])
    #expect(throws: (any Error).self) { try WorkspaceStore(directory: fixture.base.appendingPathComponent("state")) }
    let local = try PluginCatalog(directory: fixture.base.appendingPathComponent("plugins"))
    #expect(local.disabledPlugins == ["disabled"])
    #expect(local.records.map(\.installationID) != fixture.catalog.records.map(\.installationID))
    #expect(local.records.map(\.archiveSHA256) == fixture.catalog.records.map(\.archiveSHA256))
    let copied = try PluginDataStore(directory: fixture.base.appendingPathComponent("state/plugin-data-v2"), id: "notes")
    #expect(copied.document == document)
    #expect(!FileManager.default.fileExists(atPath: copied.url.deletingLastPathComponent().appendingPathComponent("removed.json").path))
    try source.persist(document.changing(operations: nil, expectedRevision: document.revision))
    #expect(try PluginDataStore(directory: copied.url.deletingLastPathComponent(), id: "notes").document == document)
    #expect(try Data(contentsOf: fixture.parent.appendingPathComponent("plugins/registry.json")) == parentRegistry)
    prepared = nil
    #expect(!FileManager.default.fileExists(atPath: fixture.base.path))
}

@Test func layoutCreationPreflightRetainsOnlyPublishedState() throws {
    let fixture = try CreationFixture()
    var prepared: LayoutAppCreationPreflight? = try fixture.prepare(recipe: .blank(), copy: false)
    #expect(prepared?.syncedPluginIDs.isEmpty == true)
    prepared?.retainPublishedState()
    prepared = nil
    #expect(FileManager.default.fileExists(atPath: fixture.base.path))
    let reopened = try WorkspaceStore(directory: fixture.base.appendingPathComponent("state"))
    withExtendedLifetime(reopened) {}
    #expect(throws: (any Error).self) { try fixture.prepare() }
    #expect(FileManager.default.fileExists(atPath: fixture.base.path))
}

@Test func layoutCreationPreflightRefusesMissingDisabledAndCorruptDependencies() throws {
    let fixture = try CreationFixture()
    #expect(throws: (any Error).self) { try fixture.prepare(recipe: fixture.recipe()) }
    #expect(!FileManager.default.fileExists(atPath: fixture.base.path))
    try fixture.install(enabled: false)
    #expect(throws: (any Error).self) { try fixture.prepare(recipe: fixture.recipe()) }
    #expect(!FileManager.default.fileExists(atPath: fixture.base.path))
    try fixture.catalog.setEnabled("notes", enabled: true)
    try Data("corrupt archive".utf8).write(to: fixture.archive())
    #expect(throws: (any Error).self) { try fixture.prepare(recipe: fixture.recipe()) }
    #expect(!FileManager.default.fileExists(atPath: fixture.base.path))
    let preview = try fixture.prepare(copy: true)
    #expect(preview.syncedPluginIDs.isEmpty)
    #expect(preview.unavailablePlugins.map(\.id) == ["notes"])
    #expect(preview.unavailablePlugins.first?.reason.isEmpty == false)
    #expect(preview.copiedPluginDataIDs.isEmpty)
}

@Test func layoutCreationPreflightRejectsChangedPackageIdentityAndDigest() throws {
    let fixture = try CreationFixture()
    try fixture.install()
    let replacement = try packageFixture("{\"id\":\"notes\",\"title\":\"Changed\",\"source\":{\"kind\":\"directory\",\"path\":\".\",\"entry\":\"index.html\"}}", files: ["index.html": "changed"])
    defer { try? FileManager.default.removeItem(at: replacement.deletingLastPathComponent()) }
    try Data(contentsOf: replacement).write(to: fixture.archive())
    let prepared = try fixture.prepare(copy: false)
    #expect(prepared.syncedPluginIDs.isEmpty)
    #expect(prepared.unavailablePlugins.first?.reason.contains("changed during synchronization") == true)
}

@Test func layoutCreationPreflightOptionalCopyRejectsMalformedCompleteDocuments() throws {
    let fixture = try CreationFixture()
    try fixture.install()
    let source = try fixture.data()
    let revision = UUID().uuidString
    let invalid = ["{broken", "{}",
        "{\"schemaVersion\":2,\"revision\":\"\(revision)\",\"values\":{}}",
        "{\"schemaVersion\":1,\"revision\":\"invalid\",\"values\":{}}",
        "{\"schemaVersion\":1,\"revision\":\"\(revision)\",\"values\":{},\"unknown\":true}",
        "{\"schemaVersion\":1,\"revision\":\"\(revision)\",\"values\":{\"large\":\"\(String(repeating: "a", count: PluginPersistence.valueBytes))\"}}"]
    for contents in invalid {
        try Data(contents.utf8).write(to: source.url)
        #expect(throws: (any Error).self) { try fixture.prepare(recipe: fixture.recipe()) }
        #expect(!FileManager.default.fileExists(atPath: fixture.base.path))
    }
    let withoutData = try fixture.prepare(recipe: fixture.recipe(), copy: false)
    #expect(withoutData.copiedPluginDataIDs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("state/plugin-data-v2").path))
}

@Test func layoutCreationPreflightRejectsSymlinkDataAndMissingNonemptyRegistry() throws {
    let fixture = try CreationFixture()
    try fixture.install()
    let source = try fixture.data()
    let outside = fixture.root.appendingPathComponent("outside.json")
    try JSONEncoder().encode(PluginDataDocument()).write(to: outside)
    try FileManager.default.createSymbolicLink(at: source.url, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try fixture.prepare() }
    #expect(!FileManager.default.fileExists(atPath: fixture.base.path))
    try FileManager.default.removeItem(at: fixture.parent.appendingPathComponent("plugins/registry.json"))
    #expect(throws: (any Error).self) { try fixture.prepare(copy: false) }
    #expect(!FileManager.default.fileExists(atPath: fixture.base.path))
    #expect(FileManager.default.fileExists(atPath: outside.path))
}

@Test func layoutCreationPreflightRejectsNamedPipeWithoutWaitingForAWriter() throws {
    let fixture = try CreationFixture()
    try fixture.install()
    let source = try fixture.data()
    #expect(mkfifo(source.url.path, 0o600) == 0)
    let started = ContinuousClock.now
    #expect(throws: (any Error).self) { try fixture.prepare() }
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(!FileManager.default.fileExists(atPath: fixture.base.path))
}
