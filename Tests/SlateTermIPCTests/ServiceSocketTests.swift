import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermIPC

private func serviceIdentity(generation: String = "g1") throws -> ServiceIdentity {
    try ServiceIdentity(appInstanceID: "app", pluginID: "example.worker", serviceID: "service", generation: generation)
}

@Test @MainActor func serviceSocketUsesOrdinaryHelloAndPreservesMetadata() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try serviceIdentity()
    var received: [(String, RPCMetadata?)] = []
    let server = try UnixServer(directory: directory, service: identity) { method, params, metadata in
        received.append((method, metadata))
        return method == "api.describe" ? .object(["causation": .object(["version": .integer(1)])]) : .object(params)
    }
    defer { server.close() }
    let path = server.path
    try await Task.detached {
        let cause = try RPCMetadata(cause: "delivery")
        #expect(try UnixClient(path: path, service: identity).call("mutate", params: ["x": .integer(1)], metadata: cause) == .object(["x": .integer(1)]))
        // No credential is required. The endpoint still owns the request's identity.
        #expect(try UnixClient(path: path).call("read") == .object([:]))
    }.value
    #expect(received.map(\.0) == ["api.describe", "mutate", "read"])
    #expect(received[1].1 == (try RPCMetadata(cause: "delivery")))
}

@Test @MainActor func inheritedServiceOwnerCannotFallBackToRootBeforeDispatch() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var calls = 0
    let server = try UnixServer(directory: directory) { _, _ in calls += 1; return .null }
    defer { server.close() }
    let path = server.path, identity = try serviceIdentity()
    await Task.detached {
        #expect(throws: RPCFailure.self) { try UnixClient(path: path, service: identity).call("mutate") }
    }.value
    #expect(calls == 0)
}

@Test @MainActor func stalePublicGenerationFailsBeforeDispatch() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try serviceIdentity(), foreign = try serviceIdentity(generation: "retired")
    var calls = 0
    let server = try UnixServer(directory: directory, service: identity) { _, _, _ in calls += 1; return .null }
    defer { server.close() }
    let path = server.path
    await Task.detached {
        #expect(throws: RPCFailure.self) { try UnixClient(path: path, service: foreign).call("mutate") }
    }.value
    #expect(calls == 0)
}

@Test @MainActor func invalidRepeatedHelloRevokesBothEndpointKinds() async throws {
    for bound in [false, true] {
        let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try bound ? serviceIdentity() : nil
        var mutations = 0
        let server = try UnixServer(directory: directory, service: identity) { method, _, _ in
            if method == "mutate" { mutations += 1 }
            return .object(["causation": .object(["version": .integer(1)])])
        }
        defer { server.close() }
        let path = server.path
        try await Task.detached {
            for variant in 0..<2 {
                try UnixClient(path: path, service: identity).withSession { peer in
                    let params: [String: JSONValue] = ["protocolVersion": .integer(variant == 0 ? 2 : 1)]
                    let metadata = variant == 1 ? try RPCMetadata(cause: nil) : nil
                    #expect(throws: RPCFailure.self) { try peer.call("hello", params: params, metadata: metadata) }
                    #expect(throws: RPCFailure.self) { try peer.call("mutate") }
                    _ = try peer.call("hello", params: ["protocolVersion": .integer(1)])
                    _ = try peer.call("read")
                }
            }
        }.value
        #expect(mutations == 0)
    }
}

@Test @MainActor func malformedHelloCannotKeepNegotiationOnEitherEndpoint() async throws {
    for bound in [false, true] {
        let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = try bound ? serviceIdentity() : nil
        var methods: [String] = []
        let server = try UnixServer(directory: directory, service: identity) { method, _, _ in methods.append(method); return .null }
        defer { server.close() }
        let path = server.path
        try await Task.detached {
            let fd = try connectServiceFixture(path); defer { Darwin.close(fd) }
            var bytes = Data()
            func append(_ request: RPCRequest) throws { bytes.append(try JSONEncoder().encode(request)); bytes.append(10) }
            try append(.init(id: .integer(1), method: "hello", params: ["protocolVersion": .integer(1)]))
            bytes.append(Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"hello\",\"metadata\":{\"version\":999}}\n".utf8))
            try append(.init(id: .integer(3), method: "mutate"))
            try append(.init(id: .integer(4), method: "hello", params: ["protocolVersion": .integer(1)]))
            try append(.init(id: .integer(5), method: "read"))
            try writeServiceFixture(bytes, fd)
            if bound { try readUntilServiceFixtureCloses(fd) }
            else {
                var framing = LineFramer(), replies: [RPCResponse] = []
                var buffer = [UInt8](repeating: 0, count: 4096)
                while replies.count < 5 {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    guard count > 0 else { throw SocketError.system("read", errno) }
                    for line in try framing.append(Data(buffer.prefix(count))) { replies.append(try JSONDecoder().decode(RPCResponse.self, from: line)) }
                }
                #expect(replies[1].error?.code == -32600)
                #expect(replies[2].error?.code == -32001)
                #expect(replies[4].error == nil)
            }
        }.value
        #expect(methods == (bound ? [] : ["read"]))
    }
}

@Test @MainActor func servicePeerDeadlinesDoNotExpireActiveRequests() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try serviceIdentity()
    let server = try UnixServer(directory: directory, service: identity) { _, _, _ in
        try await Task.sleep(for: .milliseconds(2200)); return .bool(true)
    }
    defer { server.close() }
    let path = server.path
    try await Task.detached {
        #expect(try UnixClient(path: path, timeoutSeconds: 4, service: identity).call("slow") == .bool(true))
        let unnegotiated = try connectServiceFixture(path); defer { Darwin.close(unnegotiated) }
        try readUntilServiceFixtureCloses(unnegotiated)
        let idle = try connectServiceFixture(path); defer { Darwin.close(idle) }
        var hello = try JSONEncoder().encode(RPCRequest(id: .integer(1), method: "hello", params: ["protocolVersion": .integer(1)])); hello.append(10)
        try writeServiceFixture(hello, idle)
        try readUntilServiceFixtureCloses(idle)
    }.value
}

private func connectServiceFixture(_ path: String) throws -> Int32 {
    let fd = try makeSocket(nonblocking: false)
    do {
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw SocketError.system("timeout", errno) }
        try withSocketAddress(path) { guard connect(fd, $0, $1) == 0 else { throw SocketError.system("connect", errno) } }
        return fd
    } catch { Darwin.close(fd); throw error }
}
private func writeServiceFixture(_ data: Data, _ fd: Int32) throws {
    var remaining = data
    while !remaining.isEmpty {
        let count = remaining.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count > 0 else { throw SocketError.system("write", errno) }
        remaining.removeFirst(count)
    }
}
private func readUntilServiceFixtureCloses(_ fd: Int32) throws {
    var bytes = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count == 0 { return }
        guard count > 0 else { throw SocketError.system("read", errno) }
    }
}
