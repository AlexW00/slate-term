import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermIPC

@Test @MainActor func suspendedSocketRequestDoesNotBlockOtherPeersAndCloseCancelsIt() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-async-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var started = false
    var cancelled = false
    let server = try UnixServer(directory: directory) { method, _ in
        if method == "slow" {
            started = true
            do { try await Task.sleep(for: .seconds(30)) }
            catch { cancelled = true; throw error }
        }
        return .bool(started && !cancelled)
    }
    let path = server.path
    let slow = Task.detached { Result { try UnixClient(path: path).call("slow") } }
    for _ in 0..<100 where !started { try await Task.sleep(for: .milliseconds(10)) }
    #expect(started)
    let fast = try await Task.detached { try UnixClient(path: path).call("fast") }.value
    #expect(fast == .bool(true))
    server.close()
    let result = await slow.value
    if case .success = result { Issue.record("Closed peer unexpectedly returned success") }
    for _ in 0..<100 where !cancelled { try await Task.sleep(for: .milliseconds(10)) }
    #expect(cancelled)
}

@Test @MainActor func pipelinedRequestsRetainWireOrderAcrossSuspension() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-order-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var order: [String] = []
    let server = try UnixServer(directory: directory) { method, _ in
        if method == "slow" { try await Task.sleep(for: .milliseconds(30)) }
        order.append(method)
        return .string(method)
    }
    defer { server.close() }
    let path = server.path
    let responses = try await Task.detached {
        let descriptor = try makeSocket(nonblocking: false)
        defer { Darwin.close(descriptor) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try withSocketAddress(path) {
            guard connect(descriptor, $0, $1) == 0 else { throw SocketError.system("connect", errno) }
        }
        let requests = [RPCRequest(id: .integer(1), method: "hello", params: ["protocolVersion": .integer(1)]),
                        RPCRequest(id: .integer(2), method: "slow"), RPCRequest(id: .integer(3), method: "fast")]
        var data = Data()
        for request in requests { data.append(try JSONEncoder().encode(request)); data.append(10) }
        let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw SocketError.system("write", errno) }
        var framer = LineFramer()
        var responses: [RPCResponse] = []
        var bytes = [UInt8](repeating: 0, count: 4096)
        while responses.count < 3 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            guard count > 0 else { throw SocketError.disconnected }
            for line in try framer.append(Data(bytes.prefix(count))) { responses.append(try JSONDecoder().decode(RPCResponse.self, from: line)) }
        }
        return responses
    }.value
    #expect(responses.map(\.id) == [.integer(1), .integer(2), .integer(3)])
    #expect(order == ["slow", "fast"])
}
