import Foundation

/// Installs the bundled Slate Terminal skill for coding agents by linking it into
/// each agent's user skills folder. Links point at an app-managed copy, so they
/// stay valid when the app moves and pick up a newer skill when the app updates.
public struct AgentSkills: Sendable {
    public struct Target: Sendable, Equatable {
        public let id: String
        public let name: String
        /// Skills folder relative to the home directory.
        public let directory: String
        /// Folder that shows the agent is set up, relative to the home directory; nil for the shared folder.
        public let marker: String?
        public let detail: String
    }

    public enum Status: String, Sendable {
        case notInstalled, installed
        /// Something else named slate-terminal is there; it is never replaced or removed.
        case conflict
    }

    public struct Entry: Sendable, Equatable {
        public let target: Target
        public let path: URL
        public let detected: Bool
        public let status: Status
    }

    public static let skillName = "slate-terminal"

    /// The shared folder comes first: most agents read it, and installing there
    /// as well as an agent's own folder can show the skill twice.
    public static let targets: [Target] = [
        Target(id: "agents", name: "Shared (.agents)", directory: ".agents/skills", marker: nil,
               detail: "Codex, Gemini CLI, Cursor, GitHub Copilot, OpenCode, Amp and other agents that read ~/.agents/skills"),
        Target(id: "claude", name: "Claude Code", directory: ".claude/skills", marker: ".claude", detail: "~/.claude/skills"),
        Target(id: "codex", name: "Codex", directory: ".codex/skills", marker: ".codex", detail: "~/.codex/skills"),
        Target(id: "cursor", name: "Cursor", directory: ".cursor/skills", marker: ".cursor", detail: "~/.cursor/skills"),
        Target(id: "gemini", name: "Gemini CLI", directory: ".gemini/skills", marker: ".gemini", detail: "~/.gemini/skills"),
        Target(id: "copilot", name: "GitHub Copilot", directory: ".copilot/skills", marker: ".copilot", detail: "~/.copilot/skills"),
        Target(id: "opencode", name: "OpenCode", directory: ".config/opencode/skills", marker: ".config/opencode", detail: "~/.config/opencode/skills"),
    ]

    public let home: URL
    public let bundled: URL
    public let managed: URL

    /// - Parameters:
    ///   - bundled: The skill folder shipped in the app.
    ///   - managed: Where the app keeps the copy that links point to.
    public init(home: URL, bundled: URL, managed: URL) {
        self.home = home
        self.bundled = bundled
        self.managed = managed
    }

    public func entries() -> [Entry] {
        Self.targets.map { target in
            let path = link(for: target)
            let detected = target.marker.map { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) } ?? true
            return Entry(target: target, path: path, detected: detected, status: status(at: path))
        }
    }

    public func install(_ ids: [String]) throws {
        let targets = try resolve(ids)
        try refreshManagedCopy()
        for target in targets {
            let path = link(for: target)
            switch status(at: path) {
            case .installed: continue
            case .conflict: throw AgentSkillsError.conflict(path.path)
            case .notInstalled:
                try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: path, withDestinationURL: managed)
            }
        }
    }

    /// Removes only links this app created; anything else stays untouched.
    public func uninstall(_ ids: [String]) throws {
        for target in try resolve(ids) {
            let path = link(for: target)
            switch status(at: path) {
            case .notInstalled: continue
            case .conflict: throw AgentSkillsError.conflict(path.path)
            case .installed: try FileManager.default.removeItem(at: path)
            }
        }
    }

    /// Replaces the managed copy with the bundled skill. Hidden files are skipped.
    public func refreshManagedCopy() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: bundled.appendingPathComponent("SKILL.md").path) else {
            throw AgentSkillsError.missingBundle(bundled.path)
        }
        let parent = managed.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(managed.lastPathComponent)-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try copyVisible(from: bundled, to: staging)
        // Swap in place so existing links never see a missing folder for long.
        if fileManager.fileExists(atPath: managed.path) {
            _ = try fileManager.replaceItemAt(managed, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: managed)
        }
    }

    /// Keeps installed links current after an app update; does nothing when no agent uses the skill.
    public func refreshIfInstalled() throws {
        guard entries().contains(where: { $0.status == .installed }) else { return }
        try refreshManagedCopy()
    }

    private func link(for target: Target) -> URL {
        home.appendingPathComponent(target.directory).appendingPathComponent(Self.skillName)
    }

    private func status(at path: URL) -> Status {
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path.path) {
            let resolved = URL(fileURLWithPath: destination, relativeTo: path.deletingLastPathComponent()).standardizedFileURL
            return resolved.path == managed.standardizedFileURL.path ? .installed : .conflict
        }
        return FileManager.default.fileExists(atPath: path.path) ? .conflict : .notInstalled
    }

    private func resolve(_ ids: [String]) throws -> [Target] {
        guard !ids.isEmpty else { throw AgentSkillsError.invalid("Choose at least one agent") }
        return try ids.map { id in
            guard let target = Self.targets.first(where: { $0.id == id }) else {
                throw AgentSkillsError.invalid("Unknown agent '\(id)'. Use one of: \(Self.targets.map(\.id).joined(separator: ", "))")
            }
            return target
        }
    }

    private func copyVisible(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: source.path) where !name.hasPrefix(".") {
            let from = source.appendingPathComponent(name), to = destination.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: from.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { try copyVisible(from: from, to: to) }
            else { try fileManager.copyItem(at: from, to: to) }
        }
    }
}

public enum AgentSkillsError: Error, CustomStringConvertible, Sendable {
    case invalid(String), conflict(String), missingBundle(String)
    public var description: String {
        switch self {
        case .invalid(let message): message
        case .conflict(let path): "\(path) already exists and was not created by Slate Terminal; move or remove it first"
        case .missingBundle(let path): "The bundled skill is missing at \(path)"
        }
    }
}
