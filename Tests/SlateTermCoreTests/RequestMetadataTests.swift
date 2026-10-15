import Foundation
import Testing
@testable import SlateTermCore

private func requestBytes(metadata: JSONValue?, method: String = "command.run", params: [String: JSONValue] = [:]) throws -> Data {
    var fields: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": .integer(7), "method": .string(method), "params": .object(params)]
    fields["metadata"] = metadata
    return try JSONEncoder().encode(JSONValue.object(fields))
}

@Test(arguments: [
    JSONValue.null, .array([]), .string("token"), .object([:]),
    .object(["version": .integer(2)]), .object(["version": .string("1")]),
    .object(["version": .integer(1), "origin": .string("native")]),
    .object(["version": .integer(1), "cause": .null]),
    .object(["version": .integer(1), "cause": .integer(1)]),
    .object(["version": .integer(1), "cause": .string("")]),
    .object(["version": .integer(1), "cause": .string("has space")]),
    .object(["version": .integer(1), "cause": .string("非ASCII")]),
    .object(["version": .integer(1), "cause": .string(String(repeating: "x", count: 65))])
]) func malformedMetadataCannotSilentlyBecomeARootRequest(_ metadata: JSONValue) throws {
    let bytes = try requestBytes(metadata: metadata)
    #expect(throws: ProtocolError.self) { try RPCRequest.decode(bytes) }
}

@Test func metadataRoundTripsSeparatelyFromContributedArguments() throws {
    let metadata = JSONValue.object(["version": .integer(1), "cause": .string("opaque-delivery_reference")])
    let params: [String: JSONValue] = ["id": .string("plugin.example.run"), "cause": .object(["arbitrary": .bool(true)])]
    let request = try RPCRequest.decode(requestBytes(metadata: metadata, params: params))
    let encoded = try JSONValue.encoding(request)
    #expect(encoded.object?["metadata"] == metadata)
    #expect(request.params == params)
    let legacy = try RPCRequest.decode(requestBytes(metadata: nil, params: params))
    #expect(legacy.params == params)
    #expect(try JSONValue.encoding(legacy).object?["metadata"] == nil)
}

@Test func versionOnlyMetadataIsAnExplicitRootAndHandshakeRejectsMetadata() throws {
    let metadata = JSONValue.object(["version": .integer(1)])
    let request = try RPCRequest.decode(requestBytes(metadata: metadata))
    #expect(try JSONValue.encoding(request).object?["metadata"] == metadata)
    var session = ProtocolSession()
    let hello = try RPCRequest.decode(requestBytes(metadata: metadata, method: "hello", params: ["protocolVersion": .integer(1)]))
    #expect(throws: ProtocolError.self) { try session.accept(hello) }
    #expect(throws: ProtocolError.self) { try session.accept(request) }
}
