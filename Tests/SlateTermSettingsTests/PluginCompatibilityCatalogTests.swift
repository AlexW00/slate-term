import Foundation
import Testing
import SlateTermCore
import SlateTermTestSupport
@testable import SlateTermSettings

@Test func storedIncompatiblePackagesRemainInspectableButInactive() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = try packageFixture()
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    var catalog = try PluginCatalog(directory: directory)
    let registration = try catalog.register(catalog.packages.prepare(source), replace: false)
    let before = try Data(contentsOf: directory.appendingPathComponent("registry.json"))
    let manifestPath = URL(fileURLWithPath: registration.packageRoot!).appendingPathComponent("plugin.json")
    var manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: manifestPath)).object!
    manifest["compatibility"] = .object(["minimumAPIVersion": .integer(2), "maximumAPIVersion": .integer(2)])
    try JSONEncoder().encode(JSONValue.object(manifest)).write(to: manifestPath)
    // Model a host downgrade without changing the registry's enable preference.
    catalog = try PluginCatalog(directory: directory)
    #expect(catalog.registrations.count == 1)
    #expect(catalog.activeRegistrations.isEmpty)
    #expect(catalog.disabledPlugins.isEmpty)
    let row = catalog.list().array!.first!
    #expect(row.object?["enabled"] == .bool(true))
    #expect(row.object?["compatibilityStatus"]?.object?["compatible"] == .bool(false))
    #expect(schemaAccepts(AutomationContracts.pluginDefinitions["InstalledPlugin"]!, row, definitions: AutomationContracts.pluginDefinitions))
    #expect(throws: (any Error).self) { try catalog.setEnabled("tools", enabled: true) }
    #expect(try Data(contentsOf: directory.appendingPathComponent("registry.json")) == before)
}

@Test func incompatiblePackagePreparationPreservesInstalledRegistrationAndPreference() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = try packageFixture()
    let invalid = try packageFixture(#"{"id":"tools","title":"Future","version":"2.0.0","compatibility":{"requiredMethods":["future.method"]},"commands":[{"id":"go","title":"Go","executable":"/bin/sh"}]}"#)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: invalid.deletingLastPathComponent())
    }
    var catalog = try PluginCatalog(directory: directory)
    let prepared = try catalog.packages.prepare(source)
    let validation = try prepared.validation
    #expect(schemaAccepts(AutomationContracts.plugins[.pluginsValidate]!.result, validation, definitions: AutomationContracts.pluginDefinitions))
    try catalog.register(prepared, replace: false)
    try catalog.setEnabled("tools", enabled: false)
    let records = catalog.records
    let before = try Data(contentsOf: directory.appendingPathComponent("registry.json"))
    do {
        let invalidPrepared = try catalog.packages.prepare(invalid)
        _ = try catalog.register(invalidPrepared, replace: true)
        Issue.record("Incompatible replacement was admitted")
    } catch let failure as RPCFailure {
        #expect(failure.code == APIError.incompatible)
        #expect(failure.data?.object?["compatible"] == .bool(false))
    }
    #expect(catalog.records == records)
    #expect(catalog.disabledPlugins == ["tools"])
    #expect(try Data(contentsOf: directory.appendingPathComponent("registry.json")) == before)
    #expect(throws: (any Error).self) { try PluginPackageStore.validate(invalid) }
}
