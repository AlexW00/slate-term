import Darwin
import Foundation
import SlateTermCore

/// Small nonblocking Darwin transport: Network.framework does not expose the peer
/// descriptor needed for LOCAL_PEERCRED. All state and dispatch run on the main queue.
@MainActor
public final class UnixServer {
    public let path: String
    private var listener: DispatchSourceRead?
    private var peers: [Int32: Peer] = [:]
    private let service: ServiceIdentity?
    private let handle: @MainActor (String, [String: JSONValue], RPCMetadata?) async throws -> JSONValue

    /// Compatibility handlers must reject metadata rather than silently erase causation.
    public convenience init(directory: URL, handle: @escaping @MainActor (String, [String: JSONValue]) async throws -> JSONValue) throws {
        try self.init(directory: directory) { method, params, metadata in
            guard metadata == nil else { throw RPCFailure(code: APIError.incompatible, message: "Request metadata is unsupported by this handler") }
            return try await handle(method, params)
        }
    }

    public init(directory: URL, service: ServiceIdentity? = nil,
                handle: @escaping @MainActor (String, [String: JSONValue], RPCMetadata?) async throws -> JSONValue) throws {
        self.handle = handle
        self.service = service
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var attributes = stat()
        guard lstat(directory.path, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o777 == 0o700 else {
            throw SocketError.insecureDirectory
        }
        path = directory.appendingPathComponent("\(UUID().uuidString.prefix(8)).sock").path
        let descriptor = try makeSocket(nonblocking: true)
        var bound = false
        do {
            try withSocketAddress(path) { address, length in
                guard bind(descriptor, address, length) == 0 else { throw SocketError.system("bind", errno) }
            }
            bound = true
            // Every shell reports its first prompt at launch, while the app is still busy.
            // A short queue would refuse connections from large restored layouts.
            guard chmod(path, 0o600) == 0, listen(descriptor, SOMAXCONN) == 0 else {
                throw SocketError.system("listen", errno)
            }
        } catch {
            Darwin.close(descriptor)
            // Never unlink another server's socket after a bind collision.
            if bound { unlink(path) }
            throw error
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptConnections(descriptor) }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        listener = source
        source.resume()
    }

    isolated deinit { close() }

    public func close() {
        guard let listener else { return }
        self.listener = nil
        for peer in Array(peers.values) { peer.close() }
        peers.removeAll()
        listener.cancel()
        unlink(path)
    }

    private func acceptConnections(_ listener: Int32) {
        // Bound work per callback so a connection flood cannot monopolize AppKit.
        for _ in 0..<16 {
            let descriptor = accept(listener, nil, nil)
            if descriptor < 0 { return }
            var credentials = xucred()
            var length = socklen_t(MemoryLayout<xucred>.size)
            var noSignal: Int32 = 1
            guard peers.count < (service == nil ? 128 : 4),
                  getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0,
                  credentials.cr_uid == getuid(),
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                Darwin.close(descriptor)
                continue
            }
            peers[descriptor] = Peer(descriptor: descriptor, service: service, handle: handle, onClose: { [weak self] in
                self?.peers.removeValue(forKey: descriptor)
            })
        }
    }
}

@MainActor
private final class Peer {
    private let descriptor: Int32
    private let reader: DispatchSourceRead
    private let writer: DispatchSourceWrite
    private let handle: @MainActor (String, [String: JSONValue], RPCMetadata?) async throws -> JSONValue
    private let onClose: @MainActor () -> Void
    private let service: ServiceIdentity?
    private var negotiationExpiresAt = ContinuousClock.now.advanced(by: .seconds(2))
    private var deadline: Task<Void, Never>?
    private var framing = LineFramer()
    private var session = ProtocolSession()
    private var output = Data()
    private var writerActive = false
    private var closed = false
    private var requests: [Data] = []
    private var requestBytes = 0
    private var processing: Task<Void, Never>?

    init(descriptor: Int32, service: ServiceIdentity?,
         handle: @escaping @MainActor (String, [String: JSONValue], RPCMetadata?) async throws -> JSONValue,
         onClose: @escaping @MainActor () -> Void) {
        self.descriptor = descriptor
        self.service = service
        self.handle = handle
        self.onClose = onClose
        reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        writer = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: .main)
        reader.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read() } }
        writer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        reader.setCancelHandler { Darwin.close(descriptor) }
        reader.resume()
        armDeadline()
    }

    isolated deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        deadline?.cancel(); deadline = nil
        processing?.cancel()
        requests.removeAll()
        requestBytes = 0
        if !writerActive { writer.resume() }
        writer.cancel()
        reader.cancel()
        onClose()
    }

    private func armDeadline() {
        guard service != nil, !closed else { return }
        deadline?.cancel()
        // Invalid/partial negotiation never renews the initial deadline.
        let when = session.handshaken ? ContinuousClock.now.advanced(by: .seconds(2)) : negotiationExpiresAt
        deadline = Task { [weak self] in
            do { try await Task.sleep(until: when, clock: .continuous) }
            catch { return }
            self?.close()
        }
    }

    private func read() {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count == 0 { close(); return }
        if count < 0 {
            if errno != EAGAIN && errno != EINTR { close() }
            return
        }
        do {
            for line in try framing.append(Data(buffer.prefix(count))) {
                guard !closed else { break }
                guard requestBytes + line.count <= 1_048_576, requests.count < 64 else { close(); return }
                requests.append(line)
                requestBytes += line.count
                startProcessing()
            }
        } catch { close() }
    }

    private func startProcessing() {
        guard processing == nil else { return }
        if session.handshaken { deadline?.cancel(); deadline = nil }
        processing = Task { [weak self] in
            guard let self else { return }
            defer { self.processing = nil; self.armDeadline() }
            while !self.closed, !self.requests.isEmpty {
                let request = self.requests.removeFirst()
                self.requestBytes -= request.count
                await self.dispatch(request)
            }
        }
    }

    private func dispatch(_ data: Data) async {
        var id = JSONValue.null
        var notification = false
        var decoded = false
        do {
            let request = try RPCRequest.decode(data)
            decoded = true
            if request.method == "hello" {
                if session.handshaken { negotiationExpiresAt = .now.advanced(by: .seconds(2)) }
                session = ProtocolSession()
                armDeadline()
            }
            id = request.id ?? .null
            notification = request.id == nil
            let result: JSONValue
            switch try session.accept(request) {
            case .hello:
                deadline?.cancel(); deadline = nil
                var reply: [String: JSONValue] = ["protocolVersion": .integer(1), "appVersion": .string("0.1.0-dev")]
                if let service { reply["service"] = .object(service.info) }
                result = .object(reply)
            case .command:
                result = try await handle(request.method, request.params ?? [:], request.metadata)
            }
            if !notification { enqueue(RPCResponse(id: id, result: result)) }
        } catch {
            // Malformed input may be a repeated hello that failed before decoding.
            // Invalidate the ordinary protocol session too; a generation endpoint
            // additionally closes/discards its queue as a lifecycle boundary.
            if !decoded {
                session = ProtocolSession()
                if service != nil { close(); return }
            }
            guard !notification else { return }
            let failure: RPCFailure
            switch error {
            case let error as RPCFailure: failure = error
            case ProtocolError.handshakeRequired: failure = .init(code: -32001, message: "Send hello before commands")
            case ProtocolError.incompatibleVersion: failure = .init(code: -32002, message: "Incompatible protocol version; expected 1")
            case ProtocolError.invalidRequest: failure = .init(code: -32600, message: "Invalid JSON-RPC 2.0 request")
            case ProtocolError.parseError: failure = .init(code: -32700, message: "Malformed request JSON")
            case is CancellationError: failure = .init(code: -32022, message: "Request was cancelled")
            default: failure = .init(code: -32602, message: String(describing: error))
            }
            enqueue(RPCResponse(id: id, error: failure))
        }
    }

    private func enqueue(_ response: RPCResponse) {
        guard !closed else { return }
        guard let bytes = try? JSONEncoder().encode(response), output.count + bytes.count + 1 <= 1_048_576 else {
            close(); return
        }
        output.append(bytes)
        output.append(10)
        if !writerActive { writerActive = true; writer.resume() }
    }

    private func flush() {
        guard !closed else { return }
        let count = output.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno != EAGAIN && errno != EINTR { close() }
            return
        }
        output.removeFirst(count)
        if output.isEmpty { writerActive = false; writer.suspend() }
    }
}
