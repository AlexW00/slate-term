import CryptoKit
import Darwin
import Foundation
import SlateArchive
import SlateTermCore

public struct PluginPackageLimits: Sendable {
    public var archiveBytes = 128 * 1024 * 1024
    public var extractedBytes = 512 * 1024 * 1024
    public var fileBytes = 64 * 1024 * 1024
    public var entries = 10_000
    public init() {}
}

public struct InstalledPlugin: Codable, Equatable, Sendable {
    public let id: String
    public let installationID: UUID
    public var enabled: Bool
    public let archiveSHA256: String
}

/// An immutable private snapshot. Destruction removes only its uncommitted staging tree.
public final class PreparedPluginPackage: Sendable {
    public let manifest: PluginManifest
    public let installationID: UUID
    public let archiveSHA256: String
    public let directory: URL
    init(manifest: PluginManifest, installationID: UUID, digest: String, directory: URL) {
        self.manifest = manifest; self.installationID = installationID
        archiveSHA256 = digest; self.directory = directory
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    public var validation: JSONValue {
        .object(["valid": .bool(true), "id": .string(manifest.id), "title": .string(manifest.title),
                 "manifest": manifest.value, "archiveSHA256": .string(archiveSHA256)])
    }
}

/// Filesystem preparation is independent of catalog publication. The host owns writer serialization.
public struct PluginPackageStore: Sendable {
    public let directory: URL
    public let limits: PluginPackageLimits
    public init(directory: URL, limits: PluginPackageLimits = .init()) throws {
        self.directory = directory; self.limits = limits
        try Self.privateDirectory(directory)
        try Self.privateDirectory(directory.appendingPathComponent("packages"))
        try Self.privateDirectory(directory.appendingPathComponent(".staging"))
    }

    public func generation(id: String, installationID: UUID) -> URL {
        directory.appendingPathComponent("packages").appendingPathComponent(id).appendingPathComponent(installationID.uuidString.lowercased())
    }
    public func root(_ record: InstalledPlugin) -> URL {
        generation(id: record.id, installationID: record.installationID).appendingPathComponent("contents")
    }

    public func prepare(_ url: URL) throws -> PreparedPluginPackage {
        guard url.isFileURL, url.pathExtension.lowercased() == "zip" else { throw invalid("Choose a .zip plugin package") }
        try Self.checkDirectory(directory)
        try Self.checkDirectory(directory.appendingPathComponent(".staging"))
        let staging = directory.appendingPathComponent(".staging").appendingPathComponent(UUID().uuidString)
        try Self.privateDirectory(staging)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: staging) } }
        let archive = staging.appendingPathComponent("package.zip")
        let digest = try copy(url, to: archive)
        let contents = staging.appendingPathComponent("contents")
        try Self.privateDirectory(contents)
        try inspectHeaders(archive)
        try extract(archive, to: contents)
        let manifest = try loadManifest(contents)
        _ = try manifest.registration(root: contents)
        let prepared = PreparedPluginPackage(manifest: manifest, installationID: UUID(), digest: digest, directory: staging)
        completed = true
        return prepared
    }

    public static func validate(_ url: URL) throws -> JSONValue {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("slate-package-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try PluginPackageStore(directory: temporary).prepare(url).validation
    }

    public func publish(_ prepared: PreparedPluginPackage) throws -> URL {
        try checkPackagesRoot()
        let parent = directory.appendingPathComponent("packages").appendingPathComponent(prepared.manifest.id)
        try Self.privateDirectory(parent)
        let destination = generation(id: prepared.manifest.id, installationID: prepared.installationID)
        try FileManager.default.moveItem(at: prepared.directory, to: destination)
        return destination
    }

    public func load(_ record: InstalledPlugin) throws -> PluginRegistration {
        try checkPackagesRoot()
        let generation = generation(id: record.id, installationID: record.installationID)
        try Self.checkDirectory(generation.deletingLastPathComponent())
        try Self.checkDirectory(generation)
        try Self.checkDirectory(root(record))
        guard try hash(generation.appendingPathComponent("package.zip")) == record.archiveSHA256 else { throw invalid("Installed ZIP checksum mismatch") }
        let manifest = try loadManifest(root(record))
        guard manifest.id == record.id else { throw invalid("Installed manifest identity mismatch") }
        return try manifest.registration(root: root(record))
    }

    /// Only a host-generated, validated generation can be removed. Never follows a root symlink.
    public func remove(_ record: InstalledPlugin) throws {
        try checkPackagesRoot()
        try PluginPersistence.validateID(record.id)
        let url = generation(id: record.id, installationID: record.installationID)
        try Self.checkDirectory(url.deletingLastPathComponent())
        try Self.checkDirectory(url)
        try FileManager.default.removeItem(at: url)
    }

    /// Call only at host startup under its exclusive state lease, before accepting requests.
    public func cleanAbandonedStaging() throws -> [String: String] {
        try Self.checkDirectory(directory)
        let staging = directory.appendingPathComponent(".staging")
        try Self.checkDirectory(staging)
        var diagnostics: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: staging.path) where UUID(uuidString: name) != nil {
            let candidate = staging.appendingPathComponent(name)
            do {
                try Self.checkDirectory(candidate)
                try FileManager.default.removeItem(at: candidate)
            } catch { diagnostics[candidate.path] = "Abandoned staging retained: \(error)" }
        }
        return diagnostics
    }

    /// Prior-session processes have no in-memory cleanup receipts: report, never guess/delete.
    public func orphanRoots(referenced: [InstalledPlugin]) throws -> [String: String] {
        try checkPackagesRoot()
        let packages = directory.appendingPathComponent("packages")
        let selected = Set(referenced.map { root($0).path })
        var result: [String: String] = [:]
        for id in try FileManager.default.contentsOfDirectory(atPath: packages.path) {
            let parent = packages.appendingPathComponent(id)
            do {
                try PluginPersistence.validateID(id)
                try Self.checkDirectory(parent)
                for name in try FileManager.default.contentsOfDirectory(atPath: parent.path) where UUID(uuidString: name) != nil {
                    let generation = parent.appendingPathComponent(name)
                    let root = generation.appendingPathComponent("contents")
                    do {
                        try Self.checkDirectory(generation)
                        if !selected.contains(root.path) { result[root.path] = "Previous-session package retained: process cleanup cannot be confirmed" }
                    } catch { result[root.path] = "Unsafe package generation retained: \(error)" }
                }
            } catch { result[parent.appendingPathComponent("unavailable/contents").path] = "Unsafe package directory retained: \(error)" }
        }
        return result
    }

    private func checkPackagesRoot() throws {
        try Self.checkDirectory(directory)
        try Self.checkDirectory(directory.appendingPathComponent("packages"))
    }

    private func loadManifest(_ root: URL) throws -> PluginManifest {
        let url = root.appendingPathComponent("plugin.json")
        let handle = try Self.regularReader(url)
        defer { try? handle.close() }
        return try PluginManifest(data: handle.read(upToCount: 262_145) ?? Data())
    }

    private func copy(_ source: URL, to destination: URL) throws -> String {
        let input = try Self.regularReader(source)
        defer { try? input.close() }
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        var digest = SHA256(), bytes = 0
        while let data = try input.read(upToCount: 65_536), !data.isEmpty {
            try Task.checkCancellation()
            bytes += data.count
            guard bytes <= limits.archiveBytes else { throw invalid("Plugin ZIP exceeds compressed size limit") }
            digest.update(data: data)
            try output.write(contentsOf: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func hash(_ source: URL) throws -> String {
        let handle = try Self.regularReader(source)
        defer { try? handle.close() }
        var digest = SHA256(), bytes = 0
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
            bytes += data.count
            guard bytes <= limits.archiveBytes else { throw invalid("Installed ZIP exceeds compressed size limit") }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// libarchive normalizes DOS backslashes. Inspect bounded original headers first so
    /// that invalid names cannot become acceptable paths before our extraction checks.
    /// ZIP64/multi-disk/SFX archives are intentionally outside this small package format.
    private func inspectHeaders(_ url: URL) throws {
        let handle = try Self.regularReader(url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limits.archiveBytes + 1) ?? Data()
        guard data.count >= 22, data.count <= limits.archiveBytes else { throw invalid("Invalid ZIP size") }
        func integer(_ offset: Int, _ width: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - width else { throw invalid("Truncated ZIP header") }
            return (0..<width).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try integer(offset, 4) == 0x06054b50, try offset + 22 + integer(offset + 20, 2) == data.count { end = offset; break }
        }
        guard let end, try integer(end + 4, 2) == 0, try integer(end + 6, 2) == 0 else { throw invalid("ZIP requires a single complete directory") }
        let count = try integer(end + 10, 2), centralBytes = try integer(end + 12, 4), start = try integer(end + 16, 4)
        guard count > 0, count <= limits.entries, count != 65_535,
              try integer(end + 8, 2) == count, start + centralBytes == end,
              try integer(0, 4) == 0x04034b50 else { throw invalid("Unsupported ZIP directory, ZIP64, or entry count") }
        var offset = start
        var localOffsets = Set<Int>()
        for _ in 0..<count {
            guard try integer(offset, 4) == 0x02014b50 else { throw invalid("Invalid ZIP central header") }
            let flags = try integer(offset + 8, 2), method = try integer(offset + 10, 2)
            let compressed = try integer(offset + 20, 4), expanded = try integer(offset + 24, 4)
            let nameBytes = try integer(offset + 28, 2), extra = try integer(offset + 30, 2), comment = try integer(offset + 32, 2)
            let local = try integer(offset + 42, 4)
            guard flags & 0x2041 == 0, method == 0 || method == 8, expanded <= limits.fileBytes,
                  try integer(offset + 34, 2) == 0, localOffsets.insert(local).inserted,
                  offset + 46 + nameBytes + extra + comment <= end, nameBytes > 0 else { throw invalid("Unsupported or oversized ZIP entry") }
            let name = data.subdata(in: (offset + 46)..<(offset + 46 + nameBytes))
            guard let path = String(data: name, encoding: .utf8), !path.contains("\\"),
                  try integer(local, 4) == 0x04034b50,
                  try integer(local + 6, 2) == flags, try integer(local + 8, 2) == method,
                  try integer(local + 26, 2) == nameBytes else { throw invalid("Invalid ZIP name or local header") }
            _ = try PluginManifest.relativePath(path.hasSuffix("/") ? String(path.dropLast()) : path)
            let localExtra = try integer(local + 28, 2)
            let payload = local + 30 + nameBytes + localExtra
            guard payload <= start, compressed <= start - payload,
                  data.subdata(in: (local + 30)..<(local + 30 + nameBytes)) == name else { throw invalid("ZIP local/central entries disagree") }
            offset += 46 + nameBytes + extra + comment
        }
        guard offset == end else { throw invalid("ZIP directory size mismatch") }
    }

    private func extract(_ url: URL, to root: URL) throws {
        guard let zip = slate_zip_open(url.path) else { throw invalid("Invalid or unsupported plugin ZIP") }
        defer { slate_zip_close(zip) }
        var entry = SlateZIPEntry(), entries = 0, total = 0
        var declared = Set<String>(), nodes: [String: Bool] = [:], spellings: [String: String] = [:]
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let status = slate_zip_next(zip, &entry)
            if status == 1 { break }
            guard status == 0, let name = entry.path, let raw = String(validatingCString: name),
                  entry.linked == 0, entry.encrypted == 0, entry.directory != 0 || entry.regular != 0 else {
                throw invalid("ZIP has an unsupported, linked, encrypted, or corrupt entry")
            }
            entries += 1
            guard entries <= limits.entries else { throw invalid("ZIP has too many entries") }
            let isDirectory = entry.directory != 0
            let path = try PluginManifest.relativePath(isDirectory && raw.hasSuffix("/") ? String(raw.dropLast()) : raw)
            let components = path.split(separator: "/").map(String.init)
            let key = path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard declared.insert(key).inserted else { throw invalid("ZIP has duplicate or case/Unicode-colliding paths") }
            for count in 1...components.count {
                let prefix = components.prefix(count).joined(separator: "/")
                let normalized = prefix.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                let directory = count < components.count || isDirectory
                if let existing = nodes[normalized], !existing || !directory { throw invalid("ZIP has conflicting file/directory paths") }
                // Reject differently-spelled aliases even when only their parent directory collides.
                if let spelling = spellings[normalized], spelling != prefix { throw invalid("ZIP has colliding directory spellings") }
                nodes[normalized] = directory; spellings[normalized] = prefix
                if directory { try Self.privateDirectory(root.appendingPathComponent(prefix)) }
            }
            let target = root.appendingPathComponent(path)
            guard entry.size >= 0, entry.size <= limits.fileBytes else { throw invalid("ZIP entry exceeds file size limit") }
            var fileBytes = 0
            let descriptor = isDirectory ? -1 : open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, entry.executable != 0 ? 0o700 : 0o600)
            guard isDirectory || descriptor >= 0 else { throw invalid("Could not create ZIP entry without overwriting") }
            let handle = descriptor >= 0 ? FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) : nil
            defer { try? handle?.close() }
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { slate_zip_read(zip, $0.baseAddress, $0.count) }
                guard count >= 0 else { throw invalid("ZIP decompression or checksum validation failed") }
                if count == 0 { break }
                fileBytes += Int(count); total += Int(count)
                guard !isDirectory, fileBytes <= limits.fileBytes, total <= limits.extractedBytes,
                      path != "plugin.json" || fileBytes <= 262_144 else { throw invalid("ZIP exceeds extracted size limits") }
                try handle?.write(contentsOf: Data(buffer.prefix(Int(count))))
            }
            guard fileBytes == entry.size else { throw invalid("ZIP entry size mismatch") }
        }
        guard declared.contains("plugin.json") else { throw invalid("ZIP requires plugin.json at its root") }
    }

    private static func regularReader(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(.ENOENT) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor); throw ConfigurationError.invalid("Package input must be a regular file, not a symlink")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkDirectory(url)
    }
    private static func checkDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw ConfigurationError.invalid("Package directory must be private, owned, and not a symlink") }
    }
    private func invalid(_ message: String) -> RPCFailure { RPCFailure(code: -32602, message: message) }
}
