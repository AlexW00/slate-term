import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func pluginCatalogPersistsAtomicallyAndRequiresExplicitReplacement() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-catalog-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var catalog = try PluginCatalog(directory: directory)
    let plugin = try PluginRegistration.parse(Data(#"{"id":"notes","title":"Notes","source":{"kind":"url","url":"https://example.com"}}"#.utf8))
    try catalog.register(plugin, replace: false)
    #expect(try PluginCatalog(directory: directory).registrations == [plugin])
    #expect(throws: (any Error).self) { try catalog.register(plugin, replace: false) }
    #expect(catalog.registrations == [plugin])
    try catalog.remove("notes")
    #expect(try PluginCatalog(directory: directory).registrations.isEmpty)
    var info = stat()
    #expect(stat(directory.appendingPathComponent("plugins.json").path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
}

@Test func privateJSONStoreRejectsOversizeAndUnsafeFilesWithoutChangingOldData() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-private-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("data.json")
    let store = try PrivateJSONStore(url: url, maximumBytes: 100)
    try store.save(["value": "original"])
    #expect(throws: (any Error).self) { try store.save(["value": String(repeating: "x", count: 200)]) }
    #expect(try store.load([String: String].self) == ["value": "original"])
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    #expect(throws: (any Error).self) { try store.load([String: String].self) }
    #expect(throws: (any Error).self) { try store.save(["value": "replacement"]) }
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("original"))
}
