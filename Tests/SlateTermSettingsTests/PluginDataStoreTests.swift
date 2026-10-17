import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Test func pluginDataStorePersistsRevisionAndEmptyResetWithoutLegacyMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PluginDataStore(directory: root, id: "acme.notes")
    #expect(!FileManager.default.fileExists(atPath: store.url.path))
    let reset = try store.document.changing(operations: nil, expectedRevision: store.document.revision)
    try store.persist(reset)
    #expect(store.document != reset) // persistence does not publish a new cache value
    store.accept(reset)
    let reopened = try PluginDataStore(directory: root, id: "acme.notes")
    #expect(reopened.document == reset)
    let previous = store.document
    let ops: JSONValue = .array([.object(["op": .string("set"), "key": .string("draft"), "value": .string("saved")])])
    let candidate = try previous.changing(operations: ops, expectedRevision: previous.revision)
    try store.persist(candidate)
    store.accept(candidate)
    #expect(try PluginDataStore(directory: root, id: "acme.notes").document == candidate)
    #expect(try PluginDataStore(directory: root, id: "other").document.values.isEmpty)
    #expect(throws: (any Error).self) { try PluginDataStore(directory: root, id: "../escape") }
    #expect(throws: (any Error).self) { try PluginDataStore(directory: root, id: "acme.notes\n") }
}

@Test(.enabled(if: geteuid() != 0)) func pluginDataFileFailureLeavesCacheAndFileUnchanged() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PluginDataStore(directory: root, id: "notes")
    let initial = try store.document.changing(operations: nil, expectedRevision: store.document.revision)
    try store.persist(initial); store.accept(initial)
    let bytes = try Data(contentsOf: store.url)
    let next = try initial.changing(operations: nil, expectedRevision: initial.revision)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
    #expect(throws: (any Error).self) { try store.persist(next) }
    #expect(store.document == initial)
    #expect(try Data(contentsOf: store.url) == bytes)
}

@Test func corruptPluginDataIsNotAnEmptyNamespace() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try PluginDataStore(directory: root, id: "notes")
    let bytes = Data("{bad".utf8)
    try bytes.write(to: store.url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
    #expect(throws: (any Error).self) { try PluginDataStore(directory: root, id: "notes") }
    #expect(try Data(contentsOf: store.url) == bytes)
}
