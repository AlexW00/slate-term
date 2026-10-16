import Testing
@testable import SlateTermCore

@Test func firstPassWebActionsRequireTargetsAndIdentity() throws {
    for (kind, payload) in [("focus", [:]), ("key", ["key": JSONValue.string("shift+tab")]),
                             ("check", ["checked": .bool(true)]), ("setValue", ["value": .string("2026-10-16")])] {
        var params = payload
        params["selector"] = .string("#target")
        #expect(throws: RPCFailure.self) { try WebAction(kind: kind, params: params) }
        params["expectedViewId"] = .string("view")
        params["expectedDocumentId"] = .string("document")
        #expect(try WebAction(kind: kind, params: params).identity != nil)
        params.removeValue(forKey: "selector")
        #expect(throws: RPCFailure.self) { try WebAction(kind: kind, params: params) }
        params["ref"] = .string("view:document:1")
        #expect(try WebAction(kind: kind, params: params).identity != nil)
    }
}

@Test func webInputValidationIsBoundedAndStrict() throws {
    for value in [JSONValue.null, .integer(1), .string("true")] {
        #expect(throws: RPCFailure.self) { try BrowserAction(kind: "check", params: ["selector": .string("input"), "checked": value]) }
    }
    for key in ["", "ctrl+ctrl+a", "cmd+a", "shift+", "unknown", "enter\n", String(repeating: "a", count: 129)] {
        #expect(throws: RPCFailure.self) { try BrowserAction(kind: "key", params: ["selector": .string("input"), "key": .string(key)]) }
    }
    for key in ["enter", "shift+tab", "ctrl+a", "ArrowDown", "escape", "space"] {
        #expect(try BrowserAction(kind: "key", params: ["selector": .string("input"), "key": .string(key)]).parameters["key"] != nil)
    }
    #expect(throws: RPCFailure.self) { try BrowserAction(kind: "setValue", params: ["selector": .string("input"), "value": .integer(1)]) }
    #expect(throws: RPCFailure.self) { try BrowserAction(kind: "setValue", params: ["selector": .string("input"), "value": .string(String(repeating: "1", count: 4097))]) }
}

@Test func windowActionsRejectAmbiguousOrInvalidGeometry() throws {
    let frame: [String: JSONValue] = ["windowId": .string("window-a"), "x": .integer(0), "y": .integer(-30), "width": .integer(900), "height": .integer(600)]
    #expect(try NativeWindowAction(command: "window.frame.set", params: frame).frame != nil)
    for key in ["x", "y", "width", "height"] {
        var bad = frame; bad[key] = .number(.infinity)
        #expect(throws: RPCFailure.self) { try NativeWindowAction(command: "window.frame.set", params: bad) }
        bad[key] = .bool(true)
        #expect(throws: RPCFailure.self) { try NativeWindowAction(command: "window.frame.set", params: bad) }
        bad.removeValue(forKey: key)
        #expect(throws: RPCFailure.self) { try NativeWindowAction(command: "window.frame.set", params: bad) }
    }
    var bad = frame; bad["width"] = .integer(0)
    #expect(throws: RPCFailure.self) { try NativeWindowAction(command: "window.frame.set", params: bad) }
    bad = frame; bad["pane"] = .string("p1")
    #expect(throws: RPCFailure.self) { try NativeWindowAction(command: "window.frame.set", params: bad) }
    #expect(throws: RPCFailure.self) { try NativeWindowAction(command: "window.fullscreen.set", params: ["windowId": .string("w"), "fullscreen": .string("true")]) }
    #expect(try NativeWindowAction(command: "window.fullscreen.set", params: ["windowId": .string("w"), "fullscreen": .bool(false)]).fullscreen == false)
}

@Test func warningSettersAreStrictAndWorkspaceIndependent() throws {
    for id in ["warnings.close.set", "warnings.type.set"] {
        #expect(CommandRegistry.commands.contains { $0.id == id })
        #expect(CommandContract.forCommand(id).workspaceIndependent)
        #expect(CommandContract.forCommand(id).required == ["suppressed"])
        for value in [true, false] { #expect(try WarningSuppression.value(command: id, params: ["suppressed": .bool(value)]) == value) }
        for value in [JSONValue.null, .integer(0), .string("false")] {
            #expect(throws: RPCFailure.self) { try WarningSuppression.value(command: id, params: ["suppressed": value]) }
        }
        #expect(throws: RPCFailure.self) { try WarningSuppression.value(command: id, params: [:]) }
    }
    #expect(try WarningSuppression.value(command: "warnings.close.reset", params: [:]) == false)
    #expect(throws: RPCFailure.self) { try WarningSuppression.value(command: "warnings.close.reset", params: ["suppressed": .bool(true)]) }
}
