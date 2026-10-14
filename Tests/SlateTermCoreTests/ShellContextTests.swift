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
