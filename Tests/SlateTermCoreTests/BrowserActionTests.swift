import Testing
@testable import SlateTermCore

@Test func browserActionRejectsAmbiguousAndUnboundedInputs() throws {
    for (kind, params) in [
        ("click", [:]),
        ("click", ["selector": .string("button"), "ref": .string("old:1")]),
        ("fill", ["selector": .string("#name"), "text": .null]),
        ("fill", ["selector": .string("#name"), "text": .string(String(repeating: "界", count: 30_000))]),
        ("snapshot", ["maxElements": .bool(true)]),
        ("snapshot", ["maxElements": .integer(257)]),
        ("wait", ["selector": .string("#name"), "timeoutMilliseconds": .integer(-1)]),
        ("wait", ["selector": .string("#name"), "state": .string("maybe")]),
        ("scroll", ["y": .number(.infinity)]),
        ("click", ["selector": .string("button"), "typo": .bool(true)]),
        ("select", ["selector": .string("select"), "values": .array([.integer(1)])])
    ] as [(String, [String: JSONValue])] {
        #expect(throws: RPCFailure.self) { try BrowserAction(kind: kind, params: params) }
    }
}

@Test func browserActionKeepsCheckedParametersAndOmitsRouting() throws {
    let action = try BrowserAction(kind: "fill", params: ["pane": .string("p1"), "ref": .string("document:1"), "text": .string("日本語")])
    #expect(action.kind == .fill)
    #expect(action.parameters == ["ref": .string("document:1"), "text": .string("日本語")])
    let wait = try BrowserAction(kind: "wait", params: ["selector": .string("#ready")])
    #expect(wait.timeoutMilliseconds == 10_000)
    #expect(wait.parameters["state"] == .string("visible"))
    #expect(try BrowserAction(kind: "snapshot", params: [:]).parameters["maxElements"] == .integer(128))
}
