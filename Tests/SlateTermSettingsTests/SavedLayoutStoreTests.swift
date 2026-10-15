import Darwin
import Foundation
import Testing
import SlateTermCore
import SlateTermSettings

@Suite struct SavedLayoutStoreTests {
    @Test func malformedMissingIdentityAndUnknownFieldsRemainVisibleWithoutDataLoss() throws {
        let directory = savedStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SavedLayoutStore(directory: directory)
        let valid = try store.create(.blank(name: "Valid"))
        let corrupt = Data("{ unfinished".utf8)
        var missing = try savedStoreObject(.blank())
        missing.removeValue(forKey: "id")
        var unknown = try savedStoreObject(.blank())
        unknown["future"] = ["preserve": true]
        let bytes = ["broken.json": corrupt, "missing.json": try JSONSerialization.data(withJSONObject: missing),
                     "future.json": try JSONSerialization.data(withJSONObject: unknown)]
        for (file, data) in bytes { try data.write(to: directory.appendingPathComponent(file)) }
        let entries = try store.list()
        #expect(entries.count == 4)
        #expect(entries.filter { $0.diagnostic != nil }.count == 3)
        #expect(entries.first { $0.id == valid.id } == valid)
        for (file, data) in bytes {
            #expect(entries.contains { $0.id == file && $0.definition == nil && $0.diagnostic != nil })
            #expect(try Data(contentsOf: directory.appendingPathComponent(file)) == data)
        }
        let unknownID = try #require(UUID(uuidString: unknown["id"] as! String))
        #expect(throws: RPCFailure.self) { try store.get(id: unknownID) }
    }

    @Test func opaquePluginRecipesRoundTripWithoutRuntimeRegistration() throws {
        let directory = savedStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SavedLayoutStore(directory: directory)
        var definition = SavedLayoutDefinition.blank()
        definition.tabs[0].panes[0].type = "unregistered.plugin"
        definition.tabs[0].panes[0].configuration = ["future": .object([
            "nested": .array([.string("keep me"), .number(0.75), .null, .bool(false)])])]
        let created = try store.create(definition)
        #expect(try store.get(id: definition.id) == created)
        definition.name = "Renamed"
        let updated = try store.update(definition, expectedRevision: created.revision!)
        #expect(try store.get(id: definition.id) == updated)
        #expect(updated.definition == definition)
    }

    @Test func externalChangesConflictAndRenamedFilesRemainAuthoritative() throws {
        let directory = savedStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SavedLayoutStore(directory: directory)
        var definition = SavedLayoutDefinition.blank(name: "Original")
        let created = try store.create(definition)
        let renamed = directory.appendingPathComponent("chosen-name.json")
        try FileManager.default.moveItem(at: directory.appendingPathComponent(created.file), to: renamed)
        #expect(try store.get(id: definition.id).file == "chosen-name.json")
        var external = definition
        external.name = "External"
        let externalBytes = try JSONEncoder().encode(external)
        try externalBytes.write(to: renamed)
        definition.name = "My edit"
        do {
            _ = try store.update(definition, expectedRevision: created.revision!)
            Issue.record("Stale layout write unexpectedly succeeded")
        } catch let error as RPCFailure { #expect(error.code == APIError.conflict) }
        #expect(try Data(contentsOf: renamed) == externalBytes)
        let reloaded = try store.get(id: definition.id)
        let updated = try store.update(definition, expectedRevision: reloaded.revision!)
        #expect(updated.file == "chosen-name.json")
        #expect(updated.definition == definition)
        #expect(updated.revision != reloaded.revision)
        #expect(try store.list() == [updated])
        #expect(try SavedLayoutDefinition.parse(Data(contentsOf: renamed)) == definition)
        #expect((try FileManager.default.attributesOfItem(atPath: renamed.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func duplicateIDsIncludingMalformedRecipesCannotBeUsedOrUpdated() throws {
        let directory = savedStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SavedLayoutStore(directory: directory)
        let definition = SavedLayoutDefinition.blank()
        let first = try store.create(definition)
        let duplicateURL = directory.appendingPathComponent("duplicate.json")
        try JSONEncoder().encode(definition).write(to: duplicateURL)
        for malformed in [false, true] {
            if malformed {
                var object = try savedStoreObject(definition)
                object["future"] = true
                try JSONSerialization.data(withJSONObject: object).write(to: duplicateURL)
            }
            let before = try Data(contentsOf: directory.appendingPathComponent(first.file))
            let entries = try store.list()
            #expect(entries.count == 2)
            #expect(entries.allSatisfy { $0.definition == nil && $0.diagnostic?.contains("Duplicate") == true })
            #expect(throws: RPCFailure.self) { try store.get(id: definition.id) }
            #expect(throws: RPCFailure.self) { try store.update(definition, expectedRevision: first.revision!) }
            #expect(throws: RPCFailure.self) { try store.create(definition) }
            #expect(try Data(contentsOf: directory.appendingPathComponent(first.file)) == before)
        }
    }

    @Test func createNeverOverwritesExistingFilesAndUsesPrivatePermissions() throws {
        let directory = savedStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SavedLayoutStore(directory: directory)
        let definition = SavedLayoutDefinition.blank()
        let destination = directory.appendingPathComponent(definition.id.uuidString + ".json")
        let unknown = Data("unknown user file".utf8)
        try unknown.write(to: destination)
        #expect(throws: RPCFailure.self) { try store.create(definition) }
        #expect(try Data(contentsOf: destination) == unknown)
        let created = try store.create(.blank(name: "Different"))
        #expect(created.file == created.definition!.id.uuidString + ".json")
        #expect((try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(created.file).path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func symlinksNonregularAndOversizedFilesAreDiagnosticsNotOverwriteTargets() throws {
        let directory = savedStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SavedLayoutStore(directory: directory)
        let definition = SavedLayoutDefinition.blank()
        let target = directory.appendingPathComponent("outside.txt")
        let original = try JSONEncoder().encode(definition)
        try original.write(to: target)
        let symlinkURL = directory.appendingPathComponent(definition.id.uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: target)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.json"), withIntermediateDirectories: false)
        try Data(repeating: 32, count: 262_145).write(to: directory.appendingPathComponent("large.json"))
        #expect(mkfifo(directory.appendingPathComponent("pipe.json").path, 0o600) == 0)
        let entries = try store.list()
        #expect(entries.count == 4)
        #expect(entries.allSatisfy { $0.definition == nil && $0.diagnostic != nil })
        #expect(throws: RPCFailure.self) { try store.create(definition) }
        #expect(throws: RPCFailure.self) { try store.update(definition, expectedRevision: "anything") }
        #expect(try Data(contentsOf: target) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: symlinkURL.path) == target.path)
    }

    @Test func externallyMalformedUpdateIsNeverReplacedEvenWithItsLatestRevision() throws {
        let directory = savedStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SavedLayoutStore(directory: directory)
        let definition = SavedLayoutDefinition.blank()
        let created = try store.create(definition)
        var object = try savedStoreObject(definition)
        object["future"] = "do not discard"
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let file = directory.appendingPathComponent(created.file)
        try bytes.write(to: file)
        let invalid = try #require(try store.list().first)
        #expect(throws: RPCFailure.self) { try store.update(definition, expectedRevision: invalid.revision!) }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func concurrentCooperatingCreatesPublishExactlyOneCompleteFile() async throws {
        let directory = savedStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SavedLayoutStore(directory: directory)
        let second = try SavedLayoutStore(directory: directory)
        let definition = SavedLayoutDefinition.blank()
        let successes = await withTaskGroup(of: Bool.self) { group in
            for store in [first, second] {
                group.addTask { (try? store.create(definition)) != nil }
            }
            var successes = 0
            for await success in group { if success { successes += 1 } }
            return successes
        }
        #expect(successes == 1)
        #expect(try first.list().count == 1)
        #expect(try second.get(id: definition.id).definition == definition)
    }

    @Test func catalogLimitFailsRatherThanHidingPossibleDuplicates() throws {
        let directory = savedStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SavedLayoutStore(directory: directory)
        for index in 0..<256 { try Data("{}".utf8).write(to: directory.appendingPathComponent("\(index).json")) }
        #expect(try store.list().count == 256)
        #expect(throws: RPCFailure.self) { try store.create(.blank()) }
        try Data("{}".utf8).write(to: directory.appendingPathComponent("excess.json"))
        #expect(throws: RPCFailure.self) { try store.list() }
    }
}

private func savedStoreDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("slate-saved-layouts-\(UUID().uuidString)")
}

private func savedStoreObject(_ definition: SavedLayoutDefinition) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition)) as! [String: Any]
}
