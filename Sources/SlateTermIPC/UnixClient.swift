import Darwin
import Foundation
import SlateTermCore

/// Blocking client for CLI use only. The native application uses the nonblocking server.
public struct UnixClient: Sendable {
    public let path: String
    public let protocolVersion: Int
    public let timeoutSeconds: Int
    public let service: ServiceCredentials?
    public init(path: String, protocolVersion: Int = 1, timeoutSeconds: Int = 30, service: ServiceCredentials? = nil) {
        self.path = path; self.protocolVersion = protocolVersion; self.timeoutSeconds = timeoutSeconds
        self.service = service
    }

    public func call(_ method: String, params: [String: JSONValue] = [:], metadata: RPCMetadata? = nil) throws -> JSONValue {
        try withSession { try $0.call(method, params: params, metadata: metadata) }
    }

    /// Capability checks and dependent requests share the same handshaken peer. Never reconnect
    /// after a failure: another process may now own the path and ignore negotiated safeguards.
    /// The session is serial, blocking, and invalidated when the closure exits (even if retained).
    public func withSession<Result>(_ body: (Session) throws -> Result) throws -> Result {
        guard (1...300).contains(timeoutSeconds) else { throw SocketError.invalidTimeout }
        let descriptor = try makeSocket(nonblocking: false)
        let session = Session(descriptor: descriptor)
        defer { session.close() }
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
        var hello = service?.helloParams ?? [:]
        hello["protocolVersion"] = .integer(protocolVersion)
        let reply = try Self.exchange(RPCRequest(id: .integer(1), method: "hello", params: hello), descriptor)
        try service?.validateReply(reply)
        return try body(session)
    }

    public final class Session {
        private var descriptor: Int32?
        private var nextID = 2
        private var supportsMetadata: Bool?
        fileprivate init(descriptor: Int32) { self.descriptor = descriptor }
        deinit { if let descriptor { Darwin.close(descriptor) } }

        public func call(_ method: String, params: [String: JSONValue] = [:], metadata: RPCMetadata? = nil) throws -> JSONValue {
            guard let descriptor else { throw SocketError.disconnected }
            if metadata != nil {
                if supportsMetadata == nil {
                    do { _ = try call("api.describe") }
                    catch let failure as RPCFailure where failure.code == -32601 {
                        throw RPCFailure(code: APIError.incompatible, message: "Host does not support request metadata")
                    }
                }
                guard supportsMetadata == true else {
                    throw RPCFailure(code: APIError.incompatible, message: "Host does not support request metadata version 1")
                }
            }
            guard nextID < Int.max else { close(); throw SocketError.invalidResponse }
            let request = RPCRequest(id: .integer(nextID), method: method, params: params, metadata: metadata)
            nextID += 1
            do {
                let result = try UnixClient.exchange(request, descriptor)
                if method == "api.describe" { supportsMetadata = result.object?["causation"]?.object?["version"] == .integer(1) }
                return result
            }
            catch let failure as RPCFailure { throw failure }
            catch { close(); throw error }
        }

        fileprivate func close() {
            if let descriptor { Darwin.close(descriptor) }
            descriptor = nil
        }
    }

    private static func exchange(_ request: RPCRequest, _ descriptor: Int32) throws -> JSONValue {
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
            let messages: [Data]
            do { messages = try framing.append(Data(buffer.prefix(count))) }
            catch { throw SocketError.invalidResponse }
            guard let first = messages.first else { continue }
            let response: RPCResponse
            do { response = try JSONDecoder().decode(RPCResponse.self, from: first) }
            // Invalid output is a transport failure with an unknown operation outcome,
            // not a local argument rejection. Do not expose untrusted decoder diagnostics.
            catch { throw SocketError.invalidResponse }
            guard response.jsonrpc == "2.0", response.id == request.id,
                  (response.result == nil) != (response.error == nil) else { throw SocketError.invalidResponse }
            if let failure = response.error { throw failure }
            return response.result!
        }
    }
}
