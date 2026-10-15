import Foundation
import Testing
@testable import SlateTermCore

@Test func tokenFreeServiceIdentityChecksRoutingWithoutCredentials() throws {
    let identity = try ServiceIdentity(appInstanceID: "app", pluginID: "worker", serviceID: "service", generation: "generation")
    #expect(identity.environment["SLATE_TERM_SERVICE_TOKEN"] == nil)
    #expect(try ServiceIdentity.inherited(from: identity.environment) == identity)
    try identity.validateReply(.object(["protocolVersion": .integer(1), "service": .object(identity.info)]))
    #expect(throws: RPCFailure.self) { try identity.validateReply(.object(["protocolVersion": .integer(1)])) }
    var stale = identity.info; stale["generation"] = .string("retired")
    #expect(throws: RPCFailure.self) { try identity.validateReply(.object(["protocolVersion": .integer(1), "service": .object(stale)])) }
    var legacy = identity.environment; legacy["SLATE_TERM_SERVICE_TOKEN"] = "old-token"
    #expect(throws: RPCFailure.self) { try ServiceIdentity.inherited(from: legacy) }
}

@Test func failedRepeatedHelloInvalidatesTheCommonProtocolSession() throws {
    for metadata in [nil, try RPCMetadata(cause: nil)] {
        var session = ProtocolSession()
        _ = try session.accept(.init(id: .integer(1), method: "hello", params: ["protocolVersion": .integer(1)]))
        #expect(throws: ProtocolError.self) {
            try session.accept(.init(id: .integer(2), method: "hello", params: ["protocolVersion": .integer(metadata == nil ? 2 : 1)], metadata: metadata))
        }
        #expect(throws: ProtocolError.self) { try session.accept(.init(id: .integer(3), method: "mutate")) }
        _ = try session.accept(.init(id: .integer(4), method: "hello", params: ["protocolVersion": .integer(1)]))
        #expect(try session.accept(.init(id: .integer(5), method: "read")) == .command)
    }
}
