import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func workspaceStoreRoundTripsIdentityAndCanReplaceAnExistingSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WorkspaceStore(directory: directory)
    #expect(try store.load() == nil)
    var workspace = Workspace()
    let pane = try workspace.split(PaneID(1), direction: .right)
    _ = try workspace.newTab(in: GroupID(1))
    try store.save(workspace)
    #expect(try store.load() == workspace)
    try workspace.close(pane)
    try store.save(workspace)
    var restored = try #require(try store.load())
    #expect(restored == workspace)
    #expect(try restored.split(PaneID(1), direction: .down) == PaneID(4))
    let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func aStateDirectoryHasOneWriterAndReleasesOwnership() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var first: WorkspaceStore? = try WorkspaceStore(directory: directory)
    _ = withExtendedLifetime(first) {
        #expect(throws: (any Error).self) { try WorkspaceStore(directory: directory) }
    }
    first = nil
    let reopened = try WorkspaceStore(directory: directory)
    try reopened.save(Workspace())
    #expect(try reopened.load() == Workspace())
}

@Test func corruptSnapshotIsReportedWithoutReplacingOrDeletingTheFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WorkspaceStore(directory: directory)
    let corrupt = Data("{ unfinished state".utf8)
    try corrupt.write(to: store.url)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(try Data(contentsOf: store.url) == corrupt)
}

@Test func workspaceStoreRejectsUnsafeDirectoriesAndInvalidModelReferences() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    #expect(throws: (any Error).self) { try WorkspaceStore(directory: directory) }
    #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let store = try WorkspaceStore(directory: directory)
    var raw = try #require(try JSONSerialization.jsonObject(with: Workspace().encoded()) as? [String: Any])
    var tabs = try #require(raw["tabs"] as? [[String: Any]])
    tabs[0]["focusedPane"] = "p999"
    raw["tabs"] = tabs
    let invalid = try JSONSerialization.data(withJSONObject: raw)
    try invalid.write(to: store.url)
    #expect(throws: (any Error).self) { try store.load() }
    #expect(try Data(contentsOf: store.url) == invalid)
}

@Test(.enabled(if: geteuid() != 0)) func failedSavePreservesPreviousSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try WorkspaceStore(directory: directory)
    var workspace = Workspace()
    try store.save(workspace)
    let original = try Data(contentsOf: store.url)
    try workspace.split(PaneID(1), direction: .right)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    #expect(throws: (any Error).self) { try store.save(workspace) }
    #expect(try Data(contentsOf: store.url) == original)
}
