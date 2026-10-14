import Darwin
import Foundation
import SlateTermCore

@main
struct ProcessTitles {
    static func main() throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.dropFirst().first == "pty-shell" {
            try runShell()
            return
        }
        if CommandLine.arguments.dropFirst().first == "no-tty" {
            guard setsid() > 0 else { throw Failure(message: "fixture setsid") }
            writeReady()
            while true { pause() }
        }
        do {
            try checkTitles()
            try checkParsing()
            print("PASS all process title checks")
        } catch {
            fputs("FAIL process titles: \(error)\n", stderr)
            exit(1)
        }
    }

    static func checkTitles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-titles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = descriptorCount()
        let first = try PTYShell(pane: "p1", home: root.path)
        defer { first.close() }
        let second = try PTYShell(pane: "p2", home: root.path)
        defer { second.close() }
        let unknown = try PTYShell(pane: nil, home: root.path)
        defer { unknown.close() }
        let outside = try PTYShell(pane: "p99", home: root.path)
        defer { outside.close() }
        let titles = TerminalProcessTitles()
        let p1 = PaneID(1), p2 = PaneID(2)
        let panes: Set<PaneID> = [p1, p2]
        for shell in [first, second, unknown, outside] {
            try eventually("owned helper readiness") { shell.drain().contains("owned-ready\r\n") }
        }
        // SIP hides restricted system shells' environments on current macOS. Attribute our
        // unrestricted direct children before exec, then test the same PID through real sh.
        try eventually("owned helper attribution") { Set(titles.names(for: panes).keys) == panes }
        for shell in [first, second, unknown, outside] {
            try shell.send("launch\n")
            try shell.send("printf 'fixture-ready\\n'\n")
            try eventually("shell readiness") { shell.drain().contains("fixture-ready\r\n") }
        }
        let shellName = try kernelName(first.pid)
        try require(["sh", "bash"].contains(shellName), "fixture is not the real sh executable")
        try require(try kernelName(second.pid) == shellName, "shell fixtures differ")
        try eventually("two distinct pane shell names") { titles.names(for: panes) == [p1: shellName, p2: shellName] }
        try require(titles.names(for: [p1]) == [p1: shellName], "unrequested panes leaked")
        try require(titles.names(for: []) == [:], "empty pane sample")
        print("PASS direct children attributed by distinct pane environments; unknown/unrequested ignored")
        let fresh = TerminalProcessTitles().names(for: panes)
        try require(fresh.isEmpty || fresh == [p1: shellName, p2: shellName], "fresh attribution guessed or misnamed a restricted shell")
        print(fresh.isEmpty ? "PASS redacted system-shell environments fail closed (host limitation)" : "PASS fresh system-shell attribution (environment readable on this host)")
        let authenticated = TerminalProcessTitles()
        authenticated.bind(pane: p1, pid: first.pid)
        authenticated.bind(pane: p2, pid: second.pid)
        authenticated.bind(pane: PaneID(3), pid: getpid())
        try require(authenticated.names(for: [p1, p2, PaneID(3)]) == [p1: shellName, p2: shellName], "Authenticated bindings failed or accepted a non-child")
        print("PASS authenticated shell binding works with redacted environments and rejects non-children")
        let duplicate = try PTYShell(pane: "p1", home: root.path)
        defer { duplicate.close() }
        try eventually("duplicate readiness") { duplicate.drain().contains("owned-ready\r\n") }
        try require(titles.names(for: panes) == [p2: shellName], "ambiguous pane ownership guessed")
        duplicate.close()
        try require(titles.names(for: panes) == [p1: shellName, p2: shellName], "ambiguous pane did not recover after child exit")
        let unattached = try PTYShell(pane: "p3", home: root.path, mode: "no-tty")
        defer { unattached.close() }
        try eventually("unattached readiness") { unattached.drain().contains("owned-ready\r\n") }
        let fixtureName = try kernelName(unattached.pid)
        try require(titles.names(for: [PaneID(3)]) == [PaneID(3): fixtureName], "no-TTY child name fallback")
        unattached.close()
        print("PASS ambiguous ownership rejected and no-TTY owned child name fallback")

        try first.send("/bin/sleep 2\n")
        try eventually("foreground sh -> sleep") { titles.names(for: panes) == [p1: "sleep", p2: shellName] }
        try require(authenticated.names(for: panes) == [p1: "sleep", p2: shellName], "Authenticated binding did not follow the foreground process")
        try require(tcgetpgrp(first.master) != first.pid, "sleep did not acquire its own foreground group")
        try eventually("foreground sleep -> sh", timeout: 4) { titles.names(for: panes) == [p1: shellName, p2: shellName] }
        print("PASS real PTY foreground-group transition sh -> sleep -> sh without integration")

        try second.send("exec /bin/cat\n")
        try eventually("same PID exec name updates") { titles.names(for: panes) == [p1: shellName, p2: "cat"] }
        second.close()
        try eventually("exited child omitted") { titles.names(for: panes) == [p1: shellName] }
        let replacement = try PTYShell(pane: "p2", home: root.path)
        defer { replacement.close() }
        try eventually("replacement helper readiness") { replacement.drain().contains("owned-ready\r\n") }
        try eventually("replacement helper attribution") { Set(titles.names(for: panes).keys) == panes }
        try replacement.send("launch\n")
        try replacement.send("printf 'replacement-ready\\n'\n")
        try eventually("replacement readiness") { replacement.drain().contains("replacement-ready\r\n") }
        try eventually("replacement child mapped") { titles.names(for: panes) == [p1: shellName, p2: shellName] }
        first.close()
        replacement.close()
        unknown.close()
        outside.close()
        try require(titles.names(for: panes).isEmpty, "exited child mappings survived")
        try require(descriptorCount() == before, "PTY fixture descriptors leaked")
        print("PASS exec updates, child exit/cache cleanup, replacement mapping and fixture cleanup")
    }

    static func checkParsing() throws {
        func packed(argc: Int32 = 1, executable: String = "/bin/sh", padding: Int = 2,
                    arguments: [String] = ["sh"], environment: [String], terminated: Bool = true) -> [UInt8] {
            var count = argc
            var bytes = withUnsafeBytes(of: &count) { Array($0) }
            bytes += Array(executable.utf8) + [0] + Array(repeating: 0, count: padding)
            for argument in arguments { bytes += Array(argument.utf8) + [0] }
            for entry in environment { bytes += Array(entry.utf8) + [0] }
            if terminated { bytes += [0] }
            return bytes
        }
        func parse(_ bytes: [UInt8]) -> PaneID? {
            bytes.withUnsafeBytes { TerminalProcessTitles.paneID(in: $0) }
        }
        try require(parse(packed(environment: ["SECRET=never-retained", "SLATE_TERM_PANE_ID=p12", "PATH=/bin"])) == PaneID(12), "pane after unrelated environment")
        try require(parse(packed(argc: 3, padding: 0, arguments: ["sh", "", "SLATE_TERM_PANE_ID=p77"], environment: ["SLATE_TERM_PANE_ID=p2"])) == PaneID(2), "argv mistaken for environment or empty argument skipped")
        try require(parse(packed(environment: ["OTHER_SLATE_TERM_PANE_ID=p1"])) == nil, "partial environment key matched")
        for value in ["", "p0", "p01", "p-1", "p+1", "p1 ", "t1", "p999999999999999999999999999"] {
            try require(parse(packed(environment: ["SLATE_TERM_PANE_ID=\(value)"])) == nil, "invalid pane accepted: \(value)")
        }
        try require(parse(packed(environment: ["SLATE_TERM_PANE_ID=p1", "SLATE_TERM_PANE_ID=p2"])) == nil, "duplicate pane key accepted")
        try require(parse(packed(argc: -1, environment: ["SLATE_TERM_PANE_ID=p1"])) == nil, "negative argc accepted")
        try require(parse(packed(argc: Int32.max, environment: ["SLATE_TERM_PANE_ID=p1"])) == nil, "unbounded argc accepted")
        try require(parse([1, 0]) == nil, "short argc accepted")
        try require(parse(packed(environment: ["SLATE_TERM_PANE_ID=p1"], terminated: false)) == nil, "unterminated environment accepted")
        var malformed = packed(environment: ["SLATE_TERM_PANE_ID=p1", "BAD="])
        malformed.removeLast(2)
        malformed += [0xff, 0] // No final environment terminator.
        try require(parse(malformed) == nil, "partial buffer returned an early pane match")
        let complete = packed(environment: ["SLATE_TERM_PANE_ID=p1", "UNRELATED=still-not-retained"])
        for length in 0..<complete.count {
            try require(parse(Array(complete.prefix(length))) == nil, "truncated procargs accepted at byte \(length)")
        }
        try require(parse(packed(environment: ["SLATE_TERM_PANE_ID=p\(Int.max)"])) == PaneID(Int.max), "maximum canonical ID rejected")
        try require(parse([UInt8](repeating: 0, count: 262_145)) == nil, "procargs byte bound ignored")
        print("PASS bounded procargs parsing: argv/padding, canonical IDs, duplicates, all truncations and byte limit")
    }

    static func runShell() throws {
        guard setsid() > 0, ioctl(STDIN_FILENO, TIOCSCTTY, 0) == 0,
              tcsetpgrp(STDIN_FILENO, getpid()) == 0 else { throw Failure(message: "fixture controlling PTY: \(errno)") }
        writeReady()
        // Canonical tty input: consume exactly one launch line, not the following shell commands.
        var byte: UInt8 = 0
        repeat {
            guard Darwin.read(STDIN_FILENO, &byte, 1) == 1 else { throw Failure(message: "fixture launch input") }
        } while byte != 10
        let arguments: [String] = ["sh", "-i"]
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        // Exact environment from spawn, with a private empty HOME and ENV=/dev/null.
        argv.withUnsafeBufferPointer { args in
            _ = execv("/bin/sh", args.baseAddress!)
        }
        throw Failure(message: "fixture exec: \(errno)")
    }

    static func writeReady() {
        let ready = Array("owned-ready\n".utf8)
        _ = ready.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress!, $0.count) }
    }

    static func eventually(_ label: String, timeout: Double = 3, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw Failure(message: "timeout: \(label)") }
            usleep(10_000)
        }
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func kernelName(_ pid: pid_t) throws -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { throw Failure(message: "fixture proc_name") }
        return String(cString: buffer)
    }

    static func descriptorCount() -> Int {
        (3..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }

    struct Failure: Error { let message: String }
}

/// Private PTY, direct child, exact environment. No user terminal or startup files touched.
@MainActor
private final class PTYShell {
    let pid: pid_t
    let master: Int32
    private var closed = false

    init(pane: String?, home: String, mode: String = "pty-shell") throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 1024)
        guard openpty(&master, &slave, &name, nil, nil) == 0 else { throw ProcessTitles.Failure(message: "openpty: \(errno)") }
        self.master = master
        defer { Darwin.close(slave) }
        var keepMaster = false
        defer { if !keepMaster { Darwin.close(master) } }
        guard fcntl(master, F_SETFL, O_NONBLOCK) == 0,
              fcntl(master, F_SETFD, FD_CLOEXEC) == 0 else { throw ProcessTitles.Failure(message: "PTY flags") }
        var actions: posix_spawn_file_actions_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Reopen in the helper so it can acquire this tty only after setsid().
        try Self.check(posix_spawn_file_actions_addopen(&actions, 0, &name, O_RDWR | O_NOCTTY, 0))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, 0, 1))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, 0, 2))
        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let args = [executable, mode].map { strdup($0) } + [nil]
        defer { args.forEach { free($0) } }
        var environment = ["HOME=\(home)", "ENV=/dev/null", "PATH=/usr/bin:/bin", "PS1=", "TERM=dumb"]
        if let pane { environment.append("SLATE_TERM_PANE_ID=\(pane)") }
        let env = environment.map { strdup($0) } + [nil]
        defer { env.forEach { free($0) } }
        var child: pid_t = 0
        let result = args.withUnsafeBufferPointer { args in
            env.withUnsafeBufferPointer { env in
                posix_spawn(&child, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        try Self.check(result)
        pid = child
        keepMaster = true
    }

    func send(_ text: String) throws {
        let data = Array(text.utf8)
        try data.withUnsafeBytes { bytes in
            guard Darwin.write(master, bytes.baseAddress!, bytes.count) == bytes.count else {
                throw ProcessTitles.Failure(message: "PTY write: \(errno)")
            }
        }
    }

    func drain() -> String {
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(master, &bytes, bytes.count)
        return count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
    }

    func close() {
        guard !closed else { return }
        closed = true
        // The unreaped owned leader pins its PID; this private tty pins its foreground group.
        let foreground = tcgetpgrp(master)
        if foreground > 1 && foreground != getpgrp() { _ = kill(-foreground, SIGKILL) }
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        // Release the tty before reaping: macOS can defer a killed reader's exit until this close.
        Darwin.close(master)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }

    isolated deinit { close() }

    private static func check(_ result: Int32) throws {
        if result != 0 { throw ProcessTitles.Failure(message: "spawn: \(result)") }
    }
}
