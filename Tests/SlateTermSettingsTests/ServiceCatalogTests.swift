import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

private func catalogService(_ id: String = "worker") throws -> PluginRegistration {
    try PluginRegistration.parse(JSONEncoder().encode(JSONValue.object([
        "id": .string(id), "title": .string(id), "service": .object(["executable": .string("/usr/bin/true")])
    ])))
}

@Test func serviceOptInPersistsButRegistrationAndReplacementNeverActivate() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-service-catalog-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var catalog = try PluginCatalog(directory: directory)
    let plugin = try catalogService()
    try catalog.register(plugin, replace: false)
    #expect(catalog.enabledServices.isEmpty)
    #expect(try catalog.setServiceEnabled("worker", enabled: true))
    #expect(try PluginCatalog(directory: directory).enabledServices == ["worker"])
    #expect(try !catalog.setServiceEnabled("worker", enabled: true))
    #expect(throws: (any Error).self) { try catalog.register(plugin, replace: false) }
    #expect(catalog.enabledServices == ["worker"])
    try catalog.register(plugin, replace: true)
    #expect(catalog.enabledServices.isEmpty)
    #expect(try PluginCatalog(directory: directory).enabledServices.isEmpty)
    _ = try catalog.setServiceEnabled("worker", enabled: true)
    try catalog.remove("worker")
    try catalog.register(plugin, replace: false)
    #expect(try PluginCatalog(directory: directory).enabledServices.isEmpty)
}

@Test func legacyCatalogNeverImportsUnversionedOptInAndV2RejectsInvalidRecipients() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-service-catalog-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PrivateJSONStore(url: directory.appendingPathComponent("plugins.json"))
    let plugin = try catalogService()
    var snapshot: [String: JSONValue] = ["schemaVersion": .integer(1), "registrations": .array([try .encoding(plugin)]),
                                       "enabledServices": .array([.string("worker")])]
    try store.save(snapshot)
    var migrated = try PluginCatalog(directory: directory)
    #expect(migrated.enabledServices.isEmpty)
    _ = try migrated.setServiceEnabled("worker", enabled: true)
    #expect(try store.load([String: JSONValue].self)?["schemaVersion"] == .integer(2))
    snapshot["schemaVersion"] = .integer(2)
    for invalid in [JSONValue.null, .array([.string("missing")]), .array([.string("worker"), .string("worker")])] {
        snapshot["enabledServices"] = invalid
        try store.save(snapshot)
        #expect(throws: (any Error).self) { try PluginCatalog(directory: directory) }
    }
}

@Test func serviceOptInRequiresAServiceAndIsBounded() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-service-catalog-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var catalog = try PluginCatalog(directory: directory)
    for index in 0..<17 { try catalog.register(catalogService("worker-\(index)"), replace: false) }
    for index in 0..<16 { #expect(try catalog.setServiceEnabled("worker-\(index)", enabled: true)) }
    let before = try Data(contentsOf: directory.appendingPathComponent("plugins.json"))
    #expect(throws: (any Error).self) { try catalog.setServiceEnabled("worker-16", enabled: true) }
    #expect(catalog.enabledServices.count == 16)
    #expect(try Data(contentsOf: directory.appendingPathComponent("plugins.json")) == before)
    #expect(try catalog.setServiceEnabled("worker-0", enabled: false))
    #expect(try catalog.setServiceEnabled("worker-16", enabled: true))
    let panel = try PluginRegistration.parse(Data(#"{"id":"panel","title":"Panel","source":{"kind":"url","url":"https://example.com"}}"#.utf8))
    try catalog.register(panel, replace: false)
    #expect(throws: (any Error).self) { try catalog.setServiceEnabled("panel", enabled: true) }
    #expect(throws: (any Error).self) { try catalog.setServiceEnabled("missing", enabled: false) }
}

@Test func failedServiceCatalogWritesPreserveRegistrationOptInAndBytes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-service-catalog-\(UUID().uuidString)")
    defer { _ = chmod(directory.path, 0o700); try? FileManager.default.removeItem(at: directory) }
    var catalog = try PluginCatalog(directory: directory)
    let plugin = try catalogService()
    try catalog.register(plugin, replace: false)
    _ = try catalog.setServiceEnabled("worker", enabled: true)
    let path = directory.appendingPathComponent("plugins.json")
    let before = try Data(contentsOf: path)
    // Invalid private-file mode deterministically rejects writes, even under root.
    #expect(chmod(path.path, 0o644) == 0)
    defer { _ = chmod(path.path, 0o600) }
    #expect(throws: (any Error).self) { try catalog.setServiceEnabled("worker", enabled: false) }
    #expect(throws: (any Error).self) { try catalog.register(plugin, replace: true) }
    #expect(throws: (any Error).self) { try catalog.remove("worker") }
    #expect(catalog.registrations == [plugin] && catalog.enabledServices == ["worker"])
    #expect(try Data(contentsOf: path) == before)
}
