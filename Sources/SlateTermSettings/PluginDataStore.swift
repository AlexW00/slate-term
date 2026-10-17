import Foundation
import SlateTermCore

/// The host serializes this cache under its state-directory lease. No external live writers.
/// Persistence and publication are separate so EventHub can atomically publish the cache/journal
/// only after the synchronous file replacement succeeds.
public final class PluginDataStore {
    public let url: URL
    private let file: PrivateJSONStore
    public private(set) var document: PluginDataDocument

    public init(directory: URL, id: String) throws {
        try PluginPersistence.validateID(id)
        url = directory.appendingPathComponent(id + ".json")
        file = try PrivateJSONStore(url: url, maximumBytes: PluginPersistence.dataBytes + 4096)
        document = try file.load(PluginDataDocument.self) ?? PluginDataDocument()
    }
    public func persist(_ candidate: PluginDataDocument) throws { try file.save(candidate) }
    /// Only call after persist succeeds, without a suspension/reentrant callback between them.
    public func accept(_ candidate: PluginDataDocument) { document = candidate }
}
