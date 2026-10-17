import Foundation

/// Portable package bytes. Runtime registrations are derived, never written back to the manifest.
public struct PluginManifest: Sendable {
    public let value: JSONValue
    public let id: String
    public let title: String

    public init(data: Data) throws {
        guard data.count <= 262_144 else { throw Self.invalid("Plugin manifest exceeds 256 KiB") }
        value = try JSONDecoder().decode(JSONValue.self, from: data)
        let registration = try Self.resolve(value, root: URL(fileURLWithPath: "/__slate_package_validation__"))
        id = registration.id
        title = registration.title
    }

    public func registration(root: URL, validateFiles: Bool = true) throws -> PluginRegistration {
        var registration = try Self.resolve(value, root: root)
        if validateFiles {
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            func contained(_ path: String) throws {
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/") else {
                    throw Self.invalid("Installed resource escapes its package root")
                }
            }
            if case .directory(let path, _) = registration.source {
                try contained(path)
                let encodedPath = URLComponents(url: registration.entryURL!, resolvingAgainstBaseURL: false)!.percentEncodedPath
                _ = try PluginAssets(root: URL(fileURLWithPath: path)).file(forPercentEncodedPath: encodedPath)
            }
            let specs = [registration.process, registration.service].compactMap { $0 }
            for (executable, directory) in specs.map({ ($0.executable, $0.directory) }) + registration.commands.map({ ($0.executable, $0.directory) }) {
                if let directory { try contained(directory) }
                guard let directory, (try URL(fileURLWithPath: directory).resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                    throw Self.invalid("Plugin working directory does not exist")
                }
                if executable.hasPrefix(root.path + "/") {
                    try contained(executable)
                    guard (try URL(fileURLWithPath: executable).resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true,
                          FileManager.default.isExecutableFile(atPath: executable) else {
                        throw Self.invalid("Packaged executable must be an executable regular file")
                    }
                }
            }
        }
        registration.packageRoot = root.path
        return registration
    }

    public static func relativePath(_ path: String, allowRoot: Bool = false) throws -> String {
        if allowRoot && path == "." { return "" }
        let value = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.utf8.contains(0),
              value.utf8.count <= 1024, components.count <= 32,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw invalid("Invalid package-relative path: \(path.prefix(120))")
        }
        return value
    }

    private static func resolve(_ value: JSONValue, root: URL) throws -> PluginRegistration {
        guard var object = value.object else { throw invalid("Plugin manifest must be an object") }
        func local(_ path: String, allowRoot: Bool = false) throws -> String {
            let relative = try relativePath(path, allowRoot: allowRoot)
            return relative.isEmpty ? root.path : root.appendingPathComponent(relative).path
        }
        func spec(_ value: JSONValue) throws -> JSONValue {
            guard var spec = value.object, let executable = spec["executable"]?.string else { throw invalid("An executable is required") }
            if !executable.hasPrefix("/") {
                guard executable.hasPrefix("./") else { throw invalid("Use an absolute external executable or ./package/path") }
                spec["executable"] = .string(try local(executable))
            }
            if let directory = spec["directory"] {
                guard let path = directory.string else { throw invalid("Working directory must be a relative path") }
                spec["directory"] = .string(try local(path, allowRoot: true))
            } else { spec["directory"] = .string(root.path) }
            if case .array(let arguments) = spec["arguments"] {
                spec["arguments"] = .array(try arguments.map { argument in
                    guard let text = argument.string else { throw invalid("Arguments must be strings") }
                    if text == "{pluginRoot}" { return .string(root.path) }
                    if text.hasPrefix("{pluginRoot}/") { return .string(try local(String(text.dropFirst(13)))) }
                    guard !text.contains("{pluginRoot}") else { throw invalid("{pluginRoot} must be a standalone token or path prefix") }
                    return argument
                })
            }
            return .object(spec)
        }
        if var source = object["source"]?.object, source["kind"]?.string == "directory" {
            guard let path = source["path"]?.string else { throw invalid("Static source requires a package-relative path") }
            source["path"] = .string(try local(path, allowRoot: true))
            if let entry = source["entry"]?.string { _ = try relativePath(entry) }
            object["source"] = .object(source)
        }
        for key in ["process", "service"] { if let value = object[key] { object[key] = try spec(value) } }
        if case .array(let commands) = object["commands"] { object["commands"] = .array(try commands.map(spec)) }
        return try PluginRegistration.parse(JSONEncoder().encode(JSONValue.object(object)))
    }

    private static func invalid(_ message: String) -> RPCFailure { RPCFailure(code: -32602, message: message) }
}
