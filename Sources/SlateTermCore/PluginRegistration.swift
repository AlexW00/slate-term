import Foundation

public struct PluginOrigin: Equatable, Codable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int
    public init(url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { throw invalidPlugin("A plugin URL must have an origin and no credentials") }
        self.scheme = scheme
        self.host = host
        port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
        guard (0...65_535).contains(port) else { throw invalidPlugin("Invalid origin port") }
    }
    public func matches(_ url: URL) -> Bool { (try? PluginOrigin(url: url)) == self }
}

public enum PluginSource: Equatable, Sendable, Codable {
    case directory(path: String, entry: String)
    case url(URL)

    private enum Keys: String, CodingKey { case kind, path, entry, url }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "directory":
            try requirePluginKeys(decoder, allowed: ["kind", "path", "entry"])
            self = .directory(path: try values.decode(String.self, forKey: .path), entry: try values.decodeIfPresent(String.self, forKey: .entry) ?? "index.html")
        case "url":
            try requirePluginKeys(decoder, allowed: ["kind", "url"])
            self = .url(try values.decode(URL.self, forKey: .url))
        default: throw invalidPlugin("Unknown plugin source: \(kind)")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        switch self {
        case .directory(let path, let entry):
            try values.encode("directory", forKey: .kind); try values.encode(path, forKey: .path); try values.encode(entry, forKey: .entry)
        case .url(let url): try values.encode("url", forKey: .kind); try values.encode(url, forKey: .url)
        }
    }
}

public struct PluginProcessSpec: Equatable, Codable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let directory: String?
    public let environment: [String: String]
    public let restartLimit: Int
    public let readyTimeoutSeconds: Double
    private enum Keys: String, CodingKey { case executable, arguments, directory, environment, restartLimit, readyTimeoutSeconds }
    public init(from decoder: any Decoder) throws {
        try requirePluginKeys(decoder, allowed: ["executable", "arguments", "directory", "environment", "restartLimit", "readyTimeoutSeconds"])
        let values = try decoder.container(keyedBy: Keys.self)
        executable = try values.decode(String.self, forKey: .executable)
        arguments = try values.decodeIfPresent([String].self, forKey: .arguments) ?? []
        directory = try values.decodeIfPresent(String.self, forKey: .directory)
        environment = try values.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        restartLimit = try values.decodeIfPresent(Int.self, forKey: .restartLimit) ?? 3
        readyTimeoutSeconds = try values.decodeIfPresent(Double.self, forKey: .readyTimeoutSeconds) ?? 10
        guard executable.hasPrefix("/"), !executable.utf8.contains(0), arguments.count <= 128,
              arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 16_384 }),
              directory == nil || directory!.hasPrefix("/") && !directory!.utf8.contains(0),
              environment.count <= 128, environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) && $0.value.utf8.count <= 16_384 }),
              (0...10).contains(restartLimit), readyTimeoutSeconds.isFinite, (0.1...60).contains(readyTimeoutSeconds) else {
            throw invalidPlugin("Invalid plugin process configuration")
        }
    }
}

public struct PluginRegistration: Equatable, Codable, Sendable {
    public enum Scope: String, Codable, Sendable { case pane, tab, global }
    public let id: String
    public let title: String
    public let source: PluginSource?
    public let scope: Scope
    public let process: PluginProcessSpec?
    /// App-level headless runtime, independent of the panel's HTTP process.
    public let service: PluginProcessSpec?
    public let commands: [PluginCommand]
    public let headerButtons: [PluginHeaderButton]
    public let layoutFields: [SavedLayoutField]
    /// Host-derived installation context; never accepted from manifest JSON.
    public var packageRoot: String? = nil

    public var hasPanel: Bool { source != nil }
    public var entryURL: URL? {
        switch source {
        case .url(let url): return url
        case .directory(_, let entry): return URL(string: "plugin://\(id)/")!.appendingPathComponent(entry)
        case nil: return nil
        }
    }
    public var origin: PluginOrigin? { entryURL.map { try! PluginOrigin(url: $0) } }
    public var workspaceCommands: [WorkspaceCommand] {
        commands.map { .init(id: $0.namespacedID(plugin: id), title: "\(title): \($0.title)", key: "", shift: false) }
    }

    public static func parse(_ data: Data) throws -> PluginRegistration {
        guard data.count <= 262_144 else { throw invalidPlugin("Plugin manifest exceeds 256 KiB") }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey { case id, title, source, scope, process, service, commands, headerButtons, layoutFields }
    public init(from decoder: any Decoder) throws {
        try requirePluginKeys(decoder, allowed: ["id", "title", "source", "scope", "process", "service", "commands", "headerButtons", "layoutFields"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        source = try values.decodeIfPresent(PluginSource.self, forKey: .source)
        scope = try values.decodeIfPresent(Scope.self, forKey: .scope) ?? .pane
        process = try values.decodeIfPresent(PluginProcessSpec.self, forKey: .process)
        service = try values.decodeIfPresent(PluginProcessSpec.self, forKey: .service)
        commands = try values.decodeIfPresent([PluginCommand].self, forKey: .commands) ?? []
        headerButtons = try values.decodeIfPresent([PluginHeaderButton].self, forKey: .headerButtons) ?? []
        layoutFields = try values.decodeIfPresent([SavedLayoutField].self, forKey: .layoutFields) ?? []
        guard layoutFields.count <= 32, Set(layoutFields.map(\.id)).count == layoutFields.count,
              source != nil || layoutFields.isEmpty else {
            throw invalidPlugin("Layout fields require a panel and at most 32 unique field IDs")
        }
        guard headerButtons.count <= 8, Set(headerButtons.map(\.id)).count == headerButtons.count,
              headerButtons.allSatisfy({ button in commands.contains { $0.id == button.command } }) else {
            throw invalidPlugin("Header buttons must be unique (at most 8) and reference this plugin's commands")
        }
        guard commands.count <= 32, Set(commands.map(\.id)).count == commands.count,
              (source != nil || !commands.isEmpty || service != nil), source != nil || process == nil else {
            throw invalidPlugin("A plugin needs a panel, commands or service; commands must be unique (at most 32), and process requires a panel source")
        }
        guard id.utf8.count <= 64, id.range(of: "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$", options: .regularExpression) == id.startIndex..<id.endIndex,
              !["terminal", "browser", "private-browser"].contains(id), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 100, !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw invalidPlugin("Invalid or reserved plugin identity/title")
        }
        switch source {
        case nil: break
        case .directory(let path, let entry):
            guard path.hasPrefix("/"), !path.utf8.contains(0), !entry.isEmpty, !entry.hasPrefix("/"),
                  !entry.utf8.contains(0), !entry.split(separator: "/").contains(".."), process == nil else {
                throw invalidPlugin("Static plugins require an absolute root and relative entry, without a process")
            }
        case .url(let url):
            let origin = try PluginOrigin(url: url)
            let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(origin.host)
            guard origin.port > 0 || process != nil, origin.scheme == "https" || origin.scheme == "http" && loopback else {
                throw invalidPlugin("Use HTTPS, or HTTP on a loopback host, for a registered URL")
            }
            if process != nil, !(origin.scheme == "http" && origin.host == "127.0.0.1") {
                throw invalidPlugin("Managed plugin servers must listen on an http://127.0.0.1 URL so listener ownership can be verified")
            }
        }
    }
}

/// Resolves only files under the registered static root, including after symlink
/// resolution. Registration explicitly trusts that root and its local owner.
public struct PluginAssets: Sendable {
    private let root: URL
    public init(root: URL) throws {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        var directory: ObjCBool = false
        guard root.isFileURL, FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory), directory.boolValue else {
            throw invalidPlugin("Static plugin root is not a directory")
        }
        self.root = resolved
    }
    public func file(forPercentEncodedPath path: String) throws -> URL {
        guard let decoded = path.removingPercentEncoding, !decoded.utf8.contains(0), !decoded.contains("\\") else { throw invalidPlugin("Invalid asset path") }
        let components = decoded.split(separator: "/")
        guard components.allSatisfy({ !$0.hasPrefix(".") }) else { throw invalidPlugin("Hidden files and traversal are not served") }
        let relative = components.isEmpty ? "index.html" : components.joined(separator: "/")
        let file = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { throw invalidPlugin("Asset path escapes its registered root") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 16_777_216 else { throw invalidPlugin("Asset is not a regular file of at most 16 MiB") }
        return file
    }
}

private func invalidPlugin(_ message: String) -> RPCFailure { RPCFailure(code: -32602, message: message) }
private struct PluginKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
func requirePluginKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let keys = try decoder.container(keyedBy: PluginKey.self).allKeys.map(\.stringValue)
    if let unknown = keys.first(where: { !allowed.contains($0) }) { throw invalidPlugin("Unknown plugin field: \(unknown)") }
}
