import Foundation
import SlateTermCore

public struct PluginCatalog: Sendable {
    private let store: PrivateJSONStore
    public private(set) var registrations: [PluginRegistration]
    public private(set) var disabledPlugins: Set<String>
    public var activeRegistrations: [PluginRegistration] { registrations.filter { !disabledPlugins.contains($0.id) } }
    public private(set) var enabledServices: Set<String>
    public static let maximumEnabledServices = 16

    public init(directory: URL) throws {
        store = try PrivateJSONStore(url: directory.appendingPathComponent("plugins.json"))
        if let snapshot = try store.load(Snapshot.self) {
            guard snapshot.schemaVersion == 3, snapshot.registrations.count <= 64,
                  Set(snapshot.registrations.map(\.id)).count == snapshot.registrations.count else {
                throw ConfigurationError.invalid("Invalid plugin catalog version, count, or duplicate identity")
            }
            registrations = snapshot.registrations
            guard Set(snapshot.disabledPlugins).count == snapshot.disabledPlugins.count,
                  Set(snapshot.disabledPlugins).isSubset(of: Set(registrations.map(\.id))) else {
                throw ConfigurationError.invalid("Invalid disabled plugins in plugin catalog")
            }
            let disabled = Set(snapshot.disabledPlugins)
            disabledPlugins = disabled
            let enabled = snapshot.enabledServices
            guard enabled.count <= Self.maximumEnabledServices, Set(enabled).count == enabled.count,
                  Set(enabled).isSubset(of: Set(registrations.filter { $0.service != nil && !disabled.contains($0.id) }.map(\.id))) else {
                throw ConfigurationError.invalid("Invalid enabled background services in plugin catalog")
            }
            enabledServices = Set(enabled)
        } else { registrations = []; enabledServices = []; disabledPlugins = [] }
    }

    public mutating func register(_ registration: PluginRegistration, replace: Bool) throws {
        let exists = registrations.contains { $0.id == registration.id }
        guard !exists || replace else { throw ConfigurationError.invalid("Plugin is already registered; pass --replace to replace it") }
        var next = registrations.filter { $0.id != registration.id }
        next.append(registration)
        guard next.count <= 64 else { throw ConfigurationError.invalid("At most 64 plugin types may be registered") }
        next.sort { $0.id < $1.id }
        // Even an identical replacement is a new registration, not renewed consent.
        try commit(next, enabled: enabledServices.subtracting([registration.id]), disabled: disabledPlugins)
    }

    public mutating func remove(_ id: String) throws {
        guard registrations.contains(where: { $0.id == id }) else { throw ConfigurationError.invalid("Plugin is not registered: \(id)") }
        let next = registrations.filter { $0.id != id }
        try commit(next, enabled: enabledServices.subtracting([id]), disabled: disabledPlugins.subtracting([id]))
    }

    @discardableResult
    public mutating func setEnabled(_ id: String, enabled: Bool) throws -> Bool {
        guard registrations.contains(where: { $0.id == id }) else {
            throw ConfigurationError.invalid("Plugin is not registered: \(id)")
        }
        guard disabledPlugins.contains(id) == enabled else { return false }
        var disabled = disabledPlugins
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        try commit(registrations, enabled: enabledServices.subtracting([id]), disabled: disabled)
        return true
    }

    @discardableResult
    public mutating func setServiceEnabled(_ id: String, enabled: Bool) throws -> Bool {
        guard activeRegistrations.contains(where: { $0.id == id && $0.service != nil }) else {
            throw ConfigurationError.invalid("A registered background service is required")
        }
        guard enabledServices.contains(id) != enabled else { return false }
        var next = enabledServices
        if enabled { next.insert(id) } else { next.remove(id) }
        guard next.count <= Self.maximumEnabledServices else {
            throw ConfigurationError.invalid("At most \(Self.maximumEnabledServices) background services may be enabled")
        }
        try commit(registrations, enabled: next, disabled: disabledPlugins)
        return true
    }

    private mutating func commit(_ registrations: [PluginRegistration], enabled: Set<String>, disabled: Set<String>) throws {
        try store.save(Snapshot(schemaVersion: 3, registrations: registrations, enabledServices: enabled.sorted(), disabledPlugins: disabled.sorted()))
        self.registrations = registrations
        enabledServices = enabled
        disabledPlugins = disabled
    }

    private struct Snapshot: Codable {
        let schemaVersion: Int
        let registrations: [PluginRegistration]
        let enabledServices: [String]
        let disabledPlugins: [String]
    }
}
