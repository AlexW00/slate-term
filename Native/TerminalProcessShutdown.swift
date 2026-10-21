import Darwin
import AppKit
import os

/// Ends only processes still attached to one verified, app-owned terminal session.
/// Keep Ghostty alive until completion so exit handlers can write their final output.
enum TerminalProcessShutdown {
    enum Status: String, Sendable {
        case stopped
        case deadlineExceeded
        case unverifiedOwnership
    }

    struct Outcome: Sendable {
        let status: Status
        let signalledProcessCount: Int
        let remainingProcessCount: Int
    }

    /// Completion is always asynchronous. Inspection and waits never block the main actor.
    static func stop(ttyPath: String?, foregroundPID: pid_t?,
                     interrupt: @escaping @MainActor @Sendable () -> Void,
                     completion: @escaping @MainActor @Sendable (Outcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = run(ttyPath: ttyPath, foregroundPID: foregroundPID, interrupt: interrupt)
            // Give the PTY reader and main-actor display callbacks time to consume final writes.
            Thread.sleep(forTimeInterval: 0.080)
            // AppKit can enter its termination loop from a main-queue callback.
            // A run-loop block can finish there without reentering that queue.
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated { completion(outcome) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private struct Identity: Hashable, Sendable {
        let pid: pid_t
        let seconds: Int
        let microseconds: Int32
    }

    private struct Process: Sendable {
        let identity: Identity
        let parent: pid_t
        let group: pid_t
        let session: pid_t
        let device: dev_t
        let terminalGroup: pid_t
    }

    private static let processLimit = 8192

    private static func run(ttyPath: String?, foregroundPID: pid_t?,
                            interrupt: @escaping @MainActor @Sendable () -> Void) -> Outcome {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_600_000_000
        guard let ttyPath, ttyPath.hasPrefix("/dev/"),
              let device = terminalDevice(ttyPath), let initial = processes(device: device, before: deadline) else {
            return Outcome(status: .unverifiedOwnership, signalledProcessCount: 0, remainingProcessCount: 0)
        }
        let leaders = initial.filter { $0.parent == getpid() && $0.identity.pid == $0.session && $0.device == device }
        guard leaders.count == 1, let leader = leaders.first else {
            return Outcome(status: .unverifiedOwnership, signalledProcessCount: 0, remainingProcessCount: 0)
        }
        let session = leader.session
        func attached(_ process: Process) -> Bool { process.session == session && process.device == device }
        var known = Dictionary(uniqueKeysWithValues: initial.filter(attached).map { ($0.identity, $0) })
        var signalled: Set<Identity> = []
        let foreground = initial.first { $0.identity.pid == foregroundPID && attached($0) }
        let foregroundGroup = foreground.flatMap { $0.group == leader.group ? nil : $0.group }
        let initialByPID = Dictionary(uniqueKeysWithValues: known.values.map { ($0.identity.pid, $0) })
        var ancestors: Set<Identity> = [leader.identity]
        var ancestor = foreground.flatMap { initialByPID[$0.parent] }
        while let parent = ancestor, ancestors.insert(parent.identity).inserted {
            ancestor = initialByPID[parent.parent]
        }

        // Raw-mode applications receive Ctrl-C as keyboard input, not a Unix signal.
        // Let the foreground job exit before stopping any of its helper processes.
        if let foreground, foregroundGroup != nil {
            interruptForeground(foreground, leader: leader, ttyPath: ttyPath,
                                before: min(deadline, DispatchTime.now().uptimeNanoseconds + 800_000_000),
                                interrupt: interrupt)
        }

        var stages: [Identity: (started: UInt64, duration: UInt64, signal: Int32)] = [:]
        while DispatchTime.now().uptimeNanoseconds < deadline {
            // Admit new children only while the original session leader still exists.
            if let current = process(leader.identity.pid), current.identity == leader.identity, attached(current),
               let sample = processes(device: device, before: deadline) {
                for member in sample where attached(member) { known[member.identity] = member }
            }
            for identity in Array(known.keys) {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
                guard let current = process(identity.pid), current.identity == identity, attached(current) else {
                    known.removeValue(forKey: identity)
                    continue
                }
                known[identity] = current
            }
            if known.isEmpty { break }
            let byPID = Dictionary(uniqueKeysWithValues: known.values.map { ($0.identity.pid, $0) })
            let parents = Set(known.values.map(\.parent))
            let workersRemain = known.keys.contains { !ancestors.contains($0) }
            // A parent stays alive until its children finish their exit handlers.
            // Keep the original caller shells alive when a graceful exit reparents helpers.
            // Otherwise a shell can exit login and revoke the helpers' terminal too early.
            let targets = known.values.filter {
                !parents.contains($0.identity.pid) && (!workersRemain || !ancestors.contains($0.identity))
                    && ($0.identity != leader.identity || known.count == 1)
            }.sorted {
                $0.group == foregroundGroup && $1.group != foregroundGroup
            }
            for target in targets {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { break }
                guard let current = process(target.identity.pid), current.identity == target.identity,
                      attached(current) else { continue }
                var stage = stages[target.identity]
                if stage == nil {
                    // Reserve time for the remaining ancestors without multiplying the total deadline.
                    var ancestor = byPID[current.parent]
                    var lineage: Set<pid_t> = [current.identity.pid]
                    while let parent = ancestor, lineage.insert(parent.identity.pid).inserted {
                        ancestor = byPID[parent.parent]
                    }
                    let duration = max(1, min(700_000_000, (deadline - now) / UInt64(lineage.count)))
                    stage = (started: now, duration: duration, signal: 0)
                }
                var progress = stage!
                let elapsed = now - progress.started
                let signal: Int32 = elapsed < progress.duration * 3 / 7 ? SIGHUP
                    : (elapsed < progress.duration * 11 / 14 ? SIGTERM : SIGKILL)
                guard progress.signal != signal else { continue }
                progress.signal = signal
                stages[target.identity] = progress
                if kill(current.identity.pid, signal) == 0 { signalled.insert(current.identity) }
                // Stopped jobs cannot run their HUP/TERM handlers until continued.
                if signal != SIGKILL, let final = process(current.identity.pid),
                   final.identity == current.identity, attached(final) { _ = kill(final.identity.pid, SIGCONT) }
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        // Keep the last unresolved count when the deadline expires; never extend it for a final scan.
        let remaining = known.count
        return Outcome(status: remaining == 0 ? .stopped : .deadlineExceeded,
                       signalledProcessCount: signalled.count, remainingProcessCount: remaining)
    }

    private static func interruptForeground(_ foreground: Process, leader: Process, ttyPath: String,
                                            before deadline: UInt64,
                                            interrupt: @escaping @MainActor @Sendable () -> Void) {
        let inputMode = terminalInputMode(ttyPath, device: leader.device)
        let firstDelivery = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
        var attempts = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard stillForeground(foreground, leader: leader) else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let retryReady: Bool = firstDelivery.withLock { delivery in
                guard let deliveredAt = delivery else { return false }
                return now >= deliveredAt && now - deliveredAt >= 250_000_000
            }
            if attempts == 0 || (attempts == 1 && retryReady) {
                let retry = attempts > 0
                attempts += 1
                RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                    // A queued tap must never reach a replacement job or a returned shell prompt.
                    guard DispatchTime.now().uptimeNanoseconds < deadline,
                          stillForeground(foreground, leader: leader) else { return }
                    // Applications restore terminal modes before printing their exit summary.
                    // Another Ctrl-C then becomes SIGINT and can kill that cleanup midway.
                    guard !retry || (inputMode != nil && terminalInputMode(ttyPath, device: leader.device) == inputMode) else { return }
                    MainActor.assumeIsolated { interrupt() }
                    // Measure from delivery so a busy main loop cannot bunch both taps together.
                    if !retry { firstDelivery.withLock { $0 = DispatchTime.now().uptimeNanoseconds } }
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
    }

    private static func terminalInputMode(_ path: String, device: dev_t) -> tcflag_t? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        var attributes = termios()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFCHR, info.st_rdev == device,
              tcgetattr(fd, &attributes) == 0 else { return nil }
        return attributes.c_lflag & tcflag_t(ICANON | ISIG | ECHO)
    }

    private static func stillForeground(_ foreground: Process, leader: Process) -> Bool {
        guard let currentLeader = process(leader.identity.pid), currentLeader.identity == leader.identity,
              currentLeader.session == leader.session, currentLeader.device == leader.device,
              let current = process(foreground.identity.pid), current.identity == foreground.identity,
              current.session == leader.session, current.device == leader.device,
              current.group == foreground.group else { return false }
        // tcgetpgrp on the slave fails outside its controlling session on macOS.
        // Kernel process metadata provides the same terminal foreground group.
        return current.terminalGroup == foreground.group
    }

    private static func terminalDevice(_ path: String) -> dev_t? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFCHR else { return nil }
        return info.st_rdev
    }

    private static func processes(device: dev_t, before deadline: UInt64) -> [Process]? {
        var pids = [pid_t](repeating: 0, count: processLimit + 1)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_TTY_ONLY), UInt32(bitPattern: device), $0.baseAddress, Int32($0.count))
        }
        guard bytes >= 0, Int(bytes) % MemoryLayout<pid_t>.size == 0 else { return nil }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        guard count <= processLimit else { return nil }
        var result: [Process] = []
        for pid in pids.prefix(count) where pid > 1 {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
            if let info = process(pid) { result.append(info) }
        }
        return result
    }

    private static func process(_ pid: pid_t) -> Process? {
        // Basic metadata remains readable for the privileged macOS login parent.
        // Unlike procargs, it contains neither arguments nor environment values.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 1, pid != getpid(),
              sysctl(&mib, 4, &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.size,
              info.kp_proc.p_pid == pid, info.kp_proc.p_stat != SZOMB,
              info.kp_proc.p_un.__p_starttime.tv_sec > 0 else { return nil }
        let session = getsid(pid)
        guard session > 1 else { return nil }
        return Process(identity: Identity(pid: pid, seconds: info.kp_proc.p_un.__p_starttime.tv_sec,
                                          microseconds: info.kp_proc.p_un.__p_starttime.tv_usec),
                       parent: info.kp_eproc.e_ppid, group: info.kp_eproc.e_pgid,
                       session: session, device: info.kp_eproc.e_tdev, terminalGroup: info.kp_eproc.e_tpgid)
    }
}
