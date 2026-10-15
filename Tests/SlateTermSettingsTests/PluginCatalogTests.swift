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

@Test func disabledPluginsPersistWithoutLosingRegistrationAndReplacementPreservesTheChoice() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-catalog-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var catalog = try PluginCatalog(directory: directory)
    let plugin = try PluginRegistration.parse(Data(#"{"id":"worker","title":"Worker","service":{"executable":"/usr/bin/true"}}"#.utf8))
    try catalog.register(plugin, replace: false)
    #expect(try catalog.setServiceEnabled("worker", enabled: true))
    #expect(try catalog.setEnabled("worker", enabled: false))
    catalog = try PluginCatalog(directory: directory)
    #expect(catalog.registrations == [plugin])
    #expect(catalog.activeRegistrations.isEmpty)
    #expect(catalog.enabledServices.isEmpty)
    #expect(throws: (any Error).self) { try catalog.setServiceEnabled("worker", enabled: true) }
    let before = try Data(contentsOf: directory.appendingPathComponent("plugins.json"))
    #expect(try !catalog.setEnabled("worker", enabled: false))
    #expect(try Data(contentsOf: directory.appendingPathComponent("plugins.json")) == before)
    try catalog.register(plugin, replace: true)
    #expect(try PluginCatalog(directory: directory).disabledPlugins == ["worker"])
    #expect(try catalog.setEnabled("worker", enabled: true))
    #expect(try PluginCatalog(directory: directory).activeRegistrations == [plugin])
    #expect(catalog.enabledServices.isEmpty)
    _ = try catalog.setEnabled("worker", enabled: false)
    try catalog.remove("worker")
    try catalog.register(plugin, replace: false)
    #expect(try PluginCatalog(directory: directory).disabledPlugins.isEmpty)
}

@Test func failedPluginDisablePreservesCatalogStateAndBytes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-catalog-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var catalog = try PluginCatalog(directory: directory)
    let plugin = try PluginRegistration.parse(Data(#"{"id":"notes","title":"Notes","source":{"kind":"url","url":"https://example.com"}}"#.utf8))
    try catalog.register(plugin, replace: false)
    let path = directory.appendingPathComponent("plugins.json")
    let before = try Data(contentsOf: path)
    #expect(chmod(path.path, 0o644) == 0)
    defer { _ = chmod(path.path, 0o600) }
    #expect(throws: (any Error).self) { try catalog.setEnabled("notes", enabled: false) }
    #expect(throws: (any Error).self) { try catalog.setEnabled("missing", enabled: true) }
    #expect(catalog.activeRegistrations == [plugin] && catalog.disabledPlugins.isEmpty)
    #expect(try Data(contentsOf: path) == before)
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
