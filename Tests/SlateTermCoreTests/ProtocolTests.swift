import Foundation
import Testing
@testable import SlateTermCore

@Test func framingHandlesFragmentedUTF8AndMultipleMessages() throws {
    var framer = LineFramer(maximumBytes: 32)
    let bytes = Array("{\"text\":\"日本\"}\n{}\n".utf8)
    #expect(try framer.append(Data(bytes.prefix(12))).isEmpty)
    let lines = try framer.append(Data(bytes.dropFirst(12)))
    #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"text\":\"日本\"}", "{}"])
}

@Test func framingRejectsOversizedCompleteAndIncompleteMessages() throws {
    var framer = LineFramer(maximumBytes: 4)
    #expect(throws: ProtocolError.self) { try framer.append(Data("12345\n".utf8)) }
    framer = LineFramer(maximumBytes: 4)
    #expect(throws: ProtocolError.self) { try framer.append(Data("12345".utf8)) }
}

@Test func handshakeMustSucceedBeforeCommandsCanRun() throws {
    var session = ProtocolSession()
    let request = RPCRequest(id: .integer(1), method: "panes.list")
    #expect(throws: ProtocolError.self) { try session.accept(request) }
    #expect(throws: ProtocolError.self) {
        try session.accept(RPCRequest(id: .integer(2), method: "hello", params: ["protocolVersion": .integer(99)]))
    }
    #expect(throws: ProtocolError.self) { try session.accept(request) }
    #expect(try session.accept(RPCRequest(id: .integer(3), method: "hello", params: ["protocolVersion": .integer(1)])) == .hello)
    #expect(try session.accept(request) == .command)
}

@Test func malformedRPCAndInvalidIDsAreRejected() throws {
    for source in [
        "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"hello\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"hello\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"hello\"}",
    ] {
        #expect(throws: (any Error).self) { try RPCRequest.decode(Data(source.utf8)) }
    }
}

@Test func explicitNullRequestIDIsNotANotification() throws {
    let request = try RPCRequest.decode(Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"hello\"}".utf8))
    #expect(request.id == .null)
}

@Test func newTabRejectsAnUnknownExplicitParentTab() throws {
    var workspace = Workspace()
    let before = workspace
    #expect(throws: (any Error).self) {
        try CommandRegistry.execute("tab.new", params: ["tab": .string("t999")], workspace: &workspace)
    }
    #expect(workspace == before)
}

@Test func registryCommandsMutateTheSameWorkspaceAndRejectUnknownOperations() throws {
    var workspace = Workspace()
    let result = try CommandRegistry.execute("split.right", params: [:], workspace: &workspace)
    #expect(result == .object(["paneId": .string("p2")]))
    #expect(workspace.panes.count == 2)
    let before = workspace
    #expect(throws: (any Error).self) {
        try CommandRegistry.execute("pane.destroy-universe", params: [:], workspace: &workspace)
    }
    #expect(workspace == before)
    _ = try CommandRegistry.execute("pane.close", params: ["pane": .string("p1")], workspace: &workspace)
    #expect(workspace.tabs[0].layout == .pane(PaneID(2)))
}
