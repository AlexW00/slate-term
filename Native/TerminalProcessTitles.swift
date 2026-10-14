import Darwin
import SlateTermCore

/// Caller-owned sampling (normally every 500 ms); no timer, subprocess, or shell integration.
/// Direct children are attributed by a canonical SLATE_TERM_PANE_ID or an
/// authenticated shell binding. SIP-redacted, unbound children remain unknown.
@MainActor
final class TerminalProcessTitles {
    // Fixed bounds keep both kernel copies and main-actor work finite. Oversized samples fail closed.
    private static let childLimit = 128
    private static let procargsLimitBytes = 262_144
    private var paneByChild: [ProcessIdentity: PaneID] = [:]

    init() {}

    /// Token-authenticated reports identify the shell, but macOS login remains
    /// its parent. Attribute that owned ancestor: it shares the foreground TTY
    /// and remains pinned across commands without reading SIP-redacted env data.
    func bind(pane: PaneID, pid: pid_t) {
        guard let shell = Self.processInfo(pid) else { return }
        var candidate = shell
        for _ in 0..<16 {
            if candidate.pbi_ppid == UInt32(getpid()) {
                guard let current = Self.processInfo(pid), ProcessIdentity(current) == ProcessIdentity(shell), current.pbi_ppid == shell.pbi_ppid,
                      let ancestor = Self.ownedChild(pid_t(candidate.pbi_pid)), ProcessIdentity(ancestor) == ProcessIdentity(candidate) else { return }
                paneByChild[ProcessIdentity(ancestor)] = pane
                return
            }
            guard candidate.pbi_ppid > 1, candidate.pbi_ppid <= UInt32(Int32.max),
                  let parent = Self.processInfo(pid_t(candidate.pbi_ppid)) else { return }
            candidate = parent
        }
    }

    func names(for panes: Set<PaneID>) -> [PaneID: String] {
        guard let children = Self.directChildren() else {
            paneByChild.removeAll()
            return [:]
        }
        var live: Set<ProcessIdentity> = []
        var names: [PaneID: String] = [:]
        var attributed: Set<PaneID> = []
        for pid in children {
            guard let child = Self.ownedChild(pid) else { continue }
            let identity = ProcessIdentity(child)
            live.insert(identity)
            guard !panes.isEmpty else { continue }
            let pane = paneByChild[identity] ?? Self.paneID(for: pid)
            guard let pane, panes.contains(pane),
                  let current = Self.ownedChild(pid), ProcessIdentity(current) == identity else { continue }
            paneByChild[identity] = pane
            // Multiple owned children claiming one pane are ambiguous, not an enumeration-order choice.
            guard attributed.insert(pane).inserted else {
                names.removeValue(forKey: pane)
                continue
            }
            let name = Self.foregroundName(for: current) ?? Self.name(of: current)
            guard let name, let final = Self.ownedChild(pid), ProcessIdentity(final) == identity else { continue }
            names[pane] = name
        }
        // Keep live identities across changes to the requested pane set, including empty samples.
        paneByChild = paneByChild.filter { live.contains($0.key) }
        return names
    }

    /// KERN_PROCARGS2: native argc, executable + NUL padding, argc NUL-terminated argv,
    /// then NUL-terminated environment entries and an empty terminator. Never decode other values.
    /// Internal for standalone parser regression tests; production buffers are erased after parsing.
    static func paneID(in procargs: UnsafeRawBufferPointer) -> PaneID? {
        guard procargs.count <= procargsLimitBytes, procargs.count > MemoryLayout<Int32>.size else { return nil }
        let argc = procargs.loadUnaligned(as: Int32.self)
        guard argc > 0, Int(argc) <= procargs.count - MemoryLayout<Int32>.size else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func nextString() -> Range<Int>? {
            let start = cursor
            while cursor < procargs.count && procargs[cursor] != 0 { cursor += 1 }
            guard cursor < procargs.count else { return nil }
            let range = start..<cursor
            cursor += 1
            return range
        }
        guard let executable = nextString(), !executable.isEmpty else { return nil }
        while cursor < procargs.count && procargs[cursor] == 0 { cursor += 1 }
        for _ in 0..<Int(argc) {
            guard nextString() != nil else { return nil }
        }
        let key = Array("SLATE_TERM_PANE_ID=".utf8)
        var pane: PaneID?
        while let entry = nextString() {
            if entry.isEmpty { return pane }
            guard entry.count >= key.count,
                  key.indices.allSatisfy({ procargs[entry.lowerBound + $0] == key[$0] }) else { continue }
            guard pane == nil else { return nil }
            let value = (entry.lowerBound + key.count)..<entry.upperBound
            guard value.count >= 2, value.count <= 20, procargs[value.lowerBound] == 112,
                  (49...57).contains(procargs[value.lowerBound + 1]) else { return nil } // canonical p[1-9][0-9]*
            var number = 0
            for index in (value.lowerBound + 1)..<value.upperBound {
                let byte = procargs[index]
                guard (48...57).contains(byte) else { return nil }
                let (scaled, multiplicationOverflow) = number.multipliedReportingOverflow(by: 10)
                let (next, additionOverflow) = scaled.addingReportingOverflow(Int(byte - 48))
                guard !multiplicationOverflow, !additionOverflow else { return nil }
                number = next
            }
            pane = PaneID(number)
        }
        return nil // A partial environment must not publish an earlier match.
    }

    private static func directChildren() -> [pid_t]? {
        var pids = [pid_t](repeating: 0, count: childLimit + 1)
        // Unlike proc_listpids, proc_listchildpids returns a PID count, not a byte count.
        let count = pids.withUnsafeMutableBytes { bytes in
            proc_listchildpids(getpid(), bytes.baseAddress, Int32(bytes.count))
        }
        guard count >= 0, count <= childLimit else { return nil }
        return Array(Set(pids.prefix(Int(count)).filter { $0 > 1 }))
    }

    private static func ownedChild(_ pid: pid_t) -> proc_bsdinfo? {
        guard let info = processInfo(pid), info.pbi_ppid == UInt32(getpid()) else { return nil }
        return info
    }

    private static func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1 else { return nil }
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) != size {
            // macOS login stays privileged while its shell runs: full libproc
            // data is denied even to its parent. Basic BSD process metadata is
            // public and supplies the same ownership/TTY/start identity checks.
            var kernel = kinfo_proc()
            var length = MemoryLayout<kinfo_proc>.size
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&mib, 4, &kernel, &length, nil, 0) == 0, length == MemoryLayout<kinfo_proc>.size,
                  kernel.kp_proc.p_pid == pid, kernel.kp_eproc.e_ppid >= 0, kernel.kp_eproc.e_pgid >= 0,
                  kernel.kp_proc.p_un.__p_starttime.tv_sec > 0, kernel.kp_proc.p_un.__p_starttime.tv_usec >= 0 else { return nil }
            info.pbi_pid = UInt32(pid)
            info.pbi_ppid = UInt32(kernel.kp_eproc.e_ppid)
            info.pbi_pgid = UInt32(kernel.kp_eproc.e_pgid)
            info.pbi_status = UInt32(kernel.kp_proc.p_stat)
            info.e_tdev = UInt32(bitPattern: kernel.kp_eproc.e_tdev)
            info.e_tpgid = UInt32(bitPattern: kernel.kp_eproc.e_tpgid)
            info.pbi_start_tvsec = UInt64(kernel.kp_proc.p_un.__p_starttime.tv_sec)
            info.pbi_start_tvusec = UInt64(kernel.kp_proc.p_un.__p_starttime.tv_usec)
        }
        guard info.pbi_pid == UInt32(pid), info.pbi_status != UInt32(SZOMB), info.pbi_start_tvsec != 0 else { return nil }
        return info
    }

    private static func paneID(for pid: pid_t) -> PaneID? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: procargsLimitBytes)
        // Kernel procargs necessarily contains other environment values transiently; never retain
        // or log them, and wipe the scratch allocation on success and every failure path.
        defer { buffer.withUnsafeMutableBytes { _ = memset_s($0.baseAddress!, $0.count, 0, $0.count) } }
        return buffer.withUnsafeMutableBytes { bytes in
            var size = bytes.count
            guard sysctl(&mib, UInt32(mib.count), bytes.baseAddress, &size, nil, 0) == 0,
                  size > 0, size <= bytes.count else { return nil }
            return paneID(in: UnsafeRawBufferPointer(rebasing: bytes[..<size]))
        }
    }

    private static func foregroundName(for child: proc_bsdinfo) -> String? {
        let group = child.e_tpgid
        guard child.e_tdev != UInt32.max, group > 1, group <= UInt32(Int32.max),
              let target = processInfo(pid_t(group)), target.pbi_pgid == group,
              target.e_tpgid == group, target.e_tdev == child.e_tdev,
              let name = name(of: target),
              let current = ownedChild(pid_t(child.pbi_pid)),
              ProcessIdentity(current) == ProcessIdentity(child),
              current.e_tpgid == group, current.e_tdev == child.e_tdev else { return nil }
        return name
    }

    private static func name(of process: proc_bsdinfo) -> String? {
        var buffer = [UInt8](repeating: 0, count: 128)
        let pid = pid_t(process.pbi_pid)
        let count = buffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0, count < buffer.count, let end = buffer.firstIndex(of: 0), end > 0,
              let current = processInfo(pid), ProcessIdentity(current) == ProcessIdentity(process),
              current.pbi_pgid == process.pbi_pgid, current.e_tdev == process.e_tdev,
              current.e_tpgid == process.e_tpgid else { return nil }
        return String(validating: buffer[..<end], as: UTF8.self)
    }

    private struct ProcessIdentity: Hashable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        init(_ info: proc_bsdinfo) {
            pid = pid_t(info.pbi_pid)
            startSeconds = info.pbi_start_tvsec
            startMicroseconds = info.pbi_start_tvusec
        }
    }
}
