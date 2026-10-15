import AppKit
import Foundation
import GhosttyKit
import SlateTermCore
import SlateTermSettings

@main @MainActor
struct EventEfficiencyChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-event-efficiency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = NSApplication.shared // Fixtures never create windows or activate the app.
        try checkStorage(root)
        try checkConfiguration(root)
        try await checkTerminalMetadata(root)
        print("PASS all native event efficiency checks (no windows)")
    }

    static func checkStorage(_ root: URL) throws {
        let registration = try PluginRegistration.parse(Data(#"{"id":"notes","title":"Notes","source":{"kind":"directory","path":"/tmp","entry":"index.html"}}"#.utf8))
        let instance = try PluginInstance(registration: registration, scopeKey: "p1", tab: TabID(1), directory: root,
                                          connection: .init(socketPath: "/unused", appInstanceID: "test", cliPath: "/unused"))
        defer { instance.close() }
        var events = 0
        instance.onEvent = { name, _, _ in if name == "storageChanged" { events += 1 } }
        let file = root.appendingPathComponent("notes/p1.json")
        try instance.storageSet("missing", value: nil)
        try require(!FileManager.default.fileExists(atPath: file.path) && events == 0, "Absent deletion created storage or notified")
        let value = JSONValue.object(["draft": .string("keep"), "nullable": .null])
        try instance.storageSet("value", value: value)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
        try instance.storageSet("value", value: value)
        try require(events == 1 && instance.storageGet("value") == value, "Equal write notified or changed values")
        try require(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber == inode, "Equal write replaced the file")
        try instance.storageSet("null", value: .null)
        try instance.storageSet("null", value: .null)
        try require(events == 2, "Null storage was confused with deletion")
        try instance.storageSet("value", value: nil)
        try instance.storageSet("value", value: nil)
        try require(events == 3 && instance.storageGet(nil).object?["value"] == nil, "Delete notification was duplicated")
        // A failed persistence must retain both authoritative state and event count.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do {
            try instance.storageSet("null", value: .string("must fail"))
            throw Failure("Storage write unexpectedly succeeded over a directory")
        } catch is Failure { throw Failure("Failed-persistence fixture did not fail") }
        catch { }
        try require(events == 3 && instance.storageGet("null") == .null, "Failed persistence mutated or notified")
        print("PASS storage: equal writes/absent deletes do no I/O or notification; null, changed writes and failed persistence preserved")
    }

    static func checkConfiguration(_ root: URL) throws {
        let settings = try ApplicationSettings(environment: ["SLATE_TERM_STATE_DIR": root.appendingPathComponent("settings").path], integration: true)
        let clipboard = NSPasteboard(name: .init("slate-settings-efficiency-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let runtime = try GhosttyRuntime(configurationURL: settings.engineURL, clipboard: clipboard)
        defer { runtime.close() }
        let dark = try settings.terminalColors(dark: true)
        let light = try settings.terminalColors(dark: false)
        try require(dark != light, "Bundled slot fixture must use distinct palettes")
        let bundled = settings.bundledPaletteDirectory.appendingPathComponent("Builtin Dark")
        try require(Bundle.main.resourceURL!.lastPathComponent.hasPrefix("slate-event-efficiency."), "Bundled cache test must own its resource directory")
        let bundledSource = try String(contentsOf: bundled, encoding: .utf8)
        do {
            defer { try? bundledSource.write(to: bundled, atomically: true, encoding: .utf8) }
            try "invalid".write(to: bundled, atomically: true, encoding: .utf8)
            try require(try settings.terminalColors(dark: true) == dark && settings.terminalColors(dark: false) == light, "Bundled colors were reread or slots confused")
        }
        let original = try String(contentsOf: settings.engineURL, encoding: .utf8)
        let inode = try FileManager.default.attributesOfItem(atPath: settings.engineURL.path)[.systemFileNumber] as? NSNumber
        var reloads = 0
        _ = try settings.reload { url, engineChanged in if engineChanged { try runtime.reload(from: url); reloads += 1 } }
        try require(reloads == 0, "No-op configuration reloaded the engine")
        try require(try FileManager.default.attributesOfItem(atPath: settings.engineURL.path)[.systemFileNumber] as? NSNumber == inode, "No-op configuration rewrote engine source")
        var configuration = settings.current
        configuration.plugins["notes"] = ["count": .integer(1)]
        _ = try settings.reload(prepared: settings.prepare(configuration)) { url, changed in if changed { try runtime.reload(from: url); reloads += 1 } }
        try require(reloads == 0 && settings.current.plugins["notes"] != nil, "Plugin-only settings needlessly reloaded engine or failed to apply")
        let fontSize = configuration.terminal.fontSize + 1
        configuration = try AppConfiguration.parse("[terminal]\nfont_size = \(fontSize)\n[plugins.notes]\ncount = 1\n")
        do {
            _ = try settings.reload(prepared: settings.prepare(configuration)) { _, _ in throw Failure("Injected apply failure") }
            throw Failure("Rejected engine apply unexpectedly succeeded")
        } catch is RPCFailure { }
        try require(settings.current.terminal.fontSize != configuration.terminal.fontSize, "Rejected settings became authoritative")
        try require(try String(contentsOf: settings.engineURL, encoding: .utf8) == original, "Rejected engine source was not restored")
        _ = try settings.reload(prepared: settings.prepare(configuration)) { url, changed in if changed { try runtime.reload(from: url); reloads += 1 } }
        try require(reloads == 1 && settings.error == nil, "Changed engine configuration did not apply or recover")

        // Custom file edits remain visible to explicit reloads even with identical TOML.
        try FileManager.default.createDirectory(at: settings.paletteDirectory, withIntermediateDirectories: true)
        let palette = settings.paletteDirectory.appendingPathComponent("Custom.conf")
        try "background = #102030\nforeground = #ffffff\n".write(to: palette, atomically: true, encoding: .utf8)
        configuration = try AppConfiguration.parse("[terminal]\nfont_size = \(fontSize)\ndark_theme = \"Custom\"\n[plugins.notes]\ncount = 1\n")
        _ = try settings.reload(prepared: settings.prepare(configuration)) { url, changed in if changed { try runtime.reload(from: url); reloads += 1 } }
        let before = try settings.terminalColors(dark: true)
        try "background = #304050\nforeground = #ffffff\n".write(to: palette, atomically: true, encoding: .utf8)
        try require(try settings.terminalColors(dark: true) == before, "Unapplied custom palette escaped its snapshot")
        _ = try settings.reload(prepared: settings.prepare(configuration)) { url, changed in if changed { try runtime.reload(from: url); reloads += 1 } }
        try require(reloads == 3 && settings.terminalColors(dark: true) != before, "Explicit palette reload was suppressed")
        print("PASS configuration: no-op/plugin-only engine work suppressed; real runtime reload, rollback, bundled cache and custom palette reload retained")
    }

    static func checkTerminalMetadata(_ root: URL) async throws {
        _ = NSApplication.shared // No window, activation, or user's clipboard.
        let file = root.appendingPathComponent("engine.conf")
        try "command = /bin/cat\nshell-integration = none\nclipboard-read = deny\nwait-after-command = false\n".write(to: file, atomically: true, encoding: .utf8)
        let clipboard = NSPasteboard(name: .init("slate-event-efficiency-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let runtime = try GhosttyRuntime(configurationURL: file, clipboard: clipboard)
        defer { runtime.close() }
        let terminal = try TerminalView(runtime: runtime)
        defer { terminal.close() }
        var titles = 0, directories = 0, completions = 0
        terminal.onContextChange = { snapshot, change in
            switch change {
            case .title: if snapshot.title == "efficiency-check" { titles += 1 }
            case .workingDirectory: if snapshot.workingDirectory == "/efficiency-check" { directories += 1 }
            case .commandFinished: completions += 1
            }
        }
        "efficiency-check".withCString { pointer in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SET_TITLE
            action.action.set_title.title = pointer
            _ = terminal.handleAction(action); _ = terminal.handleAction(action)
        }
        "/efficiency-check".withCString { pointer in
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_PWD
            action.action.pwd.pwd = pointer
            _ = terminal.handleAction(action); _ = terminal.handleAction(action)
        }
        var completed = ghostty_action_s()
        completed.tag = GHOSTTY_ACTION_COMMAND_FINISHED
        completed.action.command_finished.exit_code = 0
        completed.action.command_finished.duration = 42
        _ = terminal.handleAction(completed); _ = terminal.handleAction(completed)
        var secure = ghostty_action_s()
        secure.tag = GHOSTTY_ACTION_SECURE_INPUT
        secure.action.secure_input = GHOSTTY_SECURE_INPUT_OFF
        _ = terminal.handleAction(secure); _ = terminal.handleAction(secure)
        let deadline = ContinuousClock.now + .seconds(5)
        while completions < 2 {
            guard ContinuousClock.now < deadline else { throw Failure("Metadata callback deadline expired") }
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(titles == 1 && directories == 1 && completions == 2, "Metadata no-ops or completion facts were mishandled")
        try require(terminal.setColorScheme(GHOSTTY_COLOR_SCHEME_DARK), "First surface scheme was not applied")
        try require(!terminal.setColorScheme(GHOSTTY_COLOR_SCHEME_DARK), "Equal surface scheme was applied again")
        try require(terminal.setColorScheme(GHOSTTY_COLOR_SCHEME_LIGHT), "Changed surface scheme was suppressed")
        print("PASS terminal: equal title/PWD suppressed, identical completions preserved, secure input stays local, color-scheme equality")
    }

    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }
}
