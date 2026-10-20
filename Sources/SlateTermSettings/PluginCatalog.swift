import Foundation
import SlateTermCore

/// The registry is the commit pointer. Only the host holding the state lease writes it.
public struct PluginCatalog: Sendable {
    private let store: PrivateJSONStore
    public let packages: PluginPackageStore
    public private(set) var records: [InstalledPlugin]
    public private(set) var enabledOverrides: [String: Bool]
    public private(set) var registrations: [PluginRegistration] = []
    public private(set) var diagnostics: [String: String] = [:]
    public var disabledPlugins: Set<String> { Set(records.filter { !$0.enabled }.map(\.id)) }
    public var activeRegistrations: [PluginRegistration] { registrations.filter { !disabledPlugins.contains($0.id) && $0.compatibilityReport().compatible } }
    public private(set) var revision = UUID()

    public init(directory: URL) throws {
        packages = try PluginPackageStore(directory: directory)
        store = try PrivateJSONStore(url: directory.appendingPathComponent("registry.json"), prettyPrinted: true)
        let snapshot = try store.load(Snapshot.self) ?? Snapshot(schemaVersion: 1, plugins: [], enabledOverrides: nil)
        guard snapshot.schemaVersion == 1, snapshot.plugins.count <= 64,
              Set(snapshot.plugins.map(\.id)).count == snapshot.plugins.count else {
            throw ConfigurationError.invalid("Invalid plugin registry version, count, or duplicate identity")
        }
        for record in snapshot.plugins {
            try PluginPersistence.validateID(record.id)
            guard record.archiveSHA256.count == 64, record.archiveSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw ConfigurationError.invalid("Invalid plugin archive digest")
            }
        }
        records = snapshot.plugins.sorted { $0.id < $1.id }
        enabledOverrides = snapshot.enabledOverrides ?? [:]
        guard Set(enabledOverrides.keys).isSubset(of: Set(records.map(\.id))),
              records.allSatisfy({ record in enabledOverrides[record.id].map { $0 == record.enabled } ?? true }) else {
            throw ConfigurationError.invalid("Invalid plugin enabled overrides")
        }
        for record in records {
            do { registrations.append(try packages.load(record)) }
            catch { diagnostics[record.id] = String(describing: error) }
        }
    }

    /// Publishes complete files before the registry pointer. Failed persistence never retires old work.
    @discardableResult
    public mutating func register(_ prepared: PreparedPluginPackage, replace: Bool) throws -> PluginRegistration {
        let id = prepared.manifest.id
        let previous = records.first { $0.id == id }
        guard previous == nil || replace else { throw RPCFailure(code: -32602, message: "Plugin is already installed; pass --replace") }
        guard previous != nil || records.count < 64 else { throw RPCFailure(code: -32602, message: "At most 64 plugins may be installed") }
        let record = InstalledPlugin(id: id, installationID: prepared.installationID, enabled: previous?.enabled ?? true, archiveSHA256: prepared.archiveSHA256)
        // Validate resolution before any filesystem publication.
        let registration = try prepared.manifest.registration(root: packages.root(record), validateFiles: false)
        try registration.requireCompatibility()
        let destination: URL
        do { destination = try packages.publish(prepared) }
        catch { throw RPCFailure(code: APIError.settingsWriteFailed, message: "Could not publish plugin files; previous installation retained: \(error)") }
        do {
            try commit(records.filter { $0.id != id } + [record])
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        registrations.removeAll { $0.id == id }
        registrations.append(registration)
        registrations.sort { $0.id < $1.id }
        diagnostics.removeValue(forKey: id)
        return registration
    }

    public mutating func remove(_ id: String) throws {
        guard records.contains(where: { $0.id == id }) else { throw ConfigurationError.invalid("Plugin is not installed: \(id)") }
        try commit(records.filter { $0.id != id }, overrides: enabledOverrides.filter { $0.key != id })
        registrations.removeAll { $0.id == id }
        diagnostics.removeValue(forKey: id)
        // Runtime owners retire files separately, after their cleanup receipts confirm release.
    }

    @discardableResult
    public mutating func setEnabled(_ id: String, enabled: Bool, persistOverride: Bool = false) throws -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw ConfigurationError.invalid("Plugin is not installed: \(id)") }
        let effective = persistOverride ? enabled : (enabledOverrides[id] ?? enabled)
        if effective, diagnostics[id] != nil { throw RPCFailure(code: -32602, message: "Repair the unavailable plugin before enabling it") }
        if effective, let registration = registrations.first(where: { $0.id == id }) { try registration.requireCompatibility() }
        guard records[index].enabled != effective || persistOverride && enabledOverrides[id] != enabled else { return false }
        var next = records
        next[index].enabled = effective
        var overrides = enabledOverrides
        if persistOverride { overrides[id] = enabled }
        try commit(next, overrides: overrides)
        return true
    }

    /// Parent synchronization keeps an explicit choice made inside this app.
    public func inheritedEnabled(for record: InstalledPlugin) -> Bool {
        enabledOverrides[record.id] ?? record.enabled
    }

    public func list() -> JSONValue {
        .array(records.map { record in
            let registration = registrations.first { $0.id == record.id }
            var info = registration.flatMap { try? JSONValue.encoding($0).object } ?? [:]
            info["compatibilityStatus"] = registration.flatMap { try? JSONValue.encoding($0.compatibilityReport()) } ?? .null
            info.merge([
                "id": .string(record.id), "title": .string(registration?.title ?? record.id),
                "enabled": .bool(record.enabled), "installationID": .string(record.installationID.uuidString.lowercased()),
                "enabledOverride": enabledOverrides[record.id].map(JSONValue.bool) ?? .null,
                "available": .bool(registration != nil), "diagnostic": diagnostics[record.id].map(JSONValue.string) ?? .null,
                "packageRoot": .string(packages.root(record).path)
            ]) { _, value in value }
            return .object(info)
        })
    }

    private mutating func commit(_ records: [InstalledPlugin], overrides: [String: Bool]? = nil) throws {
        let sorted = records.sorted { $0.id < $1.id }
        let nextOverrides = overrides ?? enabledOverrides
        do { try store.save(Snapshot(schemaVersion: 1, plugins: sorted, enabledOverrides: nextOverrides.isEmpty ? nil : nextOverrides)) }
        catch { throw RPCFailure(code: APIError.settingsWriteFailed, message: "Could not save plugin registry; previous state retained: \(error)") }
        self.records = sorted
        enabledOverrides = nextOverrides
        revision = UUID()
    }
    private struct Snapshot: Codable {
        let schemaVersion: Int
        let plugins: [InstalledPlugin]
        let enabledOverrides: [String: Bool]?
    }
}
