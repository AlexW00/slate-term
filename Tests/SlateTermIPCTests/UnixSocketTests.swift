import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermIPC

@Test @MainActor func realSocketHandshakesAndDispatchesAndCleansUp() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-ipc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try UnixServer(directory: directory) { method, params in
        method == "null" ? .null : .object(["method": .string(method), "params": .object(params)])
    }
    let path = server.path
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let result = try await Task.detached {
        try UnixClient(path: path).call("echo", params: ["text": .string("日本語\nhello")])
    }.value
    #expect(result == .object(["method": .string("echo"), "params": .object(["text": .string("日本語\nhello")])]))
    let null = try await Task.detached { try UnixClient(path: path).call("null") }.value
    #expect(null == .null)
    server.close()
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test @MainActor func finalReleaseRemovesSocketWithoutExplicitClose() throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-ipc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var server: UnixServer? = try UnixServer(directory: directory) { _, _ in .null }
    let path = try #require(server?.path)
    #expect(FileManager.default.fileExists(atPath: path))
    server = nil
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test @MainActor func finalReleaseClosesAnIdleHandshakenPeer() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-ipc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var server: UnixServer? = try UnixServer(directory: directory) { _, _ in .null }
    let path = try #require(server?.path)
    let descriptor = try makeSocket(nonblocking: false)
    defer { Darwin.close(descriptor) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    try withSocketAddress(path) {
        guard connect(descriptor, $0, $1) == 0 else { throw SocketError.system("connect", errno) }
    }
    let hello = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"hello\",\"params\":{\"protocolVersion\":1}}\n".utf8)
    _ = hello.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    let response = try await Task.detached { try readResponse(descriptor) }.value
    #expect(response.result?.object?["protocolVersion"] == .integer(1))
    // The peer's writer is now suspended, and the client deliberately stays connected.
    server = nil
    let eof = await Task.detached {
        var byte: UInt8 = 0
        return Darwin.read(descriptor, &byte, 1)
    }.value
    #expect(eof == 0)
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test @MainActor func mismatchedProtocolNeverDispatches() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-ipc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var dispatched = false
    let server = try UnixServer(directory: directory) { _, _ in dispatched = true; return .null }
    defer { server.close() }
    let path = server.path
    let rejected = await Task.detached {
        do {
            _ = try UnixClient(path: path, protocolVersion: 999).call("echo")
            return false
        } catch { return true }
    }.value
    #expect(rejected)
    #expect(!dispatched)
}

@Test @MainActor func wireErrorsDistinguishSyntaxFromInvalidEnvelopes() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-ipc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try UnixServer(directory: directory) { _, _ in .null }
    defer { server.close() }
    let path = server.path
    for (source, expected) in [("{", -32700), ("{}", -32600), ("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":42}", -32600)] {
        let response = try await Task.detached { try rawExchange(path: path, source: source) }.value
        #expect(response.error?.code == expected)
    }
}

private func rawExchange(path: String, source: String) throws -> RPCResponse {
    let descriptor = try makeSocket(nonblocking: false)
    defer { Darwin.close(descriptor) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    try withSocketAddress(path) {
        guard connect(descriptor, $0, $1) == 0 else { throw SocketError.system("connect", errno) }
    }
    let bytes = Data((source + "\n").utf8)
    let written = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    guard written == bytes.count else { throw SocketError.system("write", errno) }
    return try readResponse(descriptor)
}

private func readResponse(_ descriptor: Int32) throws -> RPCResponse {
    var framing = LineFramer()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { throw SocketError.system("read", errno) }
        if let line = try framing.append(Data(buffer.prefix(count))).first {
            return try JSONDecoder().decode(RPCResponse.self, from: line)
        }
    }
}

@Test @MainActor func insecureSocketDirectoryIsRejectedWithoutChangingItsPermissions() throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-ipc-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    chmod(directory.path, 0o755)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: (any Error).self) { try UnixServer(directory: directory) { _, _ in .null } }
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
}

@Test @MainActor func longPrivateStatePathsUseDiscoverableShortSocketsAndCleanUp() async throws {
    let root = URL(fileURLWithPath: "/tmp/slate-ipc-\(UUID().uuidString)")
    let directory = root.appendingPathComponent("Library/Application Support/SlateTerm/LayoutApps/\(UUID().uuidString)/control")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try UnixServer(directory: directory) { method, _ in .string(method) }
    defer { server.close() }
    let path = server.path
    #expect(path.utf8.count < 104)
    #expect(!path.hasPrefix(directory.path))
    let references = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let reference = try #require(references.first)
    #expect(references.count == 1 && reference.pathExtension == "socket-path")
    #expect(try String(contentsOf: reference, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == path)
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    let answer = try await Task.detached { try UnixClient(path: path).call("long-state-path") }.value
    #expect(answer == .string("long-state-path"))
    server.close()
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(!FileManager.default.fileExists(atPath: reference.path))
    #expect(!FileManager.default.fileExists(atPath: parent.path))
    #expect(FileManager.default.fileExists(atPath: directory.path))
}


@Test @MainActor func longSocketPublicationNeverReplacesAnExistingReference() throws {
    let root = URL(fileURLWithPath: "/tmp/slate-ipc-\(UUID().uuidString)")
    let directory = root.appendingPathComponent(String(repeating: "long-state-", count: 8))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let endpoint = try SocketEndpoint(directory: directory)
    defer { endpoint.cleanup() }
    let name = URL(fileURLWithPath: endpoint.path).deletingPathExtension().lastPathComponent
    let reference = directory.appendingPathComponent(name + ".socket-path")
    try Data("existing reference".utf8).write(to: reference)
    #expect(throws: (any Error).self) { try endpoint.publish() }
    endpoint.cleanup()
    #expect(try String(contentsOf: reference, encoding: .utf8) == "existing reference")
    #expect(!FileManager.default.fileExists(atPath: reference.path + ".tmp"))
}

@Test @MainActor func closingOneLongSocketPreservesTheOtherServer() async throws {
    let root = URL(fileURLWithPath: "/tmp/slate-ipc-\(UUID().uuidString)")
    let directory = root.appendingPathComponent(String(repeating: "long-state-", count: 8))
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try UnixServer(directory: directory) { _, _ in .integer(1) }
    defer { first.close() }
    let second = try UnixServer(directory: directory) { _, _ in .integer(2) }
    defer { second.close() }
    #expect(first.path != second.path)
    first.close()
    let path = second.path
    #expect(try await Task.detached { try UnixClient(path: path).call("remaining") }.value == .integer(2))
    let references = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(references.count == 1)
}

@Test @MainActor func deferredShutdownWaitsForTheWholeReply() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-ipc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var server: UnixServer?
    let payload = String(repeating: "reply", count: 100_000)
    var shutdown = false
    server = try UnixServer(directory: directory) { _, _ in
        RPCReplyCompletion.afterReply {
            shutdown = true
            server?.close()
        }
        // Exercise an asynchronous handler before its large reply reaches the writer.
        await Task.yield()
        return .string(payload)
    }
    defer { server?.close() }
    let path = try #require(server?.path)
    let result = try await Task.detached { try UnixClient(path: path).call("restart") }.value
    #expect(result == .string(payload))
    for _ in 0..<100 where !shutdown { try await Task.sleep(for: .milliseconds(1)) }
    #expect(shutdown)
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test @MainActor func nonreadingCallerCannotDelayCommittedShutdownIndefinitely() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-ipc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var server: UnixServer?
    var shutdown = false
    server = try UnixServer(directory: directory) { method, _ in
        if method == "block" { return .string(String(repeating: "x", count: 500_000)) }
        RPCReplyCompletion.afterReply { shutdown = true; server?.close() }
        return .string("accepted")
    }
    defer { server?.close() }
    let path = try #require(server?.path)
    let descriptor = try makeSocket(nonblocking: false)
    defer { Darwin.close(descriptor) }
    var receiveLimit: Int32 = 1024
    #expect(setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &receiveLimit, socklen_t(MemoryLayout<Int32>.size)) == 0)
    try withSocketAddress(path) {
        guard connect(descriptor, $0, $1) == 0 else { throw SocketError.system("connect", errno) }
    }
    let requests = """
    {"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":1}}
    {"jsonrpc":"2.0","id":2,"method":"block"}
    {"jsonrpc":"2.0","id":3,"method":"restart"}

    """
    let data = Data(requests.utf8)
    #expect(data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) } == data.count)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!shutdown)
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !shutdown, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(shutdown)
}
