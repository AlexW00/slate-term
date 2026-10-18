import AppKit
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    /// Builds the effective appearance from the applied settings and palettes, never from files on disk.
    func appearanceSnapshot() throws -> AppearanceSnapshot {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let colors = try settings.terminalColors(dark: dark)
        return AppearanceSnapshot(configuration: settings.current, systemDark: dark, darkSlot: dark, colors: colors)
    }

    func appearanceInfo(_ params: [String: JSONValue]) throws -> JSONValue {
        guard withoutAPIGuards(params).isEmpty else { throw RPCFailure(code: -32602, message: "appearance.get takes no payload parameters") }
        // Publish any pending change first, so a read right after config.patch matches later events.
        guard let snapshot = refreshAppearance() else {
            throw RPCFailure(code: APIError.unavailable, message: "Could not read the terminal palette")
        }
        return snapshot.json
    }

    /// Coalesces a burst, such as a settings apply that also flips the appearance, into one refresh.
    func scheduleAppearanceRefresh() {
        guard !appearanceRefreshScheduled else { return }
        appearanceRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refreshAppearance() }
        }
    }

    /// Updates plugin pages and publishes host.appearance.changed when the snapshot differs from the last one.
    @discardableResult
    func refreshAppearance() -> AppearanceSnapshot? {
        appearanceRefreshScheduled = false
        let snapshot: AppearanceSnapshot
        do { snapshot = try appearanceSnapshot() }
        catch { NSLog("Could not read the terminal palette: %@", String(describing: error)); return nil }
        guard snapshot.revision != publishedAppearanceRevision else { return snapshot }
        let initial = publishedAppearanceRevision == nil
        publishedAppearanceRevision = snapshot.revision
        for pane in leaves.values.compactMap({ $0 as? PluginPane }) { pane.apply(appearance: snapshot) }
        // Nobody can have read an earlier appearance at launch, so only later changes are events.
        if !initial { events.publishHost("host.appearance.changed", payload: snapshot.eventPayload) }
        return snapshot
    }

    static let appearanceDescriptor: JSONValue = AutomationCapabilities.appearance
}
