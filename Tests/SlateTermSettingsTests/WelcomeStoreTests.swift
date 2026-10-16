import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

private func withWelcomeDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-welcome-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root.appendingPathComponent("welcome.json"))
}

@Test func welcomeStartsUnreadAndPersistsExplicitAcknowledgement() throws {
    try withWelcomeDirectory { url in
        let store = WelcomeStore(url: url)
        #expect(store.snapshot.automaticDisplayEnabled)
        #expect(!FileManager.default.fileExists(atPath: url.path)) // reads are not writes
        let first = store.revision
        #expect(try store.setAcknowledged(true))
        #expect(store.revision != first)
        #expect(!store.snapshot.automaticDisplayEnabled)
        let restored = WelcomeStore(url: url)
        #expect(restored.acknowledged == true)
        #expect(restored.snapshot.content == .current)
        #expect(try restored.setAcknowledged(false))
        #expect(WelcomeStore(url: url).snapshot.automaticDisplayEnabled)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
}

@Test func welcomeNoOpsDoNotWriteOrAdvanceRevision() throws {
    try withWelcomeDirectory { url in
        let store = WelcomeStore(url: url), revision = store.revision
        #expect(try !store.setAcknowledged(false))
        #expect(store.revision == revision)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try store.setAcknowledged(true)
        let acknowledgedRevision = store.revision
        let bytes = try Data(contentsOf: url)
        #expect(try !store.setAcknowledged(true))
        #expect(store.revision == acknowledgedRevision)
        #expect(try Data(contentsOf: url) == bytes)
    }
}

@Test func damagedWelcomeStatePausesAutomaticDisplayWithoutOverwriting() throws {
    try withWelcomeDirectory { url in
        let invalid = Data("not-json".utf8)
        try invalid.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let store = WelcomeStore(url: url)
        #expect(store.acknowledged == nil)
        #expect(!store.snapshot.automaticDisplayEnabled)
        #expect(store.snapshot.error != nil)
        #expect(store.snapshot.content.text.contains(WelcomeContent.readCommand))
        #expect(try Data(contentsOf: url) == invalid)
        let value = try JSONValue.encoding(store.snapshot)
        #expect(value.object?["acknowledged"] == .null)
        // Only an explicit operation repairs invalid content.
        #expect(try store.setAcknowledged(false))
        #expect(store.diagnostic == nil)
        #expect(WelcomeStore(url: url).acknowledged == false)
    }
}

@Test func failedWelcomeWriteRetainsStateAndRevision() throws {
    try withWelcomeDirectory { url in
        let store = WelcomeStore(url: url), revision = store.revision
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.setAcknowledged(true) }
        #expect(store.acknowledged == false)
        #expect(store.revision == revision)
        #expect(store.snapshot.automaticDisplayEnabled)
        #expect(store.diagnostic != nil)
    }
}

@Test func welcomeRejectsSymlinkAndUnsafePermissions() throws {
    try withWelcomeDirectory { url in
        let target = url.deletingLastPathComponent().appendingPathComponent("other.json")
        try Data("true".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let store = WelcomeStore(url: url)
        #expect(store.acknowledged == nil)
        #expect(throws: (any Error).self) { try store.setAcknowledged(false) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "true")
        try FileManager.default.removeItem(at: url)
        try Data("false".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(WelcomeStore(url: url).acknowledged == nil)
    }
}
