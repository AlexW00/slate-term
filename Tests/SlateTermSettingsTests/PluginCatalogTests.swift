import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

/// Tiny stored-ZIP fixture writer: no subprocess/runtime dependency in parallel unit tests.
func fixtureZIP(_ entries: [(String, Data, UInt32)]) -> Data {
    func field(_ value: Int, _ width: Int) -> Data { Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    func crc(_ data: Data) -> Int {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        }
        return Int(~value)
    }
    var output = Data(), central = Data()
    for (path, data, mode) in entries {
        let name = Data(path.utf8), start = output.count, checksum = crc(data)
        output += field(0x04034b50, 4) + field(20, 2) + field(0x800, 2) + field(0, 2) + field(0, 4)
        output += field(checksum, 4) + field(data.count, 4) + field(data.count, 4) + field(name.count, 2) + field(0, 2) + name + data
        central += field(0x02014b50, 4) + field(0x314, 2) + field(20, 2) + field(0x800, 2) + field(0, 2) + field(0, 4)
        central += field(checksum, 4) + field(data.count, 4) + field(data.count, 4) + field(name.count, 2)
        central += field(0, 2) + field(0, 2) + field(0, 2) + field(0, 2) + field(Int(mode) << 16, 4) + field(start, 4) + name
    }
    let start = output.count
    output += central
    output += field(0x06054b50, 4) + field(0, 4) + field(entries.count, 2) + field(entries.count, 2) + field(central.count, 4) + field(start, 4) + field(0, 2)
    return output
}

func packageFixture(_ manifest: String = #"{"id":"tools","title":"Tools","commands":[{"id":"go","title":"Go","executable":"/bin/sh","arguments":["{pluginRoot}/script.sh"]}]}"#,
                    files: [String: String] = ["script.sh": "printf packaged"], entries: [(String, Data, UInt32)]? = nil) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-zip-fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let content = entries ?? [("plugin.json", Data(manifest.utf8), 0o100600)] + files.sorted { $0.key < $1.key }.map { ($0.key, Data($0.value.utf8), UInt32(0o100600)) }
    let url = directory.appendingPathComponent("package.zip")
    try fixtureZIP(content).write(to: url)
    return url
}

@Test func pluginCatalogOwnsZIPAndResourcesAfterDownloadDeletion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-catalog-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = try packageFixture()
    var catalog = try PluginCatalog(directory: directory)
    let prepared = try catalog.packages.prepare(source)
    let registration = try catalog.register(prepared, replace: false)
    try FileManager.default.removeItem(at: source.deletingLastPathComponent())
    #expect(registration.commands[0].directory == registration.packageRoot)
    #expect(try String(contentsOfFile: registration.commands[0].arguments[0], encoding: .utf8) == "printf packaged")
    let reloaded = try PluginCatalog(directory: directory)
    #expect(reloaded.registrations == [registration])
    #expect(reloaded.records == catalog.records)
    let bytes = try String(contentsOf: directory.appendingPathComponent("registry.json"), encoding: .utf8)
    #expect(bytes.contains("\n  \"plugins\"")); #expect(bytes.contains("\"enabled\" : true"))
    #expect(!bytes.contains(source.path))
    var info = stat()
    #expect(stat(directory.appendingPathComponent("registry.json").path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
}

@Test func pluginReplacementPreservesDisabledChoiceAndOldFilesUntilRetirement() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = try packageFixture()
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    var catalog = try PluginCatalog(directory: directory)
    try catalog.register(catalog.packages.prepare(source), replace: false)
    let old = catalog.records[0]
    #expect(try catalog.setEnabled("tools", enabled: false))
    let before = try Data(contentsOf: directory.appendingPathComponent("registry.json"))
    #expect(try !catalog.setEnabled("tools", enabled: false))
    #expect(try Data(contentsOf: directory.appendingPathComponent("registry.json")) == before)
    #expect(throws: (any Error).self) { try catalog.register(catalog.packages.prepare(source), replace: false) }
    try catalog.register(catalog.packages.prepare(source), replace: true)
    #expect(catalog.disabledPlugins == ["tools"])
    #expect(FileManager.default.fileExists(atPath: catalog.packages.root(old).path))
    let current = catalog.records[0]
    try catalog.remove("tools")
    #expect(try PluginCatalog(directory: directory).records.isEmpty)
    #expect(FileManager.default.fileExists(atPath: catalog.packages.root(current).path))
    try catalog.packages.remove(old); try catalog.packages.remove(current)
    #expect(!FileManager.default.fileExists(atPath: catalog.packages.root(old).path))
}

@Test func registryWriteFailurePreservesPreviousInstallationAndBytes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = try packageFixture()
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    var catalog = try PluginCatalog(directory: directory)
    try catalog.register(catalog.packages.prepare(source), replace: false)
    let old = catalog.records
    let path = directory.appendingPathComponent("registry.json")
    let bytes = try Data(contentsOf: path)
    #expect(chmod(path.path, 0o644) == 0)
    #expect(throws: (any Error).self) { try catalog.register(catalog.packages.prepare(source), replace: true) }
    #expect(throws: (any Error).self) { try catalog.setEnabled("tools", enabled: false) }
    #expect(catalog.records == old)
    #expect(try Data(contentsOf: path) == bytes)
    #expect(chmod(path.path, 0o600) == 0)
    try FileManager.default.removeItem(at: catalog.packages.root(old[0]).appendingPathComponent("plugin.json"))
    let unavailable = try PluginCatalog(directory: directory)
    #expect(unavailable.registrations.isEmpty)
    #expect(unavailable.records == old)
    #expect(unavailable.diagnostics["tools"] != nil)
}

@Test func ZIPPreparationRejectsUnsafePathsTypesCollisionsAndSizeLimits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try PluginPackageStore(directory: directory)
    for path in ["../escape", "/absolute", "a/../../escape", "a\\b", "plugin.json", "PLUGIN.JSON", "a", "A/x", "web/../x"] {
        var entries: [(String, Data, UInt32)] = [("plugin.json", Data(#"{"id":"tools","title":"Tools","service":{"executable":"/bin/sh"}}"#.utf8), 0o100600), (path, Data("bad".utf8), 0o100600)]
        if path == "a" { entries.append(("a/x", Data(), 0o100600)) }
        if path == "A/x" { entries.append(("a/y", Data(), 0o100600)) }
        let source = try packageFixture(entries: entries)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        #expect(throws: (any Error).self, "Unsafe ZIP path: \(path)") { try store.prepare(source) }
    }
    let symlink = try packageFixture(entries: [("link", Data("/etc/passwd".utf8), 0o120777)])
    defer { try? FileManager.default.removeItem(at: symlink.deletingLastPathComponent()) }
    #expect(throws: (any Error).self) { try store.prepare(symlink) }
    let source = try packageFixture()
    defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    var limits = PluginPackageLimits(); limits.extractedBytes = 10
    let bounded = try PluginPackageStore(directory: directory, limits: limits)
    #expect(throws: (any Error).self) { try bounded.prepare(source) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(".staging").path).isEmpty)
}

@Test func packageLimitsAndPackagedExecutablePermissionsAreEnforced() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let manifest = Data(#"{"id":"tools","title":"Tools","commands":[{"id":"go","title":"Go","executable":"./bin/tool"}]}"#.utf8)
    let source = try packageFixture(entries: [("plugin.json", manifest, 0o100600), ("bin/tool", Data("#!/bin/sh\nexit 0\n".utf8), 0o100700)])
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    let store = try PluginPackageStore(directory: directory)
    let prepared = try store.prepare(source)
    let executable = try prepared.manifest.registration(root: prepared.directory.appendingPathComponent("contents")).commands[0].executable
    #expect(FileManager.default.isExecutableFile(atPath: executable))
    for kind in 0..<3 {
        var limits = PluginPackageLimits()
        if kind == 0 { limits.archiveBytes = 10 }
        if kind == 1 { limits.fileBytes = 10 }
        if kind == 2 { limits.entries = 1 }
        let bounded = try PluginPackageStore(directory: directory, limits: limits)
        #expect(throws: (any Error).self) { try bounded.prepare(source) }
    }
}

@Test func corruptPackageAndStagingEntriesDoNotBlockHealthyRegistryLoading() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = try packageFixture()
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    var catalog = try PluginCatalog(directory: directory)
    try catalog.register(catalog.packages.prepare(source), replace: false)
    let generation = catalog.packages.root(catalog.records[0]).deletingLastPathComponent()
    #expect(chmod(generation.path, 0o755) == 0)
    var reloaded = try PluginCatalog(directory: directory)
    #expect(reloaded.diagnostics["tools"] != nil)
    #expect(throws: (any Error).self) { try reloaded.setEnabled("tools", enabled: true) }
    let diagnostics = try reloaded.packages.orphanRoots(referenced: reloaded.records)
    #expect(diagnostics[catalog.packages.root(catalog.records[0]).path] != nil)
    let stagedLink = directory.appendingPathComponent(".staging").appendingPathComponent(UUID().uuidString)
    try FileManager.default.createSymbolicLink(at: stagedLink, withDestinationURL: source.deletingLastPathComponent())
    #expect(try !reloaded.packages.cleanAbandonedStaging().isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(chmod(generation.path, 0o700) == 0)
    #expect(try PluginCatalog(directory: directory).diagnostics.isEmpty)
}

@Test func damagedAndNonZIPArchivesAreRejectedWithoutPublication() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = try packageFixture()
    defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
    let store = try PluginPackageStore(directory: directory)
    var bytes = try Data(contentsOf: source)
    let original = bytes
    let payload = try #require(bytes.range(of: Data("printf packaged".utf8)))
    bytes[payload.lowerBound] ^= 1
    try bytes.write(to: source)
    #expect(throws: (any Error).self) { try store.prepare(source) }
    bytes = original
    bytes.removeLast(8)
    try bytes.write(to: source)
    #expect(throws: (any Error).self) { try store.prepare(source) }
    try Data("not a ZIP".utf8).write(to: source)
    #expect(throws: (any Error).self) { try store.prepare(source) }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("registry.json").path))
}

@Test func oldCatalogIsIgnoredAndCorruptRegistryIsPreserved() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try PluginPackageStore(directory: directory)
    try Data("old debug catalog".utf8).write(to: directory.appendingPathComponent("plugins.json"))
    #expect(try PluginCatalog(directory: directory).records.isEmpty)
    let registry = directory.appendingPathComponent("registry.json")
    let store = try PrivateJSONStore(url: registry)
    try store.save(["schemaVersion": 3])
    let bytes = try Data(contentsOf: registry)
    #expect(throws: (any Error).self) { try PluginCatalog(directory: directory) }
    #expect(try Data(contentsOf: registry) == bytes)
}
