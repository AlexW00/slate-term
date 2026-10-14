import Foundation

public struct ShellReport: Equatable, Codable, Sendable {
    public enum State: String, Codable, Sendable { case prompt, running }
    public let state: State
    public let pid: Int
    public let sequence: Int
    public let workingDirectory: String
    public let command: String?
    public let exitCode: Int?

    public init(state: State, pid: Int, sequence: Int, workingDirectory: String, command: String?, exitCode: Int?) {
        self.state = state; self.pid = pid; self.sequence = sequence
        self.workingDirectory = workingDirectory; self.command = command; self.exitCode = exitCode
    }
    enum CodingKeys: String, CodingKey { case state, pid, sequence, workingDirectory = "cwd", command, exitCode }
}

/// Ephemeral capability and sequence space. Replacing a terminal creates a new
/// session, so buffered reports from the old shell cannot change its successor.
public struct ShellSession: Sendable {
    public let instanceID = UUID().uuidString
    private let token: String
    public private(set) var report: ShellReport?
    public init(token: String) { self.token = token }
    public var runKey: String { "\u{1b}[slate-run-\(instanceID)~" }

    public func authenticate(token: String, pid: Int) throws {
        guard self.token == token, report?.pid == pid else {
            throw RPCFailure(code: -32040, message: "Shell session token or process does not match")
        }
    }

    public mutating func accept(_ next: ShellReport, token: String) throws {
        guard self.token == token else { throw RPCFailure(code: -32040, message: "Shell session token does not match") }
        guard next.pid > 0, next.pid <= Int(Int32.max), next.sequence > 0,
              next.workingDirectory.hasPrefix("/"), next.workingDirectory.utf8.count <= 16_384,
              !next.workingDirectory.utf8.contains(0), (next.command?.utf8.count ?? 0) <= 16_384,
              next.command?.utf8.contains(0) != true,
              next.state == .prompt ? next.exitCode.map({ (0...255).contains($0) }) == true : next.command != nil && next.exitCode == nil else {
            throw RPCFailure(code: -32602, message: "Invalid shell report")
        }
        if let report {
            guard next.pid == report.pid, next.sequence > report.sequence else {
                throw RPCFailure(code: -32041, message: "Shell report is stale or belongs to another process")
            }
        }
        report = next
    }
}
