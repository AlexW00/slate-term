import Darwin
import Dispatch
import Foundation

/// One executable and its process group, with no readiness or restart policy.
/// Descendants that daemonize (setsid/setpgid) escape this boundary and cannot be contained here.
/// Requires exclusive child-reaping ownership: no SIGCHLD auto-reap or external waitpid for this PID.
@MainActor
final class PluginProcess {
    enum State: Equatable, Sendable {
        case running
        case stopping
        case exited(ExitStatus)
        /// Immediate teardown suppresses callbacks; an outstanding reap may finish off-actor.
        case closed
    }

    enum ExitStatus: Equatable, Sendable {
        case code(Int32)
        case signal(Int32)
        /// A waitpid failure, not an invented successful exit.
        case unavailable(Int32)
    }

    struct LaunchError: Error, LocalizedError {
        let operation: String
        let code: Int32
        var errorDescription: String? { "\(operation): \(String(cString: strerror(code)))" }
    }

    static let outputTailLimitBytes = 65_536
    static let terminationGrace: Duration = .milliseconds(500)
    static let reapGrace: Duration = .milliseconds(500)

    let pid: pid_t
    private(set) var state: State = .running
    private(set) var stdoutTail = Data()
    private(set) var stderrTail = Data()
    private(set) var stdoutBytesReceived: UInt64 = 0
    private(set) var stderrBytesReceived: UInt64 = 0
    private(set) var lastIOError: String?
    /// "stdout" or "stderr", raw bytes; handlers run on the main actor.
    var onOutput: ((String, Data) -> Void)?
    /// Once, after group cleanup and leader reaping. Not emitted by close()/destruction.
    var onExit: ((ExitStatus) -> Void)?

    // The resource capsule also permits synchronous cleanup from Swift's nonisolated deinit.
    private let resources: ProcessResources
    /// Observation only: closing still suppresses callbacks and remains .closed.
    /// Confirmation means the exclusively owned leader was reaped after group teardown;
    /// it does not contain descendants that deliberately escaped that group.
    var cleanupObservation: ProcessCleanup { resources.reapObservation }
    var cleanupFinished: Bool { cleanupObservation.snapshot.finished }
    var cleanupConfirmed: Bool { cleanupObservation.snapshot.confirmed }
    private var stopDeadline: ContinuousClock.Instant?

    /// Requires an absolute executable path. Environment is exact, not merged with the host's.
    /// Arguments and environment must contain no NUL; keys must be nonempty and contain no '='.
    init(executable: String, arguments: [String], directory: URL?, environment: [String: String]) throws {
        try Self.validate(executable: executable, arguments: arguments, directory: directory, environment: environment)
        resources = try Self.spawn(executable: executable, arguments: arguments, directory: directory, environment: environment)
        pid = resources.pid
        installSources()
    }

    /// Idempotent, cancellation-independent teardown; returns within grace + reap grace (1 second),
    /// excluding main-actor scheduling delays. A stuck kernel exit becomes .closed, not .exited.
    func stop() async {
        guard state == .running || state == .stopping else { return }
        if state == .running {
            state = .stopping
            stopDeadline = .now.advanced(by: Self.terminationGrace)
            resources.signalGroup(SIGTERM, relinquish: false)
        }
        guard let deadline = stopDeadline else { return }
        while state == .stopping && ContinuousClock.now < deadline {
            await Self.yieldForCleanup()
        }
        guard state == .stopping else { return }
        resources.signalGroup(SIGKILL, relinquish: true)
        let reapDeadline = deadline.advanced(by: Self.reapGrace)
        while state == .stopping && ContinuousClock.now < reapDeadline {
            finishIfExited()
            if state == .stopping { await Self.yieldForCleanup() }
        }
        if state == .stopping { close() }
    }

    /// Sends SIGKILL to the owned group *now*, without waiting for dispatch or a later runloop turn.
    /// Suppresses future callbacks and delegates only the potentially blocking reap.
    func close() {
        guard state != .closed else { return }
        state = .closed
        onOutput = nil
        onExit = nil
        resources.close()
    }

    deinit { resources.close() }

    private static func validate(executable: String, arguments: [String], directory: URL?, environment: [String: String]) throws {
        guard executable.hasPrefix("/"), !executable.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw LaunchError(operation: "Invalid executable, argument or environment", code: EINVAL)
        }
        var info = stat()
        guard stat(executable, &info) == 0 else { throw LaunchError(operation: "stat executable", code: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw LaunchError(operation: "Executable is not a regular file", code: EACCES) }
        guard access(executable, X_OK) == 0 else { throw LaunchError(operation: "access executable", code: errno) }
        if let directory {
            guard directory.isFileURL, !directory.path.contains("\0") else { throw LaunchError(operation: "Invalid working directory", code: EINVAL) }
            guard stat(directory.path, &info) == 0 else { throw LaunchError(operation: "stat working directory", code: errno) }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw LaunchError(operation: "Working directory is not a directory", code: ENOTDIR) }
        }
    }

    private static func spawn(executable: String, arguments: [String], directory: URL?, environment: [String: String]) throws -> ProcessResources {
        let stdout = try makePipe()
        defer { Darwin.close(stdout.write) }
        var keepReads = false
        defer { if !keepReads { Darwin.close(stdout.read) } }
        let stderr = try makePipe()
        defer {
            Darwin.close(stderr.write)
            if !keepReads { Darwin.close(stderr.read) }
        }
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), "spawn file actions")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0), "spawn stdin")
        try check(posix_spawn_file_actions_adddup2(&actions, stdout.write, STDOUT_FILENO), "spawn stdout")
        try check(posix_spawn_file_actions_adddup2(&actions, stderr.write, STDERR_FILENO), "spawn stderr")
        if let directory {
            if #available(macOS 26.0, *) {
                try check(posix_spawn_file_actions_addchdir(&actions, directory.path), "spawn working directory")
            } else {
                try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path), "spawn working directory")
            }
        }
        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), "spawn attributes")
        defer { posix_spawnattr_destroy(&attributes) }
        // PGID 0 means the new child's PID, never the caller's group.
        try check(posix_spawnattr_setpgroup(&attributes, 0), "spawn process group")
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        try check(posix_spawnattr_setsigmask(&attributes, &emptyMask), "spawn signal mask")
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaultSignals), "spawn signal defaults")
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "spawn flags")
        let argv = try cStrings([executable] + arguments)
        defer { argv.forEach { free($0) } }
        let envp = try cStrings(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" })
        defer { envp.forEach { free($0) } }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&child, executable, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        try check(result, "posix_spawn \(executable)")
        keepReads = true
        return ProcessResources(pid: child, stdout: stdout.read, stderr: stderr.read)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw LaunchError(operation: "pipe", code: errno) }
        defer { descriptors.forEach { Darwin.close($0) } }
        // Keep action source descriptors away from 0/1/2, even if the host closed stdio.
        let readFD = fcntl(descriptors[0], F_DUPFD_CLOEXEC, 3)
        guard readFD >= 0 else { throw LaunchError(operation: "duplicate pipe read", code: errno) }
        let writeFD = fcntl(descriptors[1], F_DUPFD_CLOEXEC, 3)
        guard writeFD >= 0 else {
            let error = errno
            Darwin.close(readFD)
            throw LaunchError(operation: "duplicate pipe write", code: error)
        }
        guard fcntl(readFD, F_SETFL, O_NONBLOCK) == 0 else {
            let error = errno
            Darwin.close(readFD)
            Darwin.close(writeFD)
            throw LaunchError(operation: "nonblocking pipe", code: error)
        }
        return (readFD, writeFD)
    }

    private static func check(_ result: Int32, _ operation: String) throws {
        if result != 0 { throw LaunchError(operation: operation, code: result) }
    }

    private static func cStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                pointers.forEach { free($0) }
                throw LaunchError(operation: "allocate spawn strings", code: ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }

    private func installSources() {
        for (name, fd) in [("stdout", resources.stdout), ("stderr", resources.stderr)] {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.readOutput(name, fd: fd) }
            }
            // Cancellation is asynchronous. Closing here prevents queued reads touching a reused FD.
            source.setCancelHandler { Darwin.close(fd) }
            resources.readSources.append(source)
            source.resume()
        }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.finishIfExited() }
        }
        resources.exitSource = source
        source.resume()
    }

    static func yieldForCleanup() async {
        // Unlike Task.sleep this does not turn cancellation into a tight loop or abandoned teardown.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { continuation.resume() }
        }
    }

    private func finishIfExited() {
        guard state == .running || state == .stopping else { return }
        // WNOWAIT observes death without relinquishing the PID. Kill descendants before waitpid.
        var info = siginfo_t()
        let result = waitid(P_PID, UInt32(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result < 0 {
            let error = errno
            if error == EINTR { return }
            lastIOError = "waitid: \(String(cString: strerror(error)))"
            if error == ECHILD {
                // An external SIGCHLD handler/reaper violated exclusive wait ownership.
                // The ID is no longer pinned: never signal it, even during later close().
                resources.abandonOwnership()
                resources.cancelSources()
                state = .exited(.unavailable(error))
                let callback = onExit
                onExit = nil
                callback?(.unavailable(error))
            }
            return
        }
        guard info.si_pid == pid else { return }
        resources.signalGroup(SIGKILL, relinquish: true)
        guard let status = resources.reapNonblocking() else { return }
        readOutput("stdout", fd: resources.stdout)
        readOutput("stderr", fd: resources.stderr)
        // Output handlers may synchronously close the process.
        guard state != .closed else { return }
        resources.cancelSources()
        state = .exited(status)
        let callback = onExit
        onExit = nil
        callback?(status)
    }

    private func readOutput(_ stream: String, fd: Int32) {
        guard state == .running || state == .stopping,
              !resources.readSources[stream == "stdout" ? 0 : 1].isCancelled else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        // Bound each main-actor turn even if a plugin writes continuously.
        var remaining = 262_144
        while remaining > 0 && state != .closed {
            let count = Darwin.read(fd, &buffer, min(buffer.count, remaining))
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    lastIOError = "\(stream): \(String(cString: strerror(errno)))"
                    cancelReadSource(stream)
                }
                return
            }
            if count == 0 { cancelReadSource(stream); return }
            let data = Data(buffer.prefix(count))
            remaining -= count
            if stream == "stdout" {
                stdoutBytesReceived += UInt64(count)
                Self.appendTail(data, to: &stdoutTail)
            } else {
                stderrBytesReceived += UInt64(count)
                Self.appendTail(data, to: &stderrTail)
            }
            onOutput?(stream, data)
        }
    }

    private func cancelReadSource(_ stream: String) {
        resources.readSources[stream == "stdout" ? 0 : 1].cancel()
    }

    private static func appendTail(_ data: Data, to tail: inout Data) {
        tail.append(data)
        if tail.count > outputTailLimitBytes { tail.removeFirst(tail.count - outputTailLimitBytes) }
    }
}

/// The only data shared with the blocking reap worker. Never signals or owns a PID.
nonisolated final class ProcessCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var confirmed = false
    var snapshot: (finished: Bool, confirmed: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (finished, confirmed)
    }
    fileprivate func complete(confirmed: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        self.confirmed = confirmed
        finished = true
    }
}

/// Accessed on the main actor while its owner is alive. After destruction only close() is called.
/// Dispatch cancellation handlers capture FDs; the reap worker captures only PID and observation.
/// Explicitly nonisolated preserves synchronous destruction even in a default-MainActor module.
private nonisolated final class ProcessResources: @unchecked Sendable {
    let pid: pid_t
    let stdout: Int32
    let stderr: Int32
    var readSources: [DispatchSourceRead] = []
    var exitSource: DispatchSourceProcess?
    private var ownsGroup = true
    private var ownsReap = true
    let reapObservation = ProcessCleanup()

    init(pid: pid_t, stdout: Int32, stderr: Int32) {
        self.pid = pid
        self.stdout = stdout
        self.stderr = stderr
    }

    func close() {
        signalGroup(SIGKILL, relinquish: true)
        cancelSources()
        guard ownsReap else { return }
        if reapNonblocking() != nil { return }
        ownsReap = false
        let child = pid
        let observation = reapObservation
        // Never signal from this worker: the group was relinquished synchronously above.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(child, &status, 0) } while result < 0 && errno == EINTR
            observation.complete(confirmed: result == child)
        }
    }

    func signalGroup(_ signal: Int32, relinquish: Bool) {
        guard ownsGroup else { return }
        precondition(pid > 1)
        // The unreaped leader pins this ID, including when it is already a zombie.
        _ = kill(-pid, signal)
        if relinquish { ownsGroup = false }
    }

    func abandonOwnership() {
        ownsGroup = false
        ownsReap = false
        reapObservation.complete(confirmed: false)
    }

    func reapNonblocking() -> PluginProcess.ExitStatus? {
        guard ownsReap else { return nil }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        if result == 0 { return nil }
        let error = errno
        ownsReap = false
        reapObservation.complete(confirmed: result == pid)
        if result < 0 { return .unavailable(error) }
        let signal = status & 0x7f
        return signal == 0 ? .code((status >> 8) & 0xff) : .signal(signal)
    }

    func cancelSources() {
        readSources.forEach { $0.cancel() }
        exitSource?.cancel()
    }
}
