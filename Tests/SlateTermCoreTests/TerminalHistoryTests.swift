import Testing
@testable import SlateTermCore

@Test func historyLimitsKeepNewestLinesAndReportTruncation() throws {
    let request = try TerminalHistoryRequest(["maxLines": .integer(2)])
    let result = request.result(text: "old\n日本語\nlast\n", byteTruncated: false)
    #expect(result.text == "日本語\nlast\n")
    #expect(result.truncated && result.lineCount == 2)
    #expect(request.result(text: "a\nb\n", byteTruncated: false).truncated == false)
    #expect(request.result(text: "a\nb\n", byteTruncated: true).truncated)
    #expect(request.result(text: "", byteTruncated: false).lineCount == 0)
    #expect(request.result(text: "\n", byteTruncated: false).lineCount == 1)
    #expect(request.result(text: "one", byteTruncated: false).text == "one")
    for bad: JSONValue in [.integer(0), .integer(131_073), .string("100"), .null, .bool(true)] {
        #expect(throws: RPCFailure.self) { try TerminalHistoryRequest(["maxBytes": bad]) }
    }
    #expect(throws: RPCFailure.self) { try TerminalHistoryRequest(["maxLines": .integer(10_001)]) }
}

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
