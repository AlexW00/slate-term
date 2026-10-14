import Darwin
import Foundation

/// A readiness response alone cannot authenticate a loopback server: another
/// process may occupy its port. Inspect only the owned group and require its
/// IPv4 TCP listener before loading a managed plugin or accepting bridge calls.
enum PluginListener {
    /// Reserve an ephemeral loopback port, then release it for the service. A
    /// subsequent ownership check fails closed if another process wins the race.
    static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let queried = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard queried == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return address.sin_port.bigEndian
    }

    static func owns(port: UInt16, group: pid_t) -> Bool {
        guard group > 1, getpgid(group) == group else { return false }
        var members = [pid_t](repeating: 0, count: 64)
        let bytes = Int32(members.count * MemoryLayout<pid_t>.stride)
        guard proc_listpgrppids(group, &members, bytes) > 0 else { return false }
        for pid in members where pid > 1 && getpgid(pid) == group {
            var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 512)
            let capacity = Int32(descriptors.count * MemoryLayout<proc_fdinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, capacity) > 0 else { continue }
            for descriptor in descriptors where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
                var socket = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                      socket.psi.soi_family == AF_INET, socket.psi.soi_kind == SOCKINFO_TCP else { continue }
                let tcp = socket.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN,
                      UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport).bigEndian == port else { continue }
                let address = tcp.tcpsi_ini.insi_laddr.ina_46.i46a_addr4.s_addr
                if address == inet_addr("127.0.0.1") || address == INADDR_ANY { return true }
            }
        }
        return false
    }
}
