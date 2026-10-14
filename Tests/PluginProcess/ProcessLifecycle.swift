import Darwin
import Foundation

@main
struct ProcessLifecycle {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.count > 1 {
            try runFixture(CommandLine.arguments[1])
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-plugin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path

        let output = try PluginProcess(executable: "/bin/sh", arguments: ["-c", "printf '%s:%s' \"$PWD\" \"$PLUGIN_TEST\"; printf err >&2; read x || exit 7"], directory: root, environment: ["PLUGIN_TEST": "isolated"])
        var chunks: [String: Data] = [:]
        var exits: [PluginProcess.ExitStatus] = []
        output.onOutput = { stream, data in chunks[stream, default: Data()].append(data) }
        output.onExit = { exits.append($0) }
        try await eventually("output exit") { output.state == .exited(.code(7)) }
        try require(String(decoding: output.stdoutTail, as: UTF8.self).hasSuffix(":isolated"), "cwd/environment/stdout")
        try require(output.stderrTail == Data("err".utf8), "stderr retained")
        try require(chunks["stdout"] == output.stdoutTail && chunks["stderr"] == output.stderrTail, "output callbacks")
        try require(exits == [.code(7)], "one exit callback")
        try require(output.lastIOError == nil, "EOF drain used a canceled descriptor")
        var status: Int32 = 0
        try require(waitpid(output.pid, &status, WNOHANG) == -1 && errno == ECHILD, "leader reaped")
        await output.stop()
        output.close()
        try require(exits.count == 1, "no duplicate exit")
        print("PASS output, exit status, cwd, environment, stdin, callbacks and reaping")

        let descriptorsBefore = descriptorCount()
        for _ in 0..<30 {
            try expectFailure { try PluginProcess(executable: "/not/a/plugin", arguments: [], directory: nil, environment: [:]) }
            try expectFailure { try PluginProcess(executable: "/bin/sh", arguments: ["bad\0arg"], directory: nil, environment: [:]) }
            try expectFailure { try PluginProcess(executable: "/bin/sh", arguments: [], directory: root.appendingPathComponent("missing"), environment: [:]) }
            try expectFailure { try PluginProcess(executable: "/bin/sh", arguments: [], directory: nil, environment: ["BAD=KEY": "x"]) }
        }
        let invalid = root.appendingPathComponent("invalid-executable")
        try Data("not an executable format\n".utf8).write(to: invalid)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: invalid.path)
        for _ in 0..<30 {
            try expectFailure { try PluginProcess(executable: invalid.path, arguments: [], directory: nil, environment: [:]) }
        }
        try require(descriptorCount() <= descriptorsBefore + 2, "failed spawn leaked descriptors")
        print("PASS validation and failed spawn cleanup")

        let unrelated = try PluginProcess(executable: executable, arguments: ["ignore-term"], directory: nil, environment: [:])
        defer { unrelated.close() }
        try await eventually("unrelated ready") { !unrelated.stdoutTail.isEmpty }
        let stubborn = try PluginProcess(executable: executable, arguments: ["ignore-term"], directory: nil, environment: [:])
        defer { stubborn.close() }
        try await eventually("stubborn ready") { !stubborn.stdoutTail.isEmpty }
        let start = ContinuousClock.now
        async let stopOne: Void = stubborn.stop()
        async let stopTwo: Void = stubborn.stop()
        _ = await (stopOne, stopTwo)
        try require(start.duration(to: .now) < .seconds(2), "stop exceeded bound")
        try require(stubborn.state == .exited(.signal(SIGKILL)), "TERM-ignoring escalation")
        try require(unrelated.state == .running && kill(unrelated.pid, 0) == 0, "unrelated process touched")
        print("PASS bounded concurrent stop, escalation, unrelated process untouched")

        let graceful = try PluginProcess(executable: "/bin/sleep", arguments: ["60"], directory: nil, environment: [:])
        await graceful.stop()
        try require(graceful.state == .exited(.signal(SIGTERM)), "graceful TERM status")
        let canceled = try PluginProcess(executable: executable, arguments: ["ignore-term"], directory: nil, environment: [:])
        try await eventually("cancellation ready") { !canceled.stdoutTail.isEmpty }
        let canceledStop = Task { await canceled.stop() }
        canceledStop.cancel()
        await canceledStop.value
        try require(canceled.state == .exited(.signal(SIGKILL)), "cancellation abandoned teardown")
        print("PASS graceful stop and canceled stop still cleans up")

        let grandchildFile = root.appendingPathComponent("grandchild")
        let tree = try PluginProcess(executable: executable, arguments: ["leader-exits", grandchildFile.path], directory: nil, environment: [:])
        defer { tree.close() }
        try await eventually("leader exited") { tree.state == .exited(.code(0)) }
        let childPID = try readPID(grandchildFile)
        try await eventually("surviving grandchild killed") { !isLive(childPID) }
        try require(unrelated.state == .running && kill(unrelated.pid, 0) == 0, "unrelated group touched after leader exit")
        print("PASS grandchild cleanup after leader exits")

        let flood = try PluginProcess(executable: executable, arguments: ["flood"], directory: nil, environment: [:])
        var stdoutBytes = 0
        var stderrBytes = 0
        flood.onOutput = { stream, data in
            if stream == "stdout" { stdoutBytes += data.count } else { stderrBytes += data.count }
            precondition(flood.stdoutTail.count <= PluginProcess.outputTailLimitBytes)
            precondition(flood.stderrTail.count <= PluginProcess.outputTailLimitBytes)
        }
        try await eventually("flood exit") { flood.state == .exited(.code(0)) }
        flood.onOutput = nil
        try require(stdoutBytes == 1_048_580 && stderrBytes == 1_048_580, "flood output lost")
        try require(flood.stdoutTail.count == PluginProcess.outputTailLimitBytes && flood.stderrTail.count == PluginProcess.outputTailLimitBytes, "retained bounds")
        try require(flood.stdoutTail.suffix(4) == Data("DONE".utf8), "tail is newest data")
        try require(flood.lastIOError == nil, "flood I/O error")
        print("PASS bounded output retention and complete streaming")

        let closed = try PluginProcess(executable: executable, arguments: ["ignore-term"], directory: nil, environment: [:])
        try await eventually("close ready") { !closed.stdoutTail.isEmpty }
        var closeCallbacks = 0
        closed.onExit = { _ in closeCallbacks += 1 }
        closed.close()
        closed.close()
        try require(closed.state == .closed, "close state")
        try await eventually("close killed") { !isLive(closed.pid) }
        try require(closeCallbacks == 0, "closed process callbacks")
        var destroyed: PluginProcess? = try PluginProcess(executable: executable, arguments: ["ignore-term"], directory: nil, environment: [:])
        let destroyedPID = destroyed!.pid
        try await eventually("deinit ready") { !destroyed!.stdoutTail.isEmpty }
        weak let weakProcess = destroyed
        destroyed = nil
        try require(weakProcess == nil, "source retained owner")
        try await eventually("deinit killed") { !isLive(destroyedPID) }
        print("PASS synchronous close and destruction")

        let reentrant = try PluginProcess(executable: "/bin/sh", arguments: ["-c", "printf ready; exec /bin/sleep 60"], directory: nil, environment: [:])
        var reentrantOutputs = 0
        var reentrantExits = 0
        reentrant.onExit = { _ in reentrantExits += 1 }
        reentrant.onOutput = { _, _ in
            reentrantOutputs += 1
            reentrant.close()
        }
        try await eventually("reentrant close") { reentrant.state == .closed && !isLive(reentrant.pid) }
        try require(reentrantOutputs == 1 && reentrantExits == 0, "callbacks continued after reentrant close")
        print("PASS reentrant callback teardown")

        // No main-loop turn occurs after teardown in either owned helper process.
        for mode in ["close-without-runloop", "deinit-without-runloop"] {
            let synchronousFile = root.appendingPathComponent(mode)
            let synchronous = try PluginProcess(executable: executable, arguments: [mode, synchronousFile.path], directory: nil, environment: [:])
            try await eventually("synchronous helper exit") { synchronous.state == .exited(.code(0)) }
            let synchronousPID = try readPID(synchronousFile)
            try await eventually("synchronous teardown killed group") { !isLive(synchronousPID) }
        }
        print("PASS close and deinit without a later runloop turn")
        try await eventually("descriptors released") { descriptorCount() <= descriptorsBefore + 2 }
        print("PASS canceled sources release descriptors")
        print("PASS all plugin process lifecycle checks")
    }

    @MainActor
    static func eventually(_ label: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { throw Failure(message: "timeout: \(label)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    @MainActor
    static func expectFailure(_ make: () throws -> PluginProcess) throws {
        do {
            let process = try make()
            process.close()
        } catch { return }
        throw Failure(message: "invalid spawn succeeded")
    }

    static func descriptorCount() -> Int {
        (3..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }

    static func readPID(_ url: URL) throws -> pid_t {
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(text), pid > 1 else { throw Failure(message: "invalid fixture pid") }
        return pid
    }

    static func isLive(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return result == size && info.pbi_status != UInt32(SZOMB)
    }

    @MainActor
    static func runFixture(_ mode: String) throws {
        switch mode {
        case "ignore-term":
            signal(SIGTERM, SIG_IGN)
            writeAll(STDOUT_FILENO, Data("ready\n".utf8))
            while true { pause() }
        case "leader-exits":
            // No SETPGROUP flag: this fixture child deliberately inherits the owned group.
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            let argv = [executable, "ignore-term"].map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            var environment: [UnsafeMutablePointer<CChar>?] = [nil]
            var child: pid_t = 0
            let result = argv.withUnsafeBufferPointer { args in
                posix_spawn(&child, executable, nil, nil, args.baseAddress!, &environment)
            }
            guard result == 0 else { throw Failure(message: "fixture spawn: \(result)") }
            try Data("\(child)".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            // Child remains in our group and keeps the output pipes open.
            _exit(0)
        case "flood":
            let block = Data(repeating: 65, count: 8192)
            for _ in 0..<128 {
                writeAll(STDOUT_FILENO, block)
                writeAll(STDERR_FILENO, block)
            }
            writeAll(STDOUT_FILENO, Data("DONE".utf8))
            writeAll(STDERR_FILENO, Data("DONE".utf8))
        case "close-without-runloop", "deinit-without-runloop":
            var child: PluginProcess? = try PluginProcess(executable: "/bin/sleep", arguments: ["60"], directory: nil, environment: [:])
            try Data("\(child!.pid)".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            if mode == "close-without-runloop" { child!.close() } else { child = nil }
            _exit(0)
        default: throw Failure(message: "unknown fixture")
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                precondition(count > 0)
                offset += count
            }
        }
    }

    struct Failure: Error { let message: String }
}
