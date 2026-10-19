import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermIPC

/// The package's own CLI, built by `swift test` alongside the tests.
private let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/slate-term")

private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// A host that, like an app busy launching, accepts nothing until `acceptAfter` has passed.
/// It runs on its own threads, so tests never block the shared main actor.
private final class BusyHost: @unchecked Sendable {
    let path = "/tmp/slate-busy-\(UUID().uuidString.prefix(8)).sock"
    let reports = Box<[[String: JSONValue]]>([])
    private let listener: Int32

    init(acceptAfter delay: TimeInterval, backlog: Int32 = SOMAXCONN) throws {
        listener = try makeSocket(nonblocking: false)
        try withSocketAddress(path) { address, length in
            guard bind(listener, address, length) == 0, listen(listener, backlog) == 0 else { throw SocketError.system("listen", errno) }
        }
        let listener = listener, reports = reports
        Thread.detachNewThread {
            usleep(useconds_t(delay * 1_000_000))
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 { return }
                Thread.detachNewThread { Self.serve(connection, reports) }
            }
        }
    }

    private static func serve(_ connection: Int32, _ reports: Box<[[String: JSONValue]]>) {
        defer { Darwin.close(connection) }
        var framing = LineFramer()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(connection, &buffer, buffer.count)
            guard count > 0, let lines = try? framing.append(Data(buffer.prefix(count))) else { return }
            for line in lines {
                guard let request = try? RPCRequest.decode(line) else { return }
                if request.method == "shell.update" { reports.update { $0.append(request.params ?? [:]) } }
                guard let id = request.id, let reply = try? JSONEncoder().encode(RPCResponse(id: id, result: .null)) else { continue }
                _ = (reply + Data([10])).withUnsafeBytes { Darwin.write(connection, $0.baseAddress, $0.count) }
            }
        }
    }

    func close() {
        Darwin.close(listener)
        unlink(path)
    }
}

/// `pid` is the reporting shell; it must be alive, or delivery stops retrying. The test process stands in.
private func report(_ state: String, sequence: Int, socket: String, command: String? = "work", pid: Int32 = getpid()) -> Process {
    let process = Process()
    process.executableURL = cli
    process.arguments = ["shell", "update", "--shell", "bash", "--run-input", "false", "--state", state, "--pid", "\(pid)",
                         "--sequence", "\(sequence)", "--cwd=/tmp"] + (state == "prompt" ? ["--exit-code", "0"] : command.map { ["--command=\($0)"] } ?? [])
    process.environment = ["SLATE_TERM_SOCKET": socket, "SLATE_TERM_PANE_ID": "p1", "SLATE_TERM_CONTEXT_TOKEN": "token"]
    return process
}

/// Runs a hook's CLI call to completion and returns how long the prompt waited.
private func timedRun(_ process: Process) throws -> TimeInterval {
    #expect(FileManager.default.isExecutableFile(atPath: cli.path), "Build the slate-term product first")
    let started = Date()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "Delivery problems belong to the detached copy, never the prompt")
    return Date().timeIntervalSince(started)
}

private func eventually(_ condition: () -> Bool, seconds: TimeInterval = 8) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline { usleep(20_000) }
}

/// These tests wait synchronously on processes and fake hosts. Run one at a time so they never
/// starve the shared test threads and distort the timings they measure.
@Suite(.serialized) struct ShellReportDeliveryTests {

/// The launch race: the shell reports its first prompt while the app is too busy to accept.
/// The prompt must not wait, and the report must still arrive.
@Test func promptReportReachesABusyHostWithoutBlockingThePrompt() throws {
    let host = try BusyHost(acceptAfter: 2)
    defer { host.close() }
    #expect(try timedRun(report("prompt", sequence: 2, socket: host.path)) < 1)
    #expect(host.reports.value.isEmpty)
    eventually { !host.reports.value.isEmpty }
    let params = try #require(host.reports.value.first)
    #expect(params["sequence"] == .integer(2) && params["shell"] == .string("bash") && params["runInput"] == .bool(false))
    #expect(params["token"] == .string("token") && params["pane"] == .string("p1") && params["cwd"] == .string("/tmp"))
}

/// A command's start reaches a responsive host before the command runs, so the host never
/// mistakes a running program for an idle prompt.
@Test func runningReportIsDeliveredBeforeTheHookReturns() throws {
    let host = try BusyHost(acceptAfter: 0)
    defer { host.close() }
    _ = try timedRun(report("running", sequence: 3, socket: host.path, command: "-la starts with a dash"))
    #expect(host.reports.value.first?["command"] == .string("-la starts with a dash"), "The report arrived before the hook returned")
}

/// bash cannot always tell what started (history off); the report still marks the start.
@Test func runningReportWithoutCommandTextIsStillDelivered() throws {
    let host = try BusyHost(acceptAfter: 0)
    defer { host.close() }
    _ = try timedRun(report("running", sequence: 5, socket: host.path, command: nil))
    #expect(host.reports.value.first?["command"] == .string(""))
}

/// A busy host delays a command's start by about a second at most; the report still arrives.
@Test func runningReportFallsBackToDetachedDeliveryWhenTheHostIsBusy() throws {
    let host = try BusyHost(acceptAfter: 3)
    defer { host.close() }
    #expect(try timedRun(report("running", sequence: 3, socket: host.path)) < 2)
    eventually { !host.reports.value.isEmpty }
    // The first attempt reached the queue before giving up; a late duplicate is a replay the session rejects.
    #expect(host.reports.value.map { $0["sequence"] }.allSatisfy { $0 == .integer(3) } && !host.reports.value.isEmpty)
}

/// Restoring a large layout starts many shells at once while the app is busy. A full listen
/// queue refuses connections immediately, so the detached copies retry until accepted.
@Test func manyShellsReportingAtLaunchAreAllDelivered() throws {
    let host = try BusyHost(acceptAfter: 2, backlog: 4)
    defer { host.close() }
    let count = 30
    let finished = Box(0)
    for index in 1...count {
        Thread.detachNewThread {
            _ = try? timedRun(report("prompt", sequence: index * 2, socket: host.path))
            finished.update { $0 += 1 }
        }
    }
    func sequences() -> Set<Int> {
        Set(host.reports.value.compactMap { if case .integer(let value) = $0["sequence"] { value } else { nil } })
    }
    eventually({ sequences().count == count }, seconds: 12)
    #expect(sequences() == Set((1...count).map { $0 * 2 }))
}

/// After the app quits its socket is gone; nothing may linger retrying, or quitting leaks processes.
@Test func shellReportWithoutAHostFailsQuietlyAndLeavesNothingBehind() throws {
    let socket = "/tmp/slate-missing-\(UUID().uuidString.prefix(8)).sock"
    for state in ["prompt", "running"] {
        #expect(try timedRun(report(state, sequence: 2, socket: socket)) < 1.5)
    }
    usleep(500_000)
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axww", "-o", "command="]
    ps.environment = [:]
    let output = Pipe()
    ps.standardOutput = output
    try ps.run()
    let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ps.waitUntilExit()
    #expect(!listing.contains(socket) && !listing.split(separator: "\n").contains { $0.contains("--deliver") && $0.contains(socket) })
}

/// A killed app leaves its socket file behind, and connecting to it is refused just like a full
/// queue. Once the reporting shell is gone too, the copy must stop retrying and exit.
@Test func deliveryForAnEndedShellStopsRetrying() throws {
    let socket = "/tmp/slate-dead-\(UUID().uuidString.prefix(8)).sock"
    let listener = try makeSocket(nonblocking: false)
    try withSocketAddress(socket) { address, length in
        guard bind(listener, address, length) == 0 else { throw SocketError.system("bind", errno) }
    }
    Darwin.close(listener)  // The file stays; connections are refused.
    defer { unlink(socket) }
    let ended = Process()
    ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try ended.run()
    ended.waitUntilExit()
    func lingering(pid: Int32) throws -> Bool {
        let process = report("prompt", sequence: 2, socket: socket, pid: pid)
        process.arguments = (process.arguments ?? []) + ["--socket", socket]
        _ = try timedRun(process)
        usleep(800_000)
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "command="]
        let output = Pipe()
        ps.standardOutput = output
        try ps.run()
        let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return listing.split(separator: "\n").contains { $0.contains("--deliver") && $0.contains(socket) }
    }
    #expect(try !lingering(pid: ended.processIdentifier), "A copy for an ended shell outlived the app")
    #expect(try lingering(pid: getpid()), "A live shell's report keeps retrying while the host is busy")
}

/// Other processes can read arguments; the detached copy gets command text only on stdin.
@Test func detachedCopyKeepsCommandTextOutOfItsArguments() throws {
    let marker = "secret-\(UUID().uuidString)"
    let host = try BusyHost(acceptAfter: 3)
    defer { host.close() }
    _ = try timedRun(report("running", sequence: 3, socket: host.path, command: "export TOKEN=\(marker)"))
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axww", "-o", "command="]
    let output = Pipe()
    ps.standardOutput = output
    try ps.run()
    let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    ps.waitUntilExit()
    #expect(listing.contains("shell update --deliver"), "The detached copy is still waiting for the busy host")
    #expect(!listing.contains(marker))
    eventually { !host.reports.value.isEmpty }
    #expect(host.reports.value.first?["command"] == .string("export TOKEN=\(marker)"))
}
}
