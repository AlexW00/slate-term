import Foundation
import Testing
@testable import SlateTermSettings

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
