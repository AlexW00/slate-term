import Foundation

/// An on-demand executable contribution, independent of any panel's lifetime.
public struct PluginCommand: Equatable, Codable, Sendable {
    public let id: String
    public let title: String
    public let executable: String
    public let arguments: [String]
    public let directory: String?
    public let environment: [String: String]
    public let timeoutSeconds: Double

    public func namespacedID(plugin: String) -> String { "plugin.\(plugin).\(id)" }

    /// Unavailable plugin bindings remain valid configuration, but are not dispatched.
    public static func isNamespacedID(_ value: String) -> Bool {
        value.utf8.count <= 136 && value.range(of: "^plugin\\.[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*\\.[a-z][a-z0-9-]*$", options: .regularExpression) == value.startIndex..<value.endIndex
    }

    private enum Keys: String, CodingKey, CaseIterable {
        case id, title, executable, arguments, directory, environment, timeoutSeconds
    }
    public init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        guard all.allKeys.allSatisfy({ Keys(rawValue: $0.stringValue) != nil }) else {
            throw RPCFailure(code: -32602, message: "Unknown plugin command field")
        }
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 30
        guard id.utf8.count <= 64, id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) == id.startIndex..<id.endIndex,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 100,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              executable.hasPrefix("/"), !executable.contains("\0"),
              arguments.count <= 128, arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 16_384 }),
              directory == nil || directory!.hasPrefix("/") && !directory!.contains("\0"),
              environment.count <= 128, environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") && $0.value.utf8.count <= 16_384 }),
              timeoutSeconds.isFinite, (0.1...295).contains(timeoutSeconds) else {
            throw RPCFailure(code: -32602, message: "Invalid plugin command identity, executable, arguments, environment or timeout (0.1–295 seconds)")
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

/// Written by the private supervisor before it kills its owned process group.
/// The supervisor itself exits by signal even when the command succeeds.
public struct PluginCommandExit: Codable, Sendable {
    public let exitCode: Int?
    public let signal: Int?
    public init(exitCode: Int?, signal: Int?) { self.exitCode = exitCode; self.signal = signal }
}
