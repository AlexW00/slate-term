import Foundation
import Testing
import SlateTermCore
@testable import SlateTermIPC

@Test @MainActor func scopedSessionReusesHandshakeAndInvalidatesEscapedHandle() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-session-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var methods: [String] = []
    let server = try UnixServer(directory: directory) { method, _ in
        methods.append(method)
        if method == "bad" { throw RPCFailure(code: -32602, message: "Rejected") }
        return .string(method)
    }
    defer { server.close() }
    let path = server.path
    let closed = try await Task.detached {
        var escaped: UnixClient.Session?
        let result = try UnixClient(path: path).withSession { session in
            escaped = session
            #expect(try session.call("first") == .string("first"))
            #expect(throws: RPCFailure.self) { try session.call("bad") }
            return try session.call("last")
        }
        #expect(result == .string("last"))
        let retained = try #require(escaped)
        do { _ = try retained.call("escaped"); return false }
        catch SocketError.disconnected { return true }
    }.value
    #expect(closed)
    #expect(methods == ["first", "bad", "last"])
}

@Test @MainActor func scopedSessionClosesWhenItsBodyThrows() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-session-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try UnixServer(directory: directory) { _, _ in .null }
    defer { server.close() }
    let path = server.path
    let closed = try await Task.detached {
        var escaped: UnixClient.Session?
        do {
            try UnixClient(path: path).withSession { session in
                escaped = session
                _ = try session.call("first")
                throw RPCFailure(code: -32602, message: "Caller stopped")
            }
        } catch let failure as RPCFailure { #expect(failure.message == "Caller stopped") }
        let retained = try #require(escaped)
        do { _ = try retained.call("escaped"); return false }
        catch SocketError.disconnected { return true }
    }.value
    #expect(closed)
}

@Test @MainActor func transportTimeoutInvalidatesSessionBeforeItsScopeExits() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-session-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var dispatched: [String] = []
    let server = try UnixServer(directory: directory) { method, _ in
        dispatched.append(method)
        if method == "slow" { try await Task.sleep(for: .seconds(30)) }
        return .null
    }
    defer { server.close() }
    let path = server.path
    let closed = try await Task.detached {
        try UnixClient(path: path, timeoutSeconds: 1).withSession { session in
            do { _ = try session.call("slow"); Issue.record("Expected timeout") }
            catch is SocketError { /* The same handle must now be unusable. */ }
            do { _ = try session.call("retry"); return false }
            catch SocketError.disconnected { return true }
        }
    }.value
    #expect(closed)
    #expect(dispatched == ["slow"])
}

@Test @MainActor func failedSessionHandshakeNeverInvokesBody() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-session-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var dispatched = false
    let server = try UnixServer(directory: directory) { _, _ in dispatched = true; return .null }
    defer { server.close() }
    let path = server.path
    let entered = try await Task.detached {
        var entered = false
        do {
            try UnixClient(path: path, protocolVersion: 999).withSession { _ in entered = true }
            Issue.record("Expected failed handshake")
        } catch let failure as RPCFailure { #expect(failure.code == -32002) }
        return entered
    }.value
    #expect(!entered && !dispatched)
}
