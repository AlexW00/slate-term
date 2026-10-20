import Foundation
import Testing
@testable import SlateTermSettings

@Test func fileObservationAncestorTraversalStopsAtTheFilesystemRoot() {
    #expect(observationAncestorPaths(for: URL(fileURLWithPath: "/")) == ["/"])
    #expect(observationAncestorPaths(for: URL(fileURLWithPath: "/config.toml")) == ["/"])
    #expect(observationAncestorPaths(for: URL(fileURLWithPath: "/missing/nested/config.toml"))
            == ["/missing/nested", "/missing", "/"])
    #expect(observationAncestorPaths(for: URL(fileURLWithPath: "/missing/nested/../config.toml"))
            == ["/missing", "/"])
}

@Test func missingObservationTargetsResolveExistingSymlinkAncestors() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-path-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let real = root.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
    #expect(canonicalObservationPath(for: alias.appendingPathComponent("missing/plugins"))
            == canonicalObservationPath(for: real) + "/missing/plugins")
    #expect(canonicalObservationPath(for: URL(fileURLWithPath: "/")) == "/")
}

@Test @MainActor func configurationWatcherSurvivesCreationAtomicReplacementAndInPlaceEdits() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-watch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.toml")
    var observed: String?
    let watcher = try ConfigurationWatcher(url: file) { observed = try? String(contentsOf: file, encoding: .utf8) }
    defer { watcher.close() }
    try "first".write(to: file, atomically: true, encoding: .utf8)
    try await waitFor { observed == "first" }
    try "replaced".write(to: file, atomically: true, encoding: .utf8)
    try await waitFor { observed == "replaced" }
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data("in-place".utf8))
    try handle.close()
    try await waitFor { observed == "in-place" }
    try FileManager.default.removeItem(at: file)
    try await waitFor { observed == nil }
    try "recreated".write(to: file, atomically: true, encoding: .utf8)
    try await waitFor { observed == "recreated" }
}

@Test @MainActor func unrelatedDirectoryWritesDoNotCauseReloadFeedback() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-watch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.toml")
    let generated = directory.appendingPathComponent("terminal.conf")
    var changes = 0
    var writeError: (any Error)?
    let watcher = try ConfigurationWatcher(url: file) {
        changes += 1
        do { try "generated".write(to: generated, atomically: true, encoding: .utf8) }
        catch { writeError = error }
    }
    defer { watcher.close() }
    try "configuration".write(to: file, atomically: true, encoding: .utf8)
    try await waitFor { changes > 0 }
    // A bounded quiet window must span multiple 100ms coalescing cycles.
    try await Task.sleep(for: .milliseconds(400))
    #expect(writeError == nil)
    #expect(changes == 1)
}

@Test @MainActor func acknowledgedOwnWritesDoNotReloadButSupersedingEditsStillDo() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-watch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.toml")
    var observed: [String] = []
    let watcher = try ConfigurationWatcher(url: file) { observed.append((try? String(contentsOf: file, encoding: .utf8)) ?? "missing") }
    defer { watcher.close() }
    try "own".write(to: file, atomically: true, encoding: .utf8)
    watcher.acknowledgeAppliedContents(Data("own".utf8))
    try await Task.sleep(for: .milliseconds(300))
    #expect(observed.isEmpty)
    try "external".write(to: file, atomically: true, encoding: .utf8)
    watcher.acknowledgeAppliedContents(Data("own".utf8))
    try await waitFor { observed == ["external"] }
    try "next own".write(to: file, atomically: true, encoding: .utf8)
    watcher.acknowledgeAppliedContents(Data("next own".utf8))
    try "later external".write(to: file, atomically: true, encoding: .utf8)
    try await waitFor { observed == ["external", "later external"] }
}

@MainActor private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw ConfigurationError.invalid("File watcher deadline expired") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func readOnlyConfigurationWatcherSurvivesMissingAndReplacedParents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-read-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("missing/nested")
    let file = directory.appendingPathComponent("config.toml")
    var observed: String?
    let watcher = try ConfigurationWatcher(url: file, createDirectory: false) {
        observed = try? String(contentsOf: file, encoding: .utf8)
    }
    defer { watcher.close() }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "first".write(to: file, atomically: true, encoding: .utf8)
    try await waitFor { observed == "first" }
    let moved = root.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: root.appendingPathComponent("missing"), to: moved)
    try await waitFor { observed == nil }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "replacement".write(to: file, atomically: true, encoding: .utf8)
    try await waitFor { observed == "replacement" }
    try FileManager.default.removeItem(at: root.appendingPathComponent("missing"))
    try await waitFor { observed == nil }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}

@Test @MainActor func directoryTreeWatcherObservesNestedWritesAndTreeRecreationWithoutCreatingIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-tree-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("plugins")
    let nested = directory.appendingPathComponent("packages/example/installation")
    let file = nested.appendingPathComponent("package.zip")
    var changes = 0
    let watcher = try DirectoryTreeWatcher(url: directory) { changes += 1 }
    defer { watcher.close() }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("first".utf8).write(to: file)
    try await waitFor { changes > 0 }
    try await Task.sleep(for: .milliseconds(400))
    var before = changes
    let handle = try FileHandle(forWritingTo: file)
    try handle.write(contentsOf: Data("in-place".utf8))
    try handle.close()
    try await waitFor { changes > before }
    try await Task.sleep(for: .milliseconds(400))
    before = changes
    try Data("atomic".utf8).write(to: file, options: .atomic)
    try await waitFor { changes > before }
    try await Task.sleep(for: .milliseconds(400))
    before = changes
    try FileManager.default.removeItem(at: directory)
    try await waitFor { changes > before }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    try await Task.sleep(for: .milliseconds(400))
    before = changes
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("recreated".utf8).write(to: file)
    try await waitFor { changes > before }
    watcher.close()
    try await Task.sleep(for: .milliseconds(300))
    before = changes
    try Data("closed".utf8).write(to: file)
    try await Task.sleep(for: .milliseconds(500))
    #expect(changes == before)
}
