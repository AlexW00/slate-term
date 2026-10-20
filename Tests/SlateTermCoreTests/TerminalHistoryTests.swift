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

@Test func historySourcesAreExplicitAndTextBoundsApplyToSavedOutput() throws {
    #expect(try TerminalHistoryRequest([:]).source == .current)
    #expect(try TerminalHistoryRequest(["source": .string("previous")]).source == .previous)
    for bad: JSONValue in [.string("all"), .integer(1), .null, .bool(true)] {
        #expect(throws: RPCFailure.self) { try TerminalHistoryRequest(["source": bad]) }
    }
    let request = try TerminalHistoryRequest(["source": .string("previous"), "maxBytes": .integer(8), "maxLines": .integer(2)])
    let result = request.result(text: "old\r\n日本語\r\nlast\r\n", byteTruncated: false)
    #expect(result.text == "\r\nlast\r\n")
    #expect(result.truncated && result.lineCount == 2 && result.text.utf8.count == 8)
    let oneLine = try TerminalHistoryRequest(["maxLines": .integer(1)])
    #expect(oneLine.result(text: "old\r\nlast\r\n", byteTruncated: false).text == "last\r\n")
    let tiny = try TerminalHistoryRequest(["maxBytes": .integer(3)])
    let cluster = tiny.result(text: "before👩🏽‍💻", byteTruncated: false)
    #expect(cluster.text.isEmpty && cluster.truncated && cluster.lineCount == 0)
    let decomposed = tiny.result(text: "beforee\u{301}", byteTruncated: false)
    #expect(decomposed.text == "e\u{301}" && decomposed.lineCount == 1)
    let large = String(repeating: "x", count: 4 * 1024 * 1024)
    let bounded = try TerminalHistoryRequest([:]).result(text: large, byteTruncated: false)
    #expect(bounded.text.utf8.count == TerminalHistoryRequest.maximumBytes && bounded.truncated && bounded.lineCount == 1)
}
