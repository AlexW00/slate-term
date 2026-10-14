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
