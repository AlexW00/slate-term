import Testing
@testable import SlateTermCore

@Test func terminalSearchRejectsAmbiguousActionsAndUnsafeQueries() throws {
    #expect(try TerminalSearchRequest([:]).action == .get)
    #expect(try TerminalSearchRequest(["action": .string("set"), "query": .string("")]).query == "")
    for params: [String: JSONValue] in [
        ["action": .null], ["action": .string("unknown")], ["action": .string("set")],
        ["query": .string("ignored")], ["action": .string("next"), "query": .string("ignored")],
        ["action": .string("set"), "query": .string("a\0b")],
        ["action": .string("set"), "query": .string(String(repeating: "語", count: 1_366))]
    ] {
        #expect(throws: RPCFailure.self) { try TerminalSearchRequest(params) }
    }
}
