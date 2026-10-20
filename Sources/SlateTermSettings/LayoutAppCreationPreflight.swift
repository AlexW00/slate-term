import Darwin
import Foundation
import SlateTermCore

/// Owns unpublished private state and its writer lease until creation publishes the app.
public final class LayoutAppCreationPreflight {
    public struct UnavailablePlugin: Codable, Equatable, Sendable {
        public let id: String
        public let reason: String
    }
    public let base: URL
    public let syncedPluginIDs: [String]
    public let unavailablePlugins: [UnavailablePlugin]
    public let copiedPluginDataIDs: [String]
    private let state: WorkspaceStore
    private var published = false

    private init(base: URL, state: WorkspaceStore, catalog: PluginCatalog,
                 unavailable: [UnavailablePlugin], copied: [String]) {
        self.base = base; self.state = state
        syncedPluginIDs = catalog.records.map(\.id)
        unavailablePlugins = unavailable; copiedPluginDataIDs = copied
    }

    deinit {
        if !published { try? FileManager.default.removeItem(at: base) }
        withExtendedLifetime(state) {}
    }

    public func retainPublishedState() { published = true }

    public static func parentRecords(parentBase: URL, allowEmpty: Bool = false) throws -> [InstalledPlugin] {
        let directory = parentBase.appendingPathComponent("plugins")
        let registry = directory.appendingPathComponent("registry.json")
        if allowEmpty, !FileManager.default.fileExists(atPath: registry.path),
           let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("packages").path),
           entries.isEmpty { return [] }
        let data = try readRegularFile(registry, maximumBytes: 1_048_576)
        struct Snapshot: Decodable { let schemaVersion: Int; let plugins: [InstalledPlugin] }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion == 1, snapshot.plugins.count <= 64,
              Set(snapshot.plugins.map(\.id)).count == snapshot.plugins.count else {
            throw RPCFailure(code: -32602, message: "Invalid parent plugin registry")
        }
        for record in snapshot.plugins {
            try PluginPersistence.validateID(record.id)
            guard record.archiveSHA256.count == 64,
                  record.archiveSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw RPCFailure(code: -32602, message: "Invalid parent plugin digest")
            }
        }
        return snapshot.plugins.sorted { $0.id < $1.id }
    }

    /// A nil recipe prepares the same inventory for the creation dialog's preview.
    public static func prepare(base: URL, parentBase: URL, recipe: SavedLayoutDefinition?,
                               copyPluginData: Bool) throws -> LayoutAppCreationPreflight {
        let manager = FileManager.default
        // Refuse existing roots so failure cleanup can only remove state from this attempt.
        try manager.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var completed = false
        defer { if !completed { try? manager.removeItem(at: base) } }
        let state = try WorkspaceStore(directory: base.appendingPathComponent("state"))
        defer { withExtendedLifetime(state) {} }
        var catalog = try PluginCatalog(directory: base.appendingPathComponent("plugins"))
        var unavailable: [UnavailablePlugin] = []
        var copied: [String] = []
        var inventoryBytes = 0
        let desired = try parentRecords(parentBase: parentBase, allowEmpty: true)
        for record in desired {
            try Task.checkCancellation()
            let prepared: PreparedPluginPackage
            do {
                let archive = parentBase.appendingPathComponent("plugins/packages/\(record.id)/\(record.installationID.uuidString.lowercased())/package.zip")
                prepared = try catalog.packages.prepare(archive)
                guard prepared.manifest.id == record.id, prepared.archiveSHA256 == record.archiveSHA256 else {
                    throw RPCFailure(code: -32602, message: "Parent package changed during synchronization")
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                let reason = String(String(describing: error).prefix(512))
                unavailable.append(.init(id: record.id, reason: reason))
                continue
            }
            guard let files = manager.enumerator(at: prepared.directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
                throw RPCFailure(code: -32602, message: "Could not inspect prepared plugin files")
            }
            for case let file as URL in files {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values.isRegularFile == true { inventoryBytes += values.fileSize ?? 0 }
                guard inventoryBytes <= 1_073_741_824 else {
                    throw RPCFailure(code: -32602, message: "Layout app plugin inventory exceeds 1 GiB")
                }
            }
            // Local publication errors abort creation instead of pretending the parent is unavailable.
            try catalog.register(prepared, replace: false)
            try catalog.setEnabled(record.id, enabled: record.enabled)
        }
        let reloaded = try PluginCatalog(directory: base.appendingPathComponent("plugins"))
        guard reloaded.diagnostics.isEmpty, reloaded.records == catalog.records,
              reloaded.registrations.count == catalog.records.count else {
            throw RPCFailure(code: -32602, message: "Prepared plugin inventory failed verification")
        }
        if let recipe {
            _ = try recipe.validated()
            let problems = recipe.problems(types: SavedLayoutPaneType.available(plugins: reloaded.activeRegistrations))
            guard problems.isEmpty else { throw RPCFailure(code: -32602, message: problems.joined(separator: "\n")) }
        }
        if copyPluginData {
            for id in reloaded.records.map(\.id) {
                let source = parentBase.appendingPathComponent("state/plugin-data-v2/\(id).json")
                var attributes = stat()
                if lstat(source.path, &attributes) != 0 {
                    if errno == ENOENT { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let data = try readRegularFile(source, maximumBytes: PluginPersistence.dataBytes + 4096)
                let document = try JSONDecoder().decode(PluginDataDocument.self, from: data)
                let target = try PluginDataStore(directory: base.appendingPathComponent("state/plugin-data-v2"), id: id)
                try target.persist(document)
                guard try PluginDataStore(directory: base.appendingPathComponent("state/plugin-data-v2"), id: id).document == document else {
                    throw RPCFailure(code: -32602, message: "Copied plugin data failed verification")
                }
                copied.append(id)
            }
        }
        let result = LayoutAppCreationPreflight(base: base, state: state, catalog: reloaded, unavailable: unavailable, copied: copied)
        completed = true
        return result
    }

    private static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= maximumBytes else {
            throw RPCFailure(code: -32602, message: "Plugin source must be a bounded regular file owned by this user")
        }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw RPCFailure(code: -32602, message: "Plugin source exceeds its size limit") }
        return data
    }
}
