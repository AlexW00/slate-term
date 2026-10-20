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

// Darwin limits socket addresses even when the containing state directory is valid.
@MainActor
final class SocketEndpoint {
    let path: String
    private let temporaryDirectory: String?
    private let reference: URL?
    private var published = false

    init(directory: URL) throws {
        let name = String(UUID().uuidString.prefix(8))
        let preferred = directory.appendingPathComponent(name + ".sock").path
        guard !preferred.utf8.contains(0) else { throw SocketError.invalidPath }
        if preferred.utf8.count + 1 <= MemoryLayout.size(ofValue: sockaddr_un().sun_path) {
            path = preferred
            temporaryDirectory = nil
            reference = nil
        } else {
            // mkdtemp creates an exclusive private directory, independent of home-path length.
            var template = Array("/tmp/slate-ipc-XXXXXX".utf8CString)
            guard let result = mkdtemp(&template) else { throw SocketError.system("mkdtemp", errno) }
            let temporary = String(cString: result)
            path = temporary + "/" + name + ".sock"
            temporaryDirectory = temporary
            reference = directory.appendingPathComponent(name + ".socket-path")
        }
    }

    func publish() throws {
        guard let reference else { return }
        let staged = reference.path + ".tmp"
        let descriptor = open(staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SocketError.system("socket reference", errno) }
        defer { Darwin.close(descriptor); unlink(staged) }
        let data = Data((path + "\n").utf8)
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count else { throw SocketError.system("socket reference write", count < 0 ? errno : EIO) }
        guard link(staged, reference.path) == 0 else { throw SocketError.system("socket reference publication", errno) }
        published = true
    }

    func cleanup() {
        if published, let reference { unlink(reference.path); published = false }
        // Never recursively remove an endpoint directory or adopt a pre-existing directory.
        if let temporaryDirectory { rmdir(temporaryDirectory) }
    }
}
