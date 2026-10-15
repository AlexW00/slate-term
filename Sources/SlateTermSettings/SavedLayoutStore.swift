import CryptoKit
import Darwin
import Foundation
import SlateTermCore

/// Files are authoritative; every operation rescans rather than caching a catalog.
public struct SavedLayoutStore: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw savedStoreFailure("Saved layouts require a file directory") }
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkDirectory()
    }

    public func list() throws -> [SavedLayoutEntry] {
        try withLock { try scan().map(\.entry) }
    }

    public func get(id: UUID) throws -> SavedLayoutEntry {
        try withLock { try uniqueEntry(id: id, in: scan()).entry }
    }

    public func create(_ definition: SavedLayoutDefinition) throws -> SavedLayoutEntry {
        let definition = try definition.validated()
        let data = try encoded(definition)
        return try withLock {
            let records = try scan()
            guard !records.contains(where: { $0.identity == definition.id }) else {
                throw savedStoreFailure("A saved layout with ID \(definition.id) already exists")
            }
            guard records.count < 256 else { throw savedStoreFailure("Saved layout directory is limited to 256 JSON files") }
            let file = definition.id.uuidString + ".json"
            let destination = directory.appendingPathComponent(file)
            let temporary = try writeTemporary(data)
            defer { unlink(temporary.path) }
            // link publishes a complete file and fails if *any* destination exists.
            guard link(temporary.path, destination.path) == 0 else {
                throw savedStoreSystemFailure("Could not create saved layout without overwriting \(file)")
            }
            return SavedLayoutEntry(file: file, definition: definition, revision: revision(data))
        }
    }

    public func update(_ definition: SavedLayoutDefinition, expectedRevision: String) throws -> SavedLayoutEntry {
        let definition = try definition.validated()
        let data = try encoded(definition)
        return try withLock {
            let original = try uniqueEntry(id: definition.id, in: scan()).entry
            guard original.revision == expectedRevision else { throw revisionConflict(original.file) }
            let temporary = try writeTemporary(data)
            defer { unlink(temporary.path) }
            // Recheck identity, duplicates and contents after staging. flock serializes
            // cooperating writers; the final check is best-effort for external editors.
            let current = try uniqueEntry(id: definition.id, in: scan()).entry
            guard current.file == original.file, current.revision == expectedRevision else {
                throw revisionConflict(original.file)
            }
            let destination = directory.appendingPathComponent(original.file)
            let latest = try readDocument(destination)
            guard revision(latest) == expectedRevision else { throw revisionConflict(original.file) }
            var info = stat()
            guard lstat(destination.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw savedStoreFailure("Saved layout changed to a missing or nonregular file: \(original.file)")
            }
            guard rename(temporary.path, destination.path) == 0 else {
                throw savedStoreSystemFailure("Could not replace saved layout \(original.file)")
            }
            return SavedLayoutEntry(file: original.file, definition: definition, revision: revision(data))
        }
    }

    private func checkDirectory() throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw savedStoreFailure("Saved layout directory must be a real directory owned by this user")
        }
    }

    private func withLock<Value>(_ operation: () throws -> Value) throws -> Value {
        try checkDirectory()
        // Never unlink this file: another writer may still hold its inode's lock.
        let descriptor = open(directory.appendingPathComponent(".saved-layouts.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw savedStoreSystemFailure("Could not open saved layout lock") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else {
            throw savedStoreFailure("Saved layout lock must be an owner-only regular file")
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EINTR else { throw savedStoreSystemFailure("Saved layouts are busy; try again after the other operation finishes") }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func scan() throws -> [SavedLayoutRecord] {
        let files = try filenames()
        var records = files.map { file -> SavedLayoutRecord in
            var data: Data?
            do {
                let bytes = try readDocument(directory.appendingPathComponent(file))
                data = bytes
                let definition = try SavedLayoutDefinition.parse(bytes)
                return SavedLayoutRecord(identity: definition.id,
                                         entry: SavedLayoutEntry(file: file, definition: definition, revision: revision(bytes)))
            } catch {
                // Even an invalid recipe's readable UUID participates in duplicate checks.
                let identity = data.flatMap { bytes -> UUID? in
                    guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                          let id = object["id"] as? String else { return nil }
                    return UUID(uuidString: id)
                }
                let message = (error as? RPCFailure)?.message ?? error.localizedDescription
                return SavedLayoutRecord(identity: identity,
                                         entry: SavedLayoutEntry(file: file, revision: data.map(revision), diagnostic: message))
            }
        }
        let counts = Dictionary(grouping: records.compactMap(\.identity), by: { $0 }).mapValues(\.count)
        for index in records.indices {
            if let identity = records[index].identity, (counts[identity] ?? 0) > 1 {
                let entry = records[index].entry
                records[index].entry = SavedLayoutEntry(file: entry.file, revision: entry.revision,
                                                       diagnostic: "Duplicate saved layout ID: \(identity)")
            }
        }
        return records
    }

    private func filenames() throws -> [String] {
        guard let stream = opendir(directory.path) else { throw savedStoreSystemFailure("Could not scan saved layouts") }
        defer { closedir(stream) }
        var files: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw savedStoreSystemFailure("Could not scan saved layouts") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            guard name.hasSuffix(".json") else { continue }
            guard files.count < 256 else { throw savedStoreFailure("Saved layout directory exceeds 256 JSON files; move excess files elsewhere") }
            files.append(name)
        }
        return files.sorted()
    }

    private func uniqueEntry(id: UUID, in records: [SavedLayoutRecord]) throws -> SavedLayoutRecord {
        let matches = records.filter { $0.identity == id }
        guard matches.count == 1 else {
            throw savedStoreFailure(matches.isEmpty ? "Saved layout not found: \(id)" : "Duplicate saved layout ID: \(id)")
        }
        let record = matches[0]
        guard record.entry.definition != nil, record.entry.diagnostic == nil else {
            throw savedStoreFailure("Cannot use \(record.entry.file): \(record.entry.diagnostic ?? "invalid saved layout")")
        }
        return record
    }

    private func readDocument(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw savedStoreSystemFailure("Could not read \(url.lastPathComponent)") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw savedStoreFailure("Saved layout is not a regular file: \(url.lastPathComponent)")
        }
        guard info.st_size <= 262_144 else { throw savedStoreFailure("Saved layout exceeds 256 KiB: \(url.lastPathComponent)") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count <= 262_144 {
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, 262_145 - data.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw savedStoreSystemFailure("Could not read \(url.lastPathComponent)")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= 262_144 else { throw savedStoreFailure("Saved layout exceeds 256 KiB: \(url.lastPathComponent)") }
        return data
    }

    private func encoded(_ definition: SavedLayoutDefinition) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(definition)
        guard data.count <= 262_144 else { throw savedStoreFailure("Saved layout exceeds 256 KiB") }
        return data
    }

    private func writeTemporary(_ data: Data) throws -> URL {
        let temporary = directory.appendingPathComponent(".saved-layout-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw savedStoreSystemFailure("Could not stage saved layout") }
        defer { Darwin.close(descriptor) }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw savedStoreSystemFailure("Could not write staged saved layout") }
                    offset += count
                }
            }
            return temporary
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    private func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func revisionConflict(_ file: String) -> RPCFailure {
        RPCFailure(code: APIError.conflict, message: "Saved layout changed externally; reload before saving: \(file)")
    }
}

public struct SavedLayoutEntry: Codable, Equatable, Sendable, Identifiable {
    public let file: String
    public var id: String { file }
    public let definition: SavedLayoutDefinition?
    public let revision: String?
    public let diagnostic: String?

    public init(file: String, definition: SavedLayoutDefinition? = nil, revision: String? = nil, diagnostic: String? = nil) {
        self.file = file
        self.definition = definition
        self.revision = revision
        self.diagnostic = diagnostic
    }
}

private struct SavedLayoutRecord {
    let identity: UUID?
    var entry: SavedLayoutEntry
}

private func savedStoreFailure(_ message: String) -> RPCFailure { RPCFailure(code: -32602, message: message) }
private func savedStoreSystemFailure(_ message: String) -> RPCFailure {
    savedStoreFailure("\(message): \(String(cString: strerror(errno)))")
}
