import Foundation
import Testing
import SlateTermCore
@testable import SlateTermIPC

private let causationDescriptor = JSONValue.object(["causation": .object(["version": .integer(1)])])

@Test @MainActor func metadataNegotiatesOnceAndReachesHandlerWithoutChangingParams() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-meta-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var methods: [String] = []
    var received: [RPCMetadata?] = []
    let server = try UnixServer(directory: directory) { method, params, metadata in
        methods.append(method); received.append(metadata)
        return method == "api.describe" ? causationDescriptor : .object(params)
    }
    defer { server.close() }
    let path = server.path
    try await Task.detached {
        let metadata = try RPCMetadata(cause: "opaque_reference")
        try UnixClient(path: path).withSession { peer in
            // Explicit guard discovery is reused rather than opening another peer.
            _ = try peer.call("api.describe")
            let params: [String: JSONValue] = ["cause": .object(["arbitrary": .bool(true)])]
            #expect(try peer.call("mutate", params: params, metadata: metadata) == .object(params))
            _ = try peer.call("mutate", metadata: metadata)
        }
    }.value
    #expect(methods == ["api.describe", "mutate", "mutate"])
    #expect(received == [nil, try RPCMetadata(cause: "opaque_reference"), try RPCMetadata(cause: "opaque_reference")])
}

@Test @MainActor func metadataUnsupportedHostsNeverReceiveTheMutation() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-meta-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var methods: [String] = []
    let server = try UnixServer(directory: directory) { method, _ in
        methods.append(method)
        return .object(["apiVersion": .integer(1)])
    }
    defer { server.close() }
    let path = server.path
    try await Task.detached {
        do { _ = try UnixClient(path: path).call("mutate", metadata: RPCMetadata(cause: "opaque")); Issue.record("Expected incompatible host") }
        catch let failure as RPCFailure { #expect(failure.code == APIError.incompatible) }
    }.value
    #expect(methods == ["api.describe"])
}

@Test @MainActor func compatibilityHandlerCannotSilentlyDropMetadata() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-meta-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var methods: [String] = []
    // Even a mistakenly advertised descriptor cannot make the old two-argument handler
    // erase metadata and perform the request as an unrelated root.
    let server = try UnixServer(directory: directory) { method, _ in
        methods.append(method)
        return causationDescriptor
    }
    defer { server.close() }
    let path = server.path
    try await Task.detached {
        do { _ = try UnixClient(path: path).call("mutate", metadata: RPCMetadata(cause: "opaque")); Issue.record("Expected metadata refusal") }
        catch let failure as RPCFailure { #expect(failure.code == APIError.incompatible) }
    }.value
    #expect(methods == ["api.describe"])
}

@Test @MainActor func metadataDiscoveryDisconnectNeverDispatchesOrReconnects() async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-meta-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var methods: [String] = []
    var server: UnixServer?
    server = try UnixServer(directory: directory) { method, _, _ in
        methods.append(method)
        server?.close()
        return causationDescriptor
    }
    defer { server?.close(); server = nil }
    let path = try #require(server?.path)
    try await Task.detached {
        #expect(throws: SocketError.self) {
            try UnixClient(path: path).call("mutate", metadata: RPCMetadata(cause: "opaque"))
        }
    }.value
    #expect(methods == ["api.describe"])
}
