import Foundation
import SlateTermCore
import SlateTermSettings

/// Reads parent files without constructing its catalog or acquiring a parent writer lease.
@MainActor
enum LayoutAppPluginSync {
    nonisolated static func records(parentBase: URL) throws -> [InstalledPlugin] {
        try LayoutAppCreationPreflight.parentRecords(parentBase: parentBase, allowEmpty: true)
    }
    nonisolated static func prepare(_ record: InstalledPlugin, store: PluginPackageStore, parentBase: URL) throws -> PreparedPluginPackage {
        let archive = parentBase.appendingPathComponent("plugins/packages/\(record.id)/\(record.installationID.uuidString.lowercased())/package.zip")
        let prepared = try store.prepare(archive)
        try Task.checkCancellation()
        guard prepared.manifest.id == record.id, prepared.archiveSHA256 == record.archiveSHA256 else {
            throw RPCFailure(code: -32602, message: "Parent package changed during synchronization")
        }
        return prepared
    }
    nonisolated static func discard(_ packages: [PreparedPluginPackage]) async {
        guard !packages.isEmpty else { return }
        await BlockingIOExecutor.finish {
            for package in packages { try? FileManager.default.removeItem(at: package.directory) }
        }
    }
    static func initial(catalog: inout PluginCatalog, parentBase: URL, preserving restoredPlugins: Set<String>?) throws {
        // An unreadable snapshot cannot safely identify generations that must remain installed.
        guard let restoredPlugins else { return }
        let desired: [InstalledPlugin]
        do { desired = try records(parentBase: parentBase) }
        catch { NSLog("Parent plugins could not be read; retaining local copies: %@", String(describing: error)); return }
        for record in desired {
            // Restored panes retain their installed generation and enabled state until they close.
            if restoredPlugins.contains(record.id), catalog.records.contains(where: { $0.id == record.id }) { continue }
            do {
                let previous = catalog.records.first { $0.id == record.id }
                if previous?.archiveSHA256 != record.archiveSHA256 {
                    let previousRegistration = catalog.registrations.first { $0.id == record.id }
                    let prepared = try prepare(record, store: catalog.packages, parentBase: parentBase)
                    _ = try catalog.register(prepared, replace: previous != nil)
                    if let previous { retireAtStartup(previous, registration: previousRegistration, store: catalog.packages) }
                }
                _ = try catalog.setEnabled(record.id, enabled: record.enabled)
            } catch { NSLog("Parent plugin %@ could not be synchronized: %@", record.id, String(describing: error)) }
        }
        for record in catalog.records where !restoredPlugins.contains(record.id) && !desired.contains(where: { $0.id == record.id }) {
            let registration = catalog.registrations.first { $0.id == record.id }
            try catalog.remove(record.id)
            retireAtStartup(record, registration: registration, store: catalog.packages)
        }
    }
    private static func retireAtStartup(_ record: InstalledPlugin, registration: PluginRegistration?, store: PluginPackageStore) {
        let root = store.root(record).path
        // The state lease excludes the old host, but does not prove its plugin processes finished.
        guard let registration, registration.process == nil, registration.service == nil, registration.commands.isEmpty else {
            PackageFiles.retain(root: root, reason: "Previous-session package retained: process cleanup cannot be confirmed")
            return
        }
        // File-panel readers belonged to the stopped host. Existing orphan generations are never passed here.
        do { try store.remove(record) }
        catch { PackageFiles.retain(root: root, reason: "Startup package cleanup failed: \(error)") }
    }
    static func readRecipe(directory: URL, id: UUID) throws -> SavedLayoutDefinition {
        // SavedLayoutStore creates directories. Startup only reads the parent's library.
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let files = urls.filter { $0.pathExtension == "json" }
        guard files.count <= 256 else { throw RPCFailure(code: -32602, message: "Too many source layout files") }
        var found: [SavedLayoutDefinition] = []
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? Data(contentsOf: file), data.count <= 262_144,
                  let definition = try? SavedLayoutDefinition.parse(data), definition.id == id else { continue }
            found.append(definition)
        }
        guard found.count == 1 else { throw RPCFailure(code: -32602, message: "The source layout is missing, invalid, or ambiguous. Restore it in Slate Terminal before opening a fresh workspace.") }
        return found[0]
    }
}
