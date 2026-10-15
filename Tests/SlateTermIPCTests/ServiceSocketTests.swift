import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermIPC

private func serviceCredentials(generation: String = "g1") throws -> ServiceCredentials {
    try ServiceCredentials(identity: ServiceIdentity(appInstanceID: "app", pluginID: "example.worker",
        serviceID: "service", generation: generation), token: String(repeating: "ab", count: 32))
}

@Test @MainActor func authenticatedServiceSocketPreservesMetadata() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try serviceCredentials()
    var received: [(String, RPCMetadata?)] = []
    let server = try UnixServer(directory: directory, service: credentials) { method, params, metadata in
        received.append((method, metadata))
        return method == "api.describe" ? .object(["causation": .object(["version": .integer(1)])]) : .object(params)
    }
    defer { server.close() }
    let path = server.path
    try await Task.detached {
        let cause = try RPCMetadata(cause: "delivery")
        #expect(try UnixClient(path: path, service: credentials).call("mutate", params: ["x": .integer(1)], metadata: cause) == .object(["x": .integer(1)]))
    }.value
    #expect(received.map(\.0) == ["api.describe", "mutate"])
    #expect(received.last?.1 == (try RPCMetadata(cause: "delivery")))
}

@Test @MainActor func serviceClientRejectsAdministrativeReplyBeforeDispatch() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var calls = 0
    let server = try UnixServer(directory: directory) { _, _ in calls += 1; return .null }
    defer { server.close() }
    let path = server.path, credentials = try serviceCredentials()
    try await Task.detached {
        #expect(throws: RPCFailure.self) { try UnixClient(path: path, service: credentials).call("mutate") }
    }.value
    #expect(calls == 0)
}

@Test @MainActor func serviceSocketRejectsMissingAndForeignCredentials() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try serviceCredentials(), foreign = try serviceCredentials(generation: "retired")
    var calls = 0
    let server = try UnixServer(directory: directory, service: credentials) { _, _, _ in calls += 1; return .null }
    defer { server.close() }
    let path = server.path
    try await Task.detached {
        #expect(throws: RPCFailure.self) { try UnixClient(path: path).call("mutate") }
        #expect(throws: RPCFailure.self) { try UnixClient(path: path, service: foreign).call("mutate") }
    }.value
    #expect(calls == 0)
}

@Test @MainActor func invalidRepeatedServiceHelloRevokesBeforeProtocolValidation() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try serviceCredentials()
    var mutations = 0
    let server = try UnixServer(directory: directory, service: credentials) { method, _, _ in
        if method == "mutate" { mutations += 1 }
        return .object(["causation": .object(["version": .integer(1)])])
    }
    defer { server.close() }
    let path = server.path
    try await Task.detached {
        for variant in 0..<3 {
            try UnixClient(path: path, service: credentials).withSession { peer in
                var params = credentials.helloParams
                if variant == 0 { params["protocolVersion"] = .integer(2) }
                if variant == 1 { params["token"] = .string("wrong") }
                let metadata = variant == 2 ? try RPCMetadata(cause: nil) : nil
                #expect(throws: RPCFailure.self) { try peer.call("hello", params: params, metadata: metadata) }
                #expect(throws: RPCFailure.self) { try peer.call("mutate") }
                // A later valid authentication may recover this same generation.
                _ = try peer.call("hello", params: credentials.helloParams)
                _ = try peer.call("read")
            }
        }
    }.value
    #expect(mutations == 0)
}

@Test @MainActor func malformedServiceHelloClosesAndDiscardsQueuedMutation() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try serviceCredentials()
    var calls = 0
    let server = try UnixServer(directory: directory, service: credentials) { _, _, _ in calls += 1; return .null }
    defer { server.close() }
    let path = server.path
    try await Task.detached {
        let fd = try connectServiceFixture(path); defer { Darwin.close(fd) }
        var bytes = try JSONEncoder().encode(RPCRequest(id: .integer(1), method: "hello", params: credentials.helloParams))
        bytes.append(10)
        bytes.append(Data("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"hello\",\"metadata\":{\"version\":999}}\n".utf8))
        bytes.append(try JSONEncoder().encode(RPCRequest(id: .integer(3), method: "mutate"))); bytes.append(10)
        try writeServiceFixture(bytes, fd)
        try readUntilServiceFixtureCloses(fd)
    }.value
    #expect(calls == 0)
}

@Test @MainActor func servicePeerDeadlinesDoNotExpireActiveRequests() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-svc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let credentials = try serviceCredentials()
    let server = try UnixServer(directory: directory, service: credentials) { _, _, _ in
        try await Task.sleep(for: .milliseconds(2200)); return .bool(true)
    }
    defer { server.close() }
    let path = server.path
    try await Task.detached {
        #expect(try UnixClient(path: path, timeoutSeconds: 4, service: credentials).call("slow") == .bool(true))
        let unauthenticated = try connectServiceFixture(path); defer { Darwin.close(unauthenticated) }
        try readUntilServiceFixtureCloses(unauthenticated)
        let idle = try connectServiceFixture(path); defer { Darwin.close(idle) }
        var hello = try JSONEncoder().encode(RPCRequest(id: .integer(1), method: "hello", params: credentials.helloParams)); hello.append(10)
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
