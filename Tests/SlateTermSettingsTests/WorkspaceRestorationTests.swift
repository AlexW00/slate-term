import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func restorationRoundTripsAtomicallyWithTopologyButNotPrivateLocations() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-restore-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WorkspaceStore(directory: directory)
    var workspace = Workspace()
    let browser = try workspace.split(PaneID(1), direction: .right)
    try workspace.setType(browser, to: .browser)
    let privateBrowser = try workspace.split(PaneID(1), direction: .down)
    try workspace.setType(privateBrowser, to: .privateBrowser)
    var restoration = WorkspaceRestoration()
    restoration.directories["p1"] = "/tmp/a folder/日本語"
    restoration.browserURLs[browser.description] = "https://example.test/path?q=hello#fragment"
    restoration.windowFrames[GroupID(1).description] = .init(x: -900, y: 40, width: 800, height: 600)
    try store.save(workspace, restoration: restoration)
    let loaded = try #require(try store.loadSnapshot())
    #expect(loaded.workspace == workspace)
    #expect(loaded.restoration == restoration)
    let previous = try Data(contentsOf: store.url)
    restoration.browserURLs[privateBrowser.description] = "https://private.example.test/"
    #expect(throws: (any Error).self) { try store.save(workspace, restoration: restoration) }
    #expect(try Data(contentsOf: store.url) == previous)
    #expect(!String(decoding: previous, as: UTF8.self).contains("private.example"))
    // Topology-only development snapshots remain readable.
    try workspace.encoded().write(to: store.url)
    #expect(try store.loadSnapshot()?.restoration == WorkspaceRestoration())
}

@Test func restorationRejectsUnsafeLocationsAndStaleReferences() throws {
    var restoration = WorkspaceRestoration()
    for path in ["relative", "~/folder", "/bad\0path", "/" + String(repeating: "a", count: 4096)] {
        restoration.directories = ["p1": path]
        #expect(throws: (any Error).self) { try restoration.validate(for: Workspace()) }
    }
    restoration.directories = ["p999": "/tmp"]
    #expect(throws: (any Error).self) { try restoration.validate(for: Workspace()) }
    restoration.directories = [:]
    restoration.windowFrames = [GroupID(1).description: .init(x: 0, y: 0, width: .infinity, height: 600)]
    #expect(throws: (any Error).self) { try restoration.validate(for: Workspace()) }
    for url in ["javascript:alert(1)", "https://user:secret@example.test", "file://remote/tmp/a", "relative.html"] {
        #expect(!WorkspaceRestoration.allowsBrowserURL(url))
    }
    #expect(WorkspaceRestoration.allowsBrowserURL("file:///tmp/local.html"))
    #expect(WorkspaceRestoration.allowsBrowserURL("about:blank"))
}

@Test func restoredWindowFitsConnectedScreensAndHandlesRemovedMonitors() {
    typealias Frame = WorkspaceRestoration.Frame
    let primary = Frame(x: 0, y: 24, width: 1200, height: 800)
    let secondary = Frame(x: -1600, y: 0, width: 1600, height: 900)
    let saved = Frame(x: -1500, y: 80, width: 1000, height: 700)
    #expect(saved.fitted(to: [primary, secondary]) == saved)
    #expect(saved.fitted(to: [primary]) == Frame(x: 0, y: 80, width: 1000, height: 700))
    let oversized = Frame(x: 50, y: 600, width: 4000, height: 3000)
    #expect(oversized.fitted(to: [primary]) == primary)
}

/// Hints for panes that no longer fit (removed, or another type) are dropped on load; the
/// workspace itself still loads. Unsafe values remain a corrupt snapshot.
@Test func loadingDropsStaleRestorationEntriesButNotUnsafeValues() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-restore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = Workspace()
    let pane = try #require(workspace.panes.first?.id).description
    let store = try WorkspaceStore(directory: directory)
    var restoration = WorkspaceRestoration()
    restoration.directories = [pane: "/tmp"]
    try store.save(workspace, restoration: restoration)
    func write(_ edit: (inout [String: JSONValue]) -> Void) throws {
        var root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.url)).object!
        var hints = root["restoration"]!.object!
        edit(&hints)
        root["restoration"] = .object(hints)
        try JSONEncoder().encode(JSONValue.object(root)).write(to: store.url)
    }
    // A removed pane, and a browser location attached to a terminal pane.
    try write { $0["directories"] = .object([pane: .string("/tmp"), "p999": .string("/tmp")])
                $0["browserURLs"] = .object([pane: .string("https://example.test/")]) }
    let loaded = try #require(try store.loadSnapshot())
    #expect(loaded.workspace == workspace)
    #expect(loaded.restoration.directories == [pane: "/tmp"] && loaded.restoration.browserURLs.isEmpty)
    // A malformed value for a pane that does fit is still a corrupt snapshot.
    try write { $0["directories"] = .object([pane: .string("relative")]) }
    #expect(throws: (any Error).self) { try store.loadSnapshot() }
}
