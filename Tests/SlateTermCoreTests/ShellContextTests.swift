import Foundation
import Testing
@testable import SlateTermCore

@Test func shellReportsAreScopedToOneProcessAndMonotonicSession() throws {
    var session = ShellSession(token: "session-one")
    let prompt = ShellReport(state: .prompt, pid: 123, sequence: 1, workingDirectory: "/tmp/日本語", command: nil, exitCode: 0)
    try session.accept(prompt, token: "session-one")
    #expect(session.report == prompt)
    try session.authenticate(token: "session-one", pid: 123)
    #expect(throws: RPCFailure.self) { try session.authenticate(token: "wrong", pid: 123) }
    #expect(throws: RPCFailure.self) { try session.authenticate(token: "session-one", pid: 999) }
    #expect(session.runKey != ShellSession(token: "session-one").runKey)
    let running = ShellReport(state: .running, pid: 123, sequence: 2, workingDirectory: "/tmp/日本語", command: "sleep 1", exitCode: nil)
    try session.accept(running, token: "session-one")
    #expect(session.report == running)
    #expect(throws: RPCFailure.self) { try session.accept(prompt, token: "session-one") }
    #expect(throws: RPCFailure.self) { try session.accept(running, token: "different-session") }
    #expect(throws: RPCFailure.self) {
        try session.accept(ShellReport(state: .prompt, pid: 999, sequence: 3, workingDirectory: "/", command: nil, exitCode: 0), token: "session-one")
    }
    #expect(session.report == running)
}

@Test func unknownShellContextStaysUnknownAndMalformedReportsAreAtomic() throws {
    var session = ShellSession(token: "session")
    #expect(session.report == nil)
    #expect(throws: RPCFailure.self) { try session.authenticate(token: "session", pid: 123) }
    for report in [
        ShellReport(state: .prompt, pid: 0, sequence: 1, workingDirectory: "/", command: nil, exitCode: 0),
        ShellReport(state: .prompt, pid: 1, sequence: 0, workingDirectory: "/", command: nil, exitCode: 0),
        ShellReport(state: .prompt, pid: 1, sequence: 1, workingDirectory: "relative", command: nil, exitCode: 0),
        ShellReport(state: .running, pid: 1, sequence: 1, workingDirectory: "/", command: nil, exitCode: 0),
    ] {
        #expect(throws: RPCFailure.self) { try session.accept(report, token: "session") }
        #expect(session.report == nil)
    }
}

private func report(_ state: ShellReport.State, _ sequence: Int, pid: Int = 123) -> ShellReport {
    ShellReport(state: state, pid: pid, sequence: sequence, workingDirectory: "/tmp",
                command: state == .running ? "work" : nil, exitCode: state == .prompt ? 0 : nil)
}

@Test func lateReportsAreAcceptedOnceWithoutChangingTheState() throws {
    var session = ShellSession(token: "t")
    #expect(try session.accept(report(.prompt, 2), token: "t") == .current)
    // The prompt (4) overtook its command's running report (3).
    #expect(try session.accept(report(.prompt, 4), token: "t") == .current)
    #expect(try session.accept(report(.running, 3), token: "t") == .late)
    #expect(session.report == report(.prompt, 4))
    // Replays and other processes are still rejected.
    #expect(throws: RPCFailure.self) { try session.accept(report(.running, 3), token: "t") }
    #expect(throws: RPCFailure.self) { try session.accept(report(.prompt, 4), token: "t") }
    #expect(throws: RPCFailure.self) { try session.accept(report(.running, 5, pid: 9), token: "t") }
    #expect(throws: RPCFailure.self) { try session.accept(report(.running, 1), token: "wrong") }
}

@Test func lateReportsOutsideTheWindowAreStale() throws {
    var session = ShellSession(token: "t")
    try session.accept(report(.prompt, 2), token: "t")
    try session.accept(report(.prompt, 2 + ShellSession.lateWindow + 10), token: "t")
    #expect(throws: RPCFailure.self) { try session.accept(report(.running, 3), token: "t") }
    #expect(try session.accept(report(.running, 2 + ShellSession.lateWindow + 9), token: "t") == .late)
}

@Test func reportsCarryTheShellAndRunAbility() throws {
    let decoded = try JSONDecoder().decode(ShellReport.self, from: Data(#"{"state":"prompt","pid":5,"sequence":2,"cwd":"/","exitCode":0,"shell":"bash","runInput":false}"#.utf8))
    #expect(decoded.shellKind == .bash && !decoded.acceptsRunInput)
    let legacy = try JSONDecoder().decode(ShellReport.self, from: Data(#"{"state":"prompt","pid":5,"sequence":2,"cwd":"/","exitCode":0}"#.utf8))
    #expect(legacy.shellKind == .zsh && legacy.acceptsRunInput, "zsh hooks predate both fields")
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ShellReport.self, from: Data(#"{"state":"prompt","pid":5,"sequence":2,"cwd":"/","exitCode":0,"shell":"tcsh"}"#.utf8))
    }
}

@Test func shellKindsAndRunKeys() {
    #expect(ShellKind(executablePath: "/opt/homebrew/bin/fish") == .fish)
    #expect(ShellKind(executablePath: "/bin/bash") == .bash)
    #expect(ShellKind(executablePath: "/bin/zsh") == .zsh)
    #expect(ShellKind(executablePath: "/bin/tcsh") == nil)
    let session = ShellSession(token: "t")
    #expect(session.runKey(for: .zsh) == session.runKey && session.runKey(for: .bash) == session.runKey)
    #expect(session.runKey(for: .fish) == "\u{10FFFD}")
    let id = UUID()
    for kind in ShellKind.allCases {
        let line = kind.runLine(id, command: "a\nb")
        #expect(line.hasPrefix(kind.runMarker(id)) && ShellKind.isRunMarker(line))
        #expect(!line.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }, "The editor receives one line")
    }
    #expect(ShellKind.fishQuote("it's \\ ok\u{1b}") == #"'it\'s \\ ok'\x1b"#)
    #expect(ShellKind.ansiQuote("it's\n") == #"it\x27s\x0a"#)
}

/// Every byte a caller can send must reach the shell unchanged. Checked with real shells;
/// fish is checked only where it is installed.
@Test func runLineQuotingRoundTripsThroughRealShells() throws {
    var payload = "it's \"quoted\" \\ $HOME `date` ; & | * ? ~ # % 日本語 🐈 e\u{301}"
    for byte in Array(UInt8(1)...UInt8(31)) + [127] { payload.unicodeScalars.append(UnicodeScalar(byte)) }
    payload += " end"
    var shells: [(ShellKind, String)] = [(.zsh, "/bin/zsh"), (.bash, "/bin/bash")]
    for path in ["/opt/homebrew/bin/bash", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"] where FileManager.default.isExecutableFile(atPath: path) {
        shells.append((ShellKind(executablePath: path)!, path))
    }
    for (kind, path) in shells {
        let id = UUID()
        // printf %s with one argument prints it unchanged in all three shells.
        let program = kind == .fish ? "printf %s \(ShellKind.fishQuote(payload))" : "printf %s $'\(ShellKind.ansiQuote(payload))'"
        let line = kind.runLine(id, command: program)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = kind == .fish ? ["--no-config", "-c", line] : ["-f", "-c", line].filter { kind == .zsh || $0 != "-f" }
        let output = Pipe()
        process.standardOutput = output
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": "/tmp"]
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(path) exited \(process.terminationStatus)")
        #expect(data == Data(payload.utf8), "\(path) changed the payload")
    }
}
