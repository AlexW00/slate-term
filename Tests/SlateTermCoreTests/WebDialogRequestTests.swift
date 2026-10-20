import Testing
@testable import SlateTermCore

@Test func webDialogResponsesRequireExplicitConsentAndExactIdentity() throws {
    let id = "pending-dialog"
    for action in ["accept", "dismiss"] {
        let request = try WebDialogRequest(params: ["dialogId": .string(id), "action": .string(action)])
        #expect(request.dialogID == id)
        #expect(request.action.rawValue == action)
        #expect(request.text == nil)
    }
    for invalidID in [JSONValue.null, .bool(true), .string(""), .string("a:b"), .string("has space"),
                      .string(String(repeating: "x", count: 129))] {
        #expect(throws: RPCFailure.self) {
            try WebDialogRequest(params: ["dialogId": invalidID, "action": .string("accept")])
        }
    }
    for action in [JSONValue.null, .bool(true), .string(""), .string("ok")] {
        #expect(throws: RPCFailure.self) {
            try WebDialogRequest(params: ["dialogId": .string(id), "action": action])
        }
    }
    #expect(throws: RPCFailure.self) { try WebDialogRequest(params: ["action": .string("accept")]) }
    #expect(throws: RPCFailure.self) { try WebDialogRequest(params: ["dialogId": .string(id)]) }
}

@Test func webDialogPromptResponsesDistinguishEmptyTextFromDismissal() throws {
    let base: [String: JSONValue] = ["dialogId": .string("dialog"), "action": .string("accept")]
    #expect(try WebDialogRequest(params: base.merging(["text": .string("")]) { _, rhs in rhs }).text == "")
    let maximum = String(repeating: "あ", count: 21_845) + "x"
    #expect(try WebDialogRequest(params: base.merging(["text": .string(maximum)]) { _, rhs in rhs }).text == maximum)
    for value in [JSONValue.null, .bool(false), .string(maximum + "x")] {
        #expect(throws: RPCFailure.self) {
            try WebDialogRequest(params: base.merging(["text": value]) { _, rhs in rhs })
        }
    }
    #expect(throws: RPCFailure.self) {
        try WebDialogRequest(params: ["dialogId": .string("dialog"), "action": .string("dismiss"), "text": .string("")])
    }
    #expect(throws: RPCFailure.self) {
        try WebDialogRequest(params: base.merging(["accepted": .bool(true)]) { _, rhs in rhs })
    }
}
