import Foundation
import Testing
import SlateTermCore
@testable import SlateTermIPC

@Test(arguments: [false, true]) @MainActor
func presenceOriginNegotiationPreservesLabelsOnOlderHosts(_ supported: Bool) async throws {
    let directory = URL(fileURLWithPath: "/tmp/slate-origin-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    var received: [RPCMetadata?] = []
    let server = try UnixServer(directory: directory) { method, params, metadata in
        if method == "api.describe" {
            var presence: [String: JSONValue] = ["version": .integer(1)]
            if supported { presence["originVersion"] = .integer(1) }
            return .object(["causation": .object(["version": .integer(1)]), "presence": .object(presence)])
        }
        received.append(metadata)
        return .object(params)
    }
    defer { server.close() }
    let path = server.path
    let actor = try PresenceActor(name: "claude", home: "p1", origin: PresenceOrigin(instanceID: "app", sessionID: "session"))
    try await Task.detached {
        let params: [String: JSONValue] = ["pane": .string("p2")]
        let response = try UnixClient(path: path).call("terminal.capture", params: params, metadata: RPCMetadata(actor: actor))
        #expect(response == .object(params))
    }.value
    #expect(received.count == 1)
    let metadata = try #require(received[0])
    let actual = try #require(metadata.actor)
    #expect(actual.name == "claude" && actual.home == "p1")
    #expect(actual.origin == (supported ? actor.origin : nil))
}
