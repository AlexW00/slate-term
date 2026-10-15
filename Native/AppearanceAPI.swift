import AppKit
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    /// Builds the effective appearance from the applied settings and palettes, never from files on disk.
    func appearanceSnapshot() throws -> AppearanceSnapshot {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let colors = try settings.appliedPalettes.colors(dark: dark, bundledDirectory: settings.bundledPaletteDirectory)
        return AppearanceSnapshot(configuration: settings.current, systemDark: dark, darkSlot: dark, colors: colors)
    }

    func appearanceInfo(_ params: [String: JSONValue]) throws -> JSONValue {
        guard withoutAPIGuards(params).isEmpty else { throw RPCFailure(code: -32602, message: "appearance.get takes no payload parameters") }
        // Publish any pending change first, so a read right after config.patch matches later events.
        refreshAppearance()
        do { return try appearanceSnapshot().json }
        catch { throw RPCFailure(code: APIError.unavailable, message: "Could not read the terminal palette: \(error)") }
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
    func refreshAppearance() {
        appearanceRefreshScheduled = false
        let snapshot: AppearanceSnapshot
        do { snapshot = try appearanceSnapshot() }
        catch { NSLog("Could not read the terminal palette: %@", String(describing: error)); return }
        guard snapshot.revision != publishedAppearanceRevision else { return }
        let initial = publishedAppearanceRevision == nil
        publishedAppearanceRevision = snapshot.revision
        for pane in leaves.values.compactMap({ $0 as? PluginPane }) { pane.apply(appearance: snapshot) }
        // Nobody can have read an earlier appearance at launch, so only later changes are events.
        if !initial { events.publishHost("host.appearance.changed", payload: snapshot.eventPayload) }
    }

    static let appearanceDescriptor: JSONValue = .object([
        "version": .integer(1), "method": .string("appearance.get"), "topic": .string("host.appearance.changed"),
        "revision": .string("opaqueContentHash"), "pageInjection": .string("registeredPluginMainFrame"),
        "variables": .array((["--st-bg", "--st-fg", "--st-cursor", "--st-selection-bg", "--st-selection-fg"]
            + (0..<16).map { "--st-ansi-\($0)" } + ["--st-font-mono", "--st-font-mono-size"]).map(JSONValue.string)),
    ])
}
