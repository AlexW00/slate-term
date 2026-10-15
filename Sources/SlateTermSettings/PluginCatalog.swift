import Foundation
import SlateTermCore

public struct PluginCatalog: Sendable {
    private let store: PrivateJSONStore
    public private(set) var registrations: [PluginRegistration]
    public private(set) var enabledServices: Set<String>
    public static let maximumEnabledServices = 16

    public init(directory: URL) throws {
        store = try PrivateJSONStore(url: directory.appendingPathComponent("plugins.json"))
        if let snapshot = try store.load(Snapshot.self) {
            guard [1, 2].contains(snapshot.schemaVersion), snapshot.registrations.count <= 64,
                  Set(snapshot.registrations.map(\.id)).count == snapshot.registrations.count else {
                throw ConfigurationError.invalid("Invalid plugin catalog version, count, or duplicate identity")
            }
            registrations = snapshot.registrations
            if snapshot.schemaVersion == 1 {
                enabledServices = [] // Old catalogs never confer startup permission.
            } else {
                guard let enabled = snapshot.enabledServices, enabled.count <= Self.maximumEnabledServices,
                      Set(enabled).count == enabled.count,
                      Set(enabled).isSubset(of: Set(registrations.filter { $0.service != nil }.map(\.id))) else {
                    throw ConfigurationError.invalid("Invalid enabled background services in plugin catalog")
                }
                enabledServices = Set(enabled)
            }
        } else { registrations = []; enabledServices = [] }
    }

    public mutating func register(_ registration: PluginRegistration, replace: Bool) throws {
        let exists = registrations.contains { $0.id == registration.id }
        guard !exists || replace else { throw ConfigurationError.invalid("Plugin is already registered; pass --replace to replace it") }
        var next = registrations.filter { $0.id != registration.id }
        next.append(registration)
        guard next.count <= 64 else { throw ConfigurationError.invalid("At most 64 plugin types may be registered") }
        next.sort { $0.id < $1.id }
        // Even an identical replacement is a new registration, not renewed consent.
        try commit(next, enabled: enabledServices.subtracting([registration.id]))
    }

    public mutating func remove(_ id: String) throws {
        guard registrations.contains(where: { $0.id == id }) else { throw ConfigurationError.invalid("Plugin is not registered: \(id)") }
        let next = registrations.filter { $0.id != id }
        try commit(next, enabled: enabledServices.subtracting([id]))
    }

    @discardableResult
    public mutating func setServiceEnabled(_ id: String, enabled: Bool) throws -> Bool {
        guard registrations.contains(where: { $0.id == id && $0.service != nil }) else {
            throw ConfigurationError.invalid("A registered background service is required")
        }
        guard enabledServices.contains(id) != enabled else { return false }
        var next = enabledServices
        if enabled { next.insert(id) } else { next.remove(id) }
        guard next.count <= Self.maximumEnabledServices else {
            throw ConfigurationError.invalid("At most \(Self.maximumEnabledServices) background services may be enabled")
        }
        try commit(registrations, enabled: next)
        return true
    }

    private mutating func commit(_ registrations: [PluginRegistration], enabled: Set<String>) throws {
        try store.save(Snapshot(schemaVersion: 2, registrations: registrations, enabledServices: enabled.sorted()))
        self.registrations = registrations
        enabledServices = enabled
    }

    private struct Snapshot: Codable {
        let schemaVersion: Int
        let registrations: [PluginRegistration]
        let enabledServices: [String]?
    }
}
