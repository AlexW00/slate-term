import Darwin
import Foundation
import SlateTermCore

/// Blocking client for CLI use only. The native application uses the nonblocking server.
public struct UnixClient: Sendable {
    public let path: String
    public let protocolVersion: Int
    public let timeoutSeconds: Int
    public init(path: String, protocolVersion: Int = 1, timeoutSeconds: Int = 30) {
        self.path = path; self.protocolVersion = protocolVersion; self.timeoutSeconds = timeoutSeconds
    }

    public func call(_ method: String, params: [String: JSONValue] = [:]) throws -> JSONValue {
        guard (1...300).contains(timeoutSeconds) else { throw SocketError.invalidTimeout }
        let descriptor = try makeSocket(nonblocking: false)
        defer { Darwin.close(descriptor) }
        // WebKit navigation has a 15-second host deadline, followed by a bounded
        // document read. Keep the transport deadline outside those operation limits.
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw SocketError.system("socket timeout", errno)
        }
        try withSocketAddress(path) { address, length in
            guard connect(descriptor, address, length) == 0 else { throw SocketError.system("connect", errno) }
        }
        _ = try exchange(RPCRequest(id: .integer(1), method: "hello", params: ["protocolVersion": .integer(protocolVersion)]), descriptor)
        return try exchange(RPCRequest(id: .integer(2), method: method, params: params), descriptor)
    }

    private func exchange(_ request: RPCRequest, _ descriptor: Int32) throws -> JSONValue {
        var bytes = try JSONEncoder().encode(request)
        bytes.append(10)
        guard bytes.count <= 1_048_576 else { throw ProtocolError.oversizedMessage }
        while !bytes.isEmpty {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw SocketError.system("write", errno)
            }
            guard count > 0 else { throw SocketError.disconnected }
            bytes.removeFirst(count)
        }
        var framing = LineFramer()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw SocketError.system("read", errno)
            }
            guard count > 0 else { throw SocketError.disconnected }
            let messages = try framing.append(Data(buffer.prefix(count)))
            guard let first = messages.first else { continue }
            let response = try JSONDecoder().decode(RPCResponse.self, from: first)
            guard response.jsonrpc == "2.0", response.id == request.id,
                  (response.result == nil) != (response.error == nil) else { throw SocketError.invalidResponse }
            if let failure = response.error { throw failure }
            return response.result!
        }
    }
}
