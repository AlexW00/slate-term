import ArgumentParser
import Darwin
import Dispatch
import Foundation
import SlateTermCore

/// Private process-group leader. The service inherits this group, so both normal
/// host teardown and a SIGKILL of the host can remove all non-daemonizing children.
/// Service stdout/stderr pass through unchanged; its exit status is also logged.
struct PluginWorker: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_plugin-worker", shouldDisplay: false)
    @Option var parentPid: Int32
    @Option var exitStatusFile: String?
    @Argument(parsing: .unconditionalRemaining) var command: [String] = []

    func run() throws {
        guard parentPid > 1, getppid() == parentPid, getpgrp() == getpid(),
              let executable = command.first, executable.hasPrefix("/"),
              command.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw ValidationError("Plugin worker must be launched in its own group by its live parent")
        }
        // TERM reaches the service directly. Keep the group leader alive until
        // cleanup; an ignored SIGPIPE also prevents a closed log pipe skipping it.
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN); signal(SIGPIPE, SIG_IGN)
        let child = try spawn(executable: executable)
        let parentSource = DispatchSource.makeProcessSource(identifier: parentPid, eventMask: .exit, queue: .main)
        parentSource.setEventHandler { Self.killOwnedGroup() }
        let childSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .main)
        childSource.setEventHandler {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(child, &status, WNOHANG) } while result < 0 && errno == EINTR
            let description = result == child ? ((status & 0x7f) == 0 ? "code=\((status >> 8) & 0xff)" : "signal=\(status & 0x7f)") : "unavailable"
            if exitStatusFile == nil {
                try? FileHandle.standardError.write(contentsOf: Data("\nSlate plugin service exited: \(description)\n".utf8))
            }
            if let exitStatusFile, result == child {
                let signal = status & 0x7f
                let exit = PluginCommandExit(exitCode: signal == 0 ? Int((status >> 8) & 0xff) : nil,
                                             signal: signal == 0 ? nil : Int(signal))
                try? JSONEncoder().encode(exit).write(to: URL(fileURLWithPath: exitStatusFile), options: [.atomic])
            }
            Self.killOwnedGroup()
        }
        parentSource.resume(); childSource.resume()
        // Close the race between the initial parent check and kqueue registration.
        if getppid() != parentPid { Self.killOwnedGroup() }
        withExtendedLifetime((parentSource, childSource)) { dispatchMain() }
    }

    private static func killOwnedGroup() -> Never {
        let group = getpgrp()
        guard group == getpid(), group > 1 else { _exit(125) }
        // Our live PID pins the group identity. Never schedule another signal
        // after relinquishing it, and never accept a caller-supplied target group.
        _ = kill(-group, SIGKILL)
        _exit(125)
    }

    private func spawn(executable: String) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), operation: "worker file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            try check(posix_spawn_file_actions_adddup2(&actions, fd, fd), operation: "worker stdio")
        }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), operation: "worker attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setpgroup(&attributes, getpgrp()), operation: "worker inherited group")
        var empty = sigset_t(), defaults = sigset_t()
        sigemptyset(&empty); sigfillset(&defaults)
        try check(posix_spawnattr_setsigmask(&attributes, &empty), operation: "worker signal mask")
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults), operation: "worker signal defaults")
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), operation: "worker flags")
        let arguments = try strings(command)
        defer { arguments.forEach { free($0) } }
        let environment = try strings(ProcessInfo.processInfo.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        defer { environment.forEach { free($0) } }
        var pid: pid_t = 0
        let result = arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { envp in
                posix_spawn(&pid, executable, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
            }
        }
        try check(result, operation: "worker posix_spawn")
        return pid
    }
    private func check(_ code: Int32, operation: String) throws {
        guard code == 0 else { throw ValidationError("\(operation): \(String(cString: strerror(code)))") }
    }
    private func strings(_ values: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for value in values {
            guard let pointer = strdup(value) else {
                pointers.forEach { free($0) }
                throw ValidationError("Unable to allocate plugin arguments")
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }
}
