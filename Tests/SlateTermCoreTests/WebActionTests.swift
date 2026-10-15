import Testing
@testable import SlateTermCore

@Test func webSelectorsRequirePairedAutomationIdentityBeforeMutation() throws {
    for kind in ["click", "fill", "select", "scroll"] {
        var params: [String: JSONValue] = ["selector": .string("#target")]
        if kind == "fill" { params["text"] = .string("value") }
        if kind == "select" { params["values"] = .array([.string("value")]) }
        #expect(throws: RPCFailure.self) { try WebAction(kind: kind, params: params) }
        params["expectedViewId"] = .string("view-a")
        #expect(throws: RPCFailure.self) { try WebAction(kind: kind, params: params) }
        params["expectedDocumentId"] = .string("document-a")
        let action = try WebAction(kind: kind, params: params)
        #expect(action.identity == (try WebIdentity(viewID: "view-a", documentID: "document-a")))
        #expect(action.action.parameters["expectedViewId"] == nil)
        #expect(action.action.parameters["expectedDocumentId"] == nil)
    }
    #expect(throws: RPCFailure.self) { try WebAction(kind: "scroll", params: ["y": .integer(1)]) }
}

@Test func webReferencesBindViewAndDocumentWithoutRerouting() throws {
    let action = try WebAction(kind: "click", params: ["pane": .string("p1"), "ref": .string("view-a:document-a:3")])
    #expect(action.identity == (try WebIdentity(viewID: "view-a", documentID: "document-a")))
    #expect(action.action.parameters == ["ref": .string("view-a:document-a:3")])
    for (view, document) in [("view-b", "document-a"), ("view-a", "document-b")] {
        #expect(throws: RPCFailure.self) {
            try WebAction(kind: "click", params: ["ref": .string("view-a:document-a:3"),
                "expectedViewId": .string(view), "expectedDocumentId": .string(document)])
        }
    }
    for ref in ["document:1", "a:b:0", "a:b:-1", "a:b:01", "a:b:1:2", "a:b:18446744073709551616", "a:非ASCII:1"] {
        #expect(throws: RPCFailure.self) { try WebAction(kind: "click", params: ["ref": .string(ref)]) }
    }
}

@Test func webReadsAllowDiscoveryButRejectPartialOrMalformedGuards() throws {
    #expect(try WebAction(kind: "snapshot", params: [:]).identity == nil)
    #expect(try WebAction(kind: "wait", params: ["selector": .string("#ready")]).identity == nil)
    for value in [JSONValue.null, .integer(1), .string(""), .string("has space"), .string(String(repeating: "x", count: 129))] {
        #expect(throws: RPCFailure.self) {
            try WebAction(kind: "snapshot", params: ["expectedViewId": value, "expectedDocumentId": .string("document")])
        }
    }
    #expect(throws: RPCFailure.self) { try WebAction(kind: "snapshot", params: ["expectedDocumentId": .string("document")]) }
    #expect(throws: RPCFailure.self) {
        try WebAction(kind: "snapshot", params: ["expectedViewId": .string("view"), "expectedDocumentId": .string("document"), "maxElements": .integer(257)])
    }
    #expect(throws: RPCFailure.self) { try WebAction(kind: "snapshot", params: ["expectedDocumenId": .string("typo")]) }
}
