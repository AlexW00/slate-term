import Foundation
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    func configurationRevision() throws -> (source: String, revision: String) {
        let source = try configurationSource()
        try observeConfigurationSource(source)
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

    func patchConfiguration(_ params: [String: JSONValue], operation: WorkspaceOperationContext) throws -> JSONValue {
        guard let expected = params["expectedSourceRevision"]?.string, let values = params["values"]?.object else {
            throw RPCFailure(code: -32602, message: "values object and expectedSourceRevision are required")
        }
        return try writeConfiguration(values, expected: expected, operation: operation)
    }

    private func writeConfiguration(_ values: [String: JSONValue], expected: String? = nil, operation: WorkspaceOperationContext) throws -> JSONValue {
        let read = try configurationRevision()
        if let expected, expected != read.revision { throw RPCFailure(code: APIError.conflict, message: "Configuration source changed; read config.get before retrying") }
        let updated = try ConfigurationPatch.updating(source: read.source, values: values)
        return try commitConfigurationSource(source: read.source, updated: updated, operation: operation)
    }

    func commitConfigurationSource(source: String, updated: String, operation: WorkspaceOperationContext) throws -> JSONValue {
        let candidate = try AppConfiguration.parse(updated)
        if updated != source || !candidate.changedKeys(from: settings.current).isEmpty || settings.error != nil {
            do { try saveConfigurationSource(source: source, updated: updated, refreshEditor: false, operation: operation) }
            catch {
                var state = configurationRevisionInfo()
                state["operationId"] = .string(operation.lineage.operationID.uuidString)
                state["outcome"] = .string("unknown")
                state["persisted"] = (try? configurationSource()).map { .bool($0 == updated) } ?? .null
                throw RPCFailure(code: APIError.settingsWriteFailed, message: "Settings write/apply failed; inspect current state before retrying: \(error)", data: .object(state))
            }
        }
        var result = configurationRevisionInfo()
        result["persisted"] = .bool(true)
        result["operationId"] = .string(operation.lineage.operationID.uuidString)
        result["restartRequired"] = try settings.status().object?["restartRequired"]
        return .object(result)
    }

    func pluginSettingsInfo(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let id = params["id"]?.string else { throw RPCFailure(code: -32602, message: "Plugin id is required") }
        try PluginSettingsPatch.validateNamespace(id)
        let read = try configurationRevision()
        let candidate = try? AppConfiguration.parse(read.source)
        return .object(["id": .string(id), "values": .object(candidate.map { $0.plugins[id] ?? [:] } ?? settings.current.plugins[id] ?? [:]),
                        "appliedValues": .object(settings.current.plugins[id] ?? [:]), "sourceValid": .bool(candidate != nil),
                        "writeRevision": .string(read.revision)])
    }

    func pluginSettingsFailure(_ error: Error) -> RPCFailure {
        let failure = error as? RPCFailure
        let code = failure?.code ?? -32602
        let message: String
        switch code {
        case APIError.conflict: message = "Settings source or target changed; read the namespace again"
        case APIError.settingsWriteFailed: message = "Plugin settings write/apply failed; inspect current state before retrying"
        default: message = "Plugin settings request rejected; check the patch and source configuration"
        }
        // A TOML diagnostic or underlying apply failure may quote an unrelated
        // namespace's source. Namespace API errors retain typed state for every
        // client, never those diagnostics.
        let safeKeys: Set<String> = ["operationId", "sourceRevision", "appliedRevision", "sourceValid", "appliedMatchesSource", "outcome", "persisted"]
        let data = failure?.data?.object.map { JSONValue.object($0.filter { safeKeys.contains($0.key) }) }
        return RPCFailure(code: code, message: message, data: data)
    }

    func patchPluginSettings(_ params: [String: JSONValue], operation: WorkspaceOperationContext) throws -> JSONValue {
        guard let id = params["id"]?.string, let expected = params["expectedWriteRevision"]?.string,
              case .array(let operations) = params["operations"] else { throw RPCFailure(code: -32602, message: "id, operations and expectedWriteRevision are required") }
        let read = try configurationRevision()
        guard read.revision == expected else { throw RPCFailure(code: APIError.conflict, message: "Settings source changed; read the namespace again") }
        let updated = try PluginSettingsPatch.updating(source: read.source, pluginID: id, operations: operations)
        let result = try commitConfigurationSource(source: read.source, updated: updated, operation: operation)
        var response = try pluginSettingsInfo(["id": .string(id)]).object!
        response["operationId"] = result.object?["operationId"]
        return .object(response)
    }

    func runSettingsCommand(_ id: String, params: [String: JSONValue], operation: WorkspaceOperationContext = .init(origin: .native)) throws -> JSONValue? {
        switch id {
        case "appearance.set", "appearance.light", "appearance.dark", "appearance.auto":
            let mode = id == "appearance.set" ? params["mode"]?.string : String(id.dropFirst("appearance.".count))
            guard let mode, ["auto", "light", "dark"].contains(mode) else { throw RPCFailure(code: -32602, message: "mode must be auto, light or dark") }
            return try writeConfiguration(["appearance.theme": .string(mode)], expected: params["expectedSourceRevision"]?.string, operation: operation)
        case "terminal.palette.set":
            guard let slot = params["slot"]?.string, ["light", "dark"].contains(slot), let name = params["name"]?.string else {
                throw RPCFailure(code: -32602, message: "slot (light|dark) and name are required")
            }
            return try writeConfiguration(["terminal.\(slot)_theme": .string(name)], expected: params["expectedSourceRevision"]?.string, operation: operation)
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
            return try writeConfiguration(["terminal.font_size": size], expected: params["expectedSourceRevision"]?.string, operation: operation)
        case "warnings.close.reset", "warnings.close.set", "warnings.type.reset", "warnings.type.set":
            let value = try WarningSuppression.value(command: id, params: withoutAPIGuards(params))
            if id.hasPrefix("warnings.close.") { try settings.setSuppressCloseWarning(value) }
            else { try settings.setSuppressTypeWarning(value) }
            updateStatusMenu()
            return .object(["suppressed": .bool(value)])
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
