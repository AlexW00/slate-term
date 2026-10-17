import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func packagedServiceRegistrationDoesNotPersistStartupPermission() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = try packageFixture(#"{"id":"worker","title":"Worker","service":{"executable":"/bin/sh","arguments":["{pluginRoot}/worker.sh"]}}"#, files: ["worker.sh": "exit 0"])
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    var catalog = try PluginCatalog(directory: directory)
    let registration = try catalog.register(catalog.packages.prepare(source), replace: false)
    #expect(registration.service?.directory == registration.packageRoot)
    #expect(registration.service?.arguments == [registration.packageRoot! + "/worker.sh"])
    #expect(try PluginCatalog(directory: directory).activeRegistrations == [registration])
    let registry = try String(contentsOf: directory.appendingPathComponent("registry.json"), encoding: .utf8)
    #expect(!registry.contains("enabledServices"))
    #expect(try catalog.setEnabled("worker", enabled: false))
    #expect(try PluginCatalog(directory: directory).activeRegistrations.isEmpty)
}
