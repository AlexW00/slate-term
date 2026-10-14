import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible, Sendable {
    case system(String, Int32)
    case invalidPath
    case insecureDirectory
    case disconnected
    case invalidResponse
    case invalidTimeout

    public var description: String {
        switch self {
        case .system(let operation, let code): "\(operation): \(String(cString: strerror(code)))"
        case .invalidPath: "Unix socket path is too long or contains a NUL byte"
        case .insecureDirectory: "Socket directory must be owned by this user, not a symlink, and have mode 0700"
        case .disconnected: "Control connection closed"
        case .invalidResponse: "Invalid control response"
        case .invalidTimeout: "Socket timeout must be between 1 and 300 seconds"
        }
    }
}

func withSocketAddress<T>(_ path: String, body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw SocketError.invalidPath
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

func makeSocket(nonblocking: Bool) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SocketError.system("socket", errno) }
    var noSignal: Int32 = 1
    guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
          setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0,
          !nonblocking || fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
        let error = SocketError.system("socket options", errno)
        Darwin.close(descriptor)
        throw error
    }
    return descriptor
}
