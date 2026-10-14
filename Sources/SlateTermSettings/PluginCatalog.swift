import Foundation
import SlateTermCore

public struct PluginCatalog: Sendable {
    private let store: PrivateJSONStore
    public private(set) var registrations: [PluginRegistration]

    public init(directory: URL) throws {
        store = try PrivateJSONStore(url: directory.appendingPathComponent("plugins.json"))
        if let snapshot = try store.load(Snapshot.self) {
            guard snapshot.schemaVersion == 1, snapshot.registrations.count <= 64,
                  Set(snapshot.registrations.map(\.id)).count == snapshot.registrations.count else {
                throw ConfigurationError.invalid("Invalid plugin catalog version, count, or duplicate identity")
            }
            registrations = snapshot.registrations
        } else { registrations = [] }
    }

    public mutating func register(_ registration: PluginRegistration, replace: Bool) throws {
        let exists = registrations.contains { $0.id == registration.id }
        guard !exists || replace else { throw ConfigurationError.invalid("Plugin is already registered; pass --replace to replace it") }
        var next = registrations.filter { $0.id != registration.id }
        next.append(registration)
        guard next.count <= 64 else { throw ConfigurationError.invalid("At most 64 plugin types may be registered") }
        next.sort { $0.id < $1.id }
        try store.save(Snapshot(schemaVersion: 1, registrations: next))
        registrations = next
    }

    public mutating func remove(_ id: String) throws {
        guard registrations.contains(where: { $0.id == id }) else { throw ConfigurationError.invalid("Plugin is not registered: \(id)") }
        let next = registrations.filter { $0.id != id }
        try store.save(Snapshot(schemaVersion: 1, registrations: next))
        registrations = next
    }

    private struct Snapshot: Codable {
        let schemaVersion: Int
        let registrations: [PluginRegistration]
    }
}
