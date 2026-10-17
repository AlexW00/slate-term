import Foundation

/// Shells with Slate's authenticated integration. Each kind has its own run-line syntax.
public enum ShellKind: String, Codable, Sendable, CaseIterable {
    case zsh, bash, fish

    /// Matches by executable name, as the terminal engine does for its own integration.
    public init?(executablePath: String) {
        guard let kind = ShellKind(rawValue: URL(fileURLWithPath: executablePath).lastPathComponent) else { return nil }
        self = kind
    }

    /// The marker is the first word of the submitted line, so preexec text starts with it.
    public func runMarker(_ id: UUID) -> String {
        switch self {
        case .zsh, .bash: return ": __SLATE_RUN_\(id.uuidString);"
        case .fish: return "true __SLATE_RUN_\(id.uuidString);"
        }
    }

    /// One line the shell's editor accepts as a single command: no raw control characters.
    public func runLine(_ id: UUID, command: String) -> String {
        switch self {
        case .zsh, .bash: return "\(runMarker(id)) builtin eval $'\(Self.ansiQuote(command))'"
        case .fish: return "\(runMarker(id)) eval \(Self.fishQuote(command))"
        }
    }

    /// Recognizes any shell's marker, for consumers that only need to know a run started.
    public static func isRunMarker(_ command: String) -> Bool {
        command.hasPrefix(": __SLATE_RUN_") || command.hasPrefix("true __SLATE_RUN_")
    }

    /// zsh and bash `$'…'`: escape quotes, backslashes and control characters as `\xHH`.
    static func ansiQuote(_ command: String) -> String {
        var quoted = ""
        for scalar in command.unicodeScalars {
            let value = scalar.value
            if value < 32 || value == 127 || value == 39 || value == 92 {
                quoted += String(format: "\\x%02x", value)
            } else {
                quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted
    }

    /// fish has no `$'…'`. Adjacent tokens concatenate, so control characters sit
    /// outside single quotes as `\xHH`; inside quotes only `\'` and `\\` are escapes.
    static func fishQuote(_ command: String) -> String {
        var quoted = ""
        var open = false
        for scalar in command.unicodeScalars {
            let value = scalar.value
            if value < 32 || value == 127 {
                if open { quoted += "'"; open = false }
                quoted += String(format: "\\x%02x", value)
                continue
            }
            if !open { quoted += "'"; open = true }
            if value == 39 || value == 92 { quoted += "\\" }
            quoted.unicodeScalars.append(scalar)
        }
        if open { quoted += "'" }
        return quoted
    }
}

public struct ShellReport: Equatable, Codable, Sendable {
    public enum State: String, Codable, Sendable { case prompt, running }
    public let state: State
    public let pid: Int
    public let sequence: Int
    public let workingDirectory: String
    public let command: String?
    public let exitCode: Int?
    /// Which hooks sent the report. Absent means zsh, the original integration.
    public let shell: ShellKind?
    /// False when the shell cannot check its edit buffer, so `terminal.run` must refuse.
    public let runInput: Bool?

    public init(state: State, pid: Int, sequence: Int, workingDirectory: String, command: String?, exitCode: Int?,
                shell: ShellKind? = nil, runInput: Bool? = nil) {
        self.state = state; self.pid = pid; self.sequence = sequence
        self.workingDirectory = workingDirectory; self.command = command; self.exitCode = exitCode
        self.shell = shell; self.runInput = runInput
    }
    enum CodingKeys: String, CodingKey { case state, pid, sequence, workingDirectory = "cwd", command, exitCode, shell, runInput }

    public var shellKind: ShellKind { shell ?? .zsh }
    public var acceptsRunInput: Bool { runInput ?? true }
}

/// Ephemeral capability and sequence space. Replacing a terminal creates a new
/// session, so buffered reports from the old shell cannot change its successor.
public struct ShellSession: Sendable {
    /// Reports travel on separate connections and can arrive out of order.
    public enum Acceptance: Equatable, Sendable {
        /// The newest report; it is now the session's state.
        case current
        /// An older report that arrived late. It never changes the state, but run
        /// tracking still needs it to pair a command with its prompt.
        case late
    }

    /// How far behind the newest report a late report may be.
    public static let lateWindow = 64

    public let instanceID = UUID().uuidString
    private let token: String
    public private(set) var report: ShellReport?
    private var seen = Set<Int>()
    public init(token: String) { self.token = token }
    public var runKey: String { "\u{1b}[slate-run-\(instanceID)~" }
    /// fish 4 decodes escape sequences into keys and drops ones it cannot parse, so fish
    /// binds one private-use character instead. A claim still needs a pending run.
    public func runKey(for shell: ShellKind) -> String { shell == .fish ? "\u{10FFFD}" : runKey }

    public func authenticate(token: String, pid: Int) throws {
        guard self.token == token, report?.pid == pid else {
            throw RPCFailure(code: -32040, message: "Shell session token or process does not match")
        }
    }

    @discardableResult
    public mutating func accept(_ next: ShellReport, token: String) throws -> Acceptance {
        guard self.token == token else { throw RPCFailure(code: -32040, message: "Shell session token does not match") }
        guard next.pid > 0, next.pid <= Int(Int32.max), next.sequence > 0,
              next.workingDirectory.hasPrefix("/"), next.workingDirectory.utf8.count <= 16_384,
              !next.workingDirectory.utf8.contains(0), (next.command?.utf8.count ?? 0) <= 16_384,
              next.command?.utf8.contains(0) != true,
              next.state == .prompt ? next.exitCode.map({ (0...255).contains($0) }) == true : next.command != nil && next.exitCode == nil else {
            throw RPCFailure(code: -32602, message: "Invalid shell report")
        }
        guard let report else {
            self.report = next
            seen = [next.sequence]
            return .current
        }
        guard next.pid == report.pid, !seen.contains(next.sequence),
              next.sequence > report.sequence - Self.lateWindow else {
            throw RPCFailure(code: -32041, message: "Shell report is stale or belongs to another process")
        }
        seen.insert(next.sequence)
        let newest = max(report.sequence, next.sequence)
        seen = seen.filter { $0 > newest - Self.lateWindow }
        guard next.sequence > report.sequence else { return .late }
        self.report = next
        return .current
    }
}
