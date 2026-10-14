import Foundation
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    func configurationRevision() throws -> (source: String, revision: String) {
        let source = try configurationSource()
        if configurationRevisionSource != source {
            configurationRevisionSource = source
            configurationSourceRevision = UUID().uuidString
        }
        return (source, configurationSourceRevision)
    }

    func configurationRevisionInfo() -> [String: JSONValue] {
        do {
            let read = try configurationRevision()
            let candidate = try? AppConfiguration.parse(read.source)
            return ["sourceRevision": .string(read.revision), "appliedRevision": .string(appliedConfigurationRevision),
                    "sourceValid": .bool(candidate != nil),
                    "appliedMatchesSource": .bool(candidate?.changedKeys(from: settings.current).isEmpty == true)]
        } catch {
            return ["sourceRevision": .null, "appliedRevision": .string(appliedConfigurationRevision),
                    "sourceValid": .bool(false), "sourceError": .string(String(describing: error)), "appliedMatchesSource": .bool(false)]
        }
    }

    func patchConfiguration(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let expected = params["expectedSourceRevision"]?.string, let values = params["values"]?.object else {
            throw RPCFailure(code: -32602, message: "values object and expectedSourceRevision are required")
        }
        return try writeConfiguration(values, expected: expected)
    }

    private func writeConfiguration(_ values: [String: JSONValue], expected: String? = nil) throws -> JSONValue {
        let read = try configurationRevision()
        if let expected, expected != read.revision { throw RPCFailure(code: APIError.conflict, message: "Configuration source changed; read config.get before retrying") }
        let updated = try ConfigurationPatch.updating(source: read.source, values: values)
        if updated != read.source {
            do { try saveSettings(source: read.source, changes: ConfigurationPatch.literals(values), refreshEditor: false) }
            catch {
                var state = configurationRevisionInfo()
                state["outcome"] = .string("unknown")
                state["persisted"] = (try? configurationSource()).map { .bool($0 == updated) } ?? .null
                throw RPCFailure(code: APIError.settingsWriteFailed, message: "Settings write/apply failed; inspect current state before retrying: \(error)", data: .object(state))
            }
        }
        var result = configurationRevisionInfo()
        result["persisted"] = .bool(true)
        result["operationId"] = .string(UUID().uuidString)
        result["restartRequired"] = try settings.status().object?["restartRequired"]
        return .object(result)
    }

    func runSettingsCommand(_ id: String, params: [String: JSONValue]) throws -> JSONValue? {
        switch id {
        case "appearance.set", "appearance.light", "appearance.dark", "appearance.auto":
            let mode = id == "appearance.set" ? params["mode"]?.string : String(id.dropFirst("appearance.".count))
            guard let mode, ["auto", "light", "dark"].contains(mode) else { throw RPCFailure(code: -32602, message: "mode must be auto, light or dark") }
            return try writeConfiguration(["appearance.theme": .string(mode)], expected: params["expectedSourceRevision"]?.string)
        case "terminal.palette.set":
            guard let slot = params["slot"]?.string, ["light", "dark"].contains(slot), let name = params["name"]?.string else {
                throw RPCFailure(code: -32602, message: "slot (light|dark) and name are required")
            }
            return try writeConfiguration(["terminal.\(slot)_theme": .string(name)], expected: params["expectedSourceRevision"]?.string)
        case "terminal.font.set", "terminal.font.increase", "terminal.font.decrease", "terminal.font.reset":
            let size: JSONValue
            switch id {
            case "terminal.font.set":
                guard let value = params["size"] else { throw RPCFailure(code: -32602, message: "size is required") }
                size = value
            case "terminal.font.increase": size = .number(min(256, settings.current.terminal.fontSize + 1))
            case "terminal.font.decrease": size = .number(max(1, settings.current.terminal.fontSize - 1))
            default: size = .number(AppConfiguration.defaults.terminal.fontSize)
            }
            return try writeConfiguration(["terminal.font_size": size], expected: params["expectedSourceRevision"]?.string)
        case "warnings.close.reset":
            try settings.setSuppressCloseWarning(false)
            updateStatusMenu()
            return .object(["suppressed": .bool(false)])
        case "warnings.type.reset":
            try settings.setSuppressTypeWarning(false)
            updateStatusMenu()
            return .object(["suppressed": .bool(false)])
        default: return nil
        }
    }

    func listPalettes() throws -> JSONValue {
        let custom = try PaletteLibrary(directory: settings.paletteDirectory).entries()
        guard custom.count <= 1000 else { throw RPCFailure(code: APIError.unavailable, message: "Palette listing exceeds 1000 entries") }
        let bundled = AppConfiguration.BundledTerminalTheme.allCases.map { theme -> JSONValue in
            .object(["name": .string(theme.rawValue), "source": .string("bundled"), "valid": .bool(true)])
        }
        return .array(bundled + custom.map { entry in
            .object(["name": .string(entry.name), "source": .string("custom"),
                     "valid": .bool((try? TerminalPalette.load(from: entry.url, followingSymbolicLinks: false)) != nil)])
        })
    }

    func importPalette(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let path = params["path"]?.string, path.hasPrefix("/") else { throw RPCFailure(code: -32602, message: "An absolute local path is required") }
        let entry = try PaletteLibrary(directory: settings.paletteDirectory).importPalette(from: URL(fileURLWithPath: path))
        refreshSettings()
        return .object(["name": .string(entry.name), "activated": .bool(false)])
    }
}
