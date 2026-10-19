import Foundation
import Testing
@testable import SlateTermCore
import SlateTermTestSupport

@Test func webActionContractsMatchPairedIdentityRefsAndLegacyDOMInputs() throws {
    let definitions = AutomationContracts.webDefinitions
    let samples: [(String, [String: JSONValue])] = [
        ("snapshot", [:]), ("snapshot", ["maxElements": .integer(257)]),
        ("click", ["selector": .string("#submit")]), ("click", ["ref": .string("view:document:1")]),
        ("click", ["ref": .string("view:document:01")]), ("click", ["ref": .string("view:document:18446744073709551616")]),
        ("click", ["ref": .string("view:document:1"), "selector": .string("#submit")]),
        ("fill", ["selector": .string("#text"), "text": .string("")]), ("fill", ["selector": .string("#text")]),
        ("fill", ["ref": .string("view:document:1"), "text": .string(String(repeating: "a", count: 65_537))]),
        ("select", ["ref": .string("view:document:1"), "values": .array([])]),
        ("select", ["ref": .string("view:document:1"), "values": .array([.null])]),
        ("scroll", [:]), ("scroll", ["x": .number(-0.5), "y": .integer(10_000_001)]),
        ("scroll", ["ref": .string("view:document:1"), "x": .integer(4)]),
        ("wait", ["selector": .string("#ready"), "timeoutMilliseconds": .integer(0)]),
        ("wait", ["selector": .string("#ready"), "state": .string("gone")])
    ]
    for (kind, payload) in samples {
        let routed = payload.merging(["pane": .string("p1")]) { _, value in value }
        let browserMethod = AutomationMethod(rawValue: "browser." + kind)!
        let webMethod = AutomationMethod(rawValue: "web." + kind)!
        #expect(schemaAccepts(AutomationContracts.web[browserMethod]!.input, .object(routed), definitions: definitions)
            == ((try? BrowserAction(kind: kind, params: routed)) != nil))
        let guardSamples: [[String: JSONValue]] = [[:], ["expectedViewId": .string("view")],
            ["expectedViewId": .string("view"), "expectedDocumentId": .string("document")],
            ["expectedViewId": .string("other"), "expectedDocumentId": .string("document")]]
        for guards in guardSamples {
            let guarded = routed.merging(guards) { _, value in value }
            #expect(schemaAccepts(AutomationContracts.web[webMethod]!.input, .object(guarded), definitions: definitions)
                == ((try? WebAction(kind: kind, params: guarded)) != nil))
        }
    }
}

@Test func webContractsKeepLegacyFallbackAndScreenshotBoundariesDistinct() {
    let methods = AutomationContracts.web
    #expect(Set(methods.keys) == Set(AutomationMethod.publicMethods.filter { $0.rawValue.hasPrefix("web.") || $0.rawValue.hasPrefix("browser.") }))
    #expect(schemaAccepts(methods[.browserGet]!.input, .object(["ignored": .bool(true)])))
    #expect(!schemaAccepts(methods[.webGet]!.input, .object([:])))
    #expect(!schemaAccepts(methods[.webGet]!.input, .object(["contextPane": .string("p1")])))
    #expect(!schemaAccepts(methods[.webGet]!.input, .object(["pane": .string("p1"), "ignored": .bool(true)])))
    let resolved = AutomationMethod.webGet.resolving([:], defaults: .init(pane: PaneID(1), tab: TabID(1)))
    #expect(schemaAccepts(methods[.webGet]!.input, .object(resolved)))
    #expect(!schemaAccepts(methods[.browserGet]!.input, .object(["expectedViewId": .string("view"), "expectedDocumentId": .string("document")])))
    for path in ["relative.png", "", "/tmp/capture.png", "/tmp/\0capture", "/" + String(repeating: "a", count: 4096)] {
        let input: JSONValue = .object(["pane": .string("p1"), "path": .string(path)])
        #expect(schemaAccepts(methods[.browserScreenshot]!.input, input))
        #expect(schemaAccepts(methods[.webScreenshot]!.input, input) == (path.hasPrefix("/") && path.utf8.count <= 4096 && !path.contains("\0")))
    }
    let navigation = methods[.browserNavigate]!.input
    #expect(schemaAccepts(navigation, .object(["url": .string(" example.test/path ")])))
    #expect(!schemaAccepts(navigation, .object(["url": .string("javascript:alert(1)://")])))
}

@Test func browserDataContractsKeepAllProfileAndExplicitSiteRequestsDistinct() throws {
    let all = AutomationContracts.web[.browserClearData]!
    let site = AutomationContracts.web[.browserClearSiteData]!
    #expect(schemaAccepts(all.input, .object([:])))
    #expect(!schemaAccepts(all.input, .object(["pane": .string("p1")])))
    #expect(!schemaAccepts(site.input, .object(["url": .string("https://example.test")])))
    for url in ["https://EXAMPLE.test./path", "https://[::1]:8080/", "http://user:pass@example.test", "example.test", "about:blank", "file:///tmp/test", "https://example.test/%zz", "https://example.test/with space"] {
        let params: [String: JSONValue] = ["pane": .string("p1"), "url": .string(url)]
        #expect(schemaAccepts(site.input, .object(params)) == ((try? BrowserDataRequest(kind: .site, params: params)) != nil))
    }
    let request = try BrowserDataRequest(kind: .site, params: ["pane": .string("p1"), "url": .string("https://EXAMPLE.test./path")])
    #expect(schemaAccepts(site.result, .object(["cleared": .bool(true), "scope": .string("site"), "storage": .string("private"), "host": .string(request.host!)]), definitions: AutomationContracts.webDefinitions))
    #expect(!schemaAccepts(all.result, .object(["cleared": .bool(true), "scope": .string("all"), "storage": .string("private"), "host": .null]), definitions: AutomationContracts.webDefinitions))
}

@Test func webResultContractsDistinguishDOMUTF16ClippingAndNativeScalarClipping() {
    let definitions = AutomationContracts.webDefinitions
    var element: [String: JSONValue] = ["ref": .string("view:document:1"), "tag": .string("button"), "role": .string("button"),
        "name": .string(String(repeating: "😀", count: 128)), "enabled": .bool(true), "inViewport": .bool(true),
        "rect": .object(["x": .integer(0), "y": .integer(0), "width": .integer(10), "height": .integer(10)])]
    #expect(schemaAccepts(definitions["WebElement"]!, .object(element), definitions: definitions))
    element["type"] = .string("number")
    for key in ["min", "max", "step"] { element[key] = .string(String(repeating: "😀", count: 64)) }
    #expect(schemaAccepts(definitions["WebElement"]!, .object(element), definitions: definitions))
    element["step"] = .string(String(repeating: "😀", count: 65))
    #expect(!schemaAccepts(definitions["WebElement"]!, .object(element), definitions: definitions))
    element.removeValue(forKey: "step")
    element["name"] = .string(String(repeating: "😀", count: 129))
    #expect(!schemaAccepts(definitions["WebElement"]!, .object(element), definitions: definitions))
    var inspection: [String: JSONValue] = ["viewId": .string("view"), "documentId": .null, "ready": .bool(false),
        "pendingOperations": .integer(0), "pendingActions": .integer(0), "pendingSubmissions": .integer(0),
        "paneId": .string("p1"), "sampledAt": .number(1.5), "url": .string(""), "title": .string(String(repeating: "😀", count: 512)),
        "truncated": .bool(false), "renderable": .bool(false), "screenshotReady": .bool(false)]
    #expect(schemaAccepts(definitions["WebInspection"]!, .object(inspection), definitions: definitions))
    inspection["title"] = .string(String(repeating: "😀", count: 513))
    #expect(!schemaAccepts(definitions["WebInspection"]!, .object(inspection), definitions: definitions))
    let selected: JSONValue = .object(["performed": .bool(true), "values": .array((0..<65).map { .string(String($0)) }),
        "viewId": .string("view"), "documentId": .string("document"), "paneId": .string("p1"), "sampledAt": .number(1.5),
        "rect": .object(["x": .integer(0), "y": .integer(0), "width": .integer(100), "height": .integer(30)]),
        "viewport": .object(["width": .integer(800), "height": .integer(600)])])
    #expect(schemaAccepts(definitions["WebSelect"]!, selected, definitions: definitions))
    #expect(!schemaAccepts(definitions["BrowserSelect"]!, selected, definitions: definitions))
}

@Test func storedSiteContractsMatchValidationWithoutPaneTargets() throws {
    let list = AutomationContracts.web[.browserListData]!
    let remove = AutomationContracts.web[.browserRemoveSiteData]!
    #expect(schemaAccepts(list.input, .object([:])))
    #expect(schemaAccepts(list.result, .object(["storage": .string("persistent"), "sites": .array([])]), definitions: AutomationContracts.webDefinitions))
    #expect(!schemaAccepts(list.result, .object(["storage": .string("private"), "sites": .array([])]), definitions: AutomationContracts.webDefinitions))
    for params: [String: JSONValue] in [[:], ["site": .string("Example.COM")], ["site": .string("bücher.example")],
        ["site": .string("")], ["site": .null], ["site": .string("example.com\n")],
        ["site": .string(String(repeating: "界", count: 5461) + "a")],
        ["site": .string(String(repeating: "界", count: 5462))],
        ["site": .string("example.com"), "pane": .string("p1")]] {
        #expect(schemaAccepts(remove.input, .object(params)) == ((try? BrowserDataRequest(kind: .storedSite, params: params)) != nil))
    }
    for key in ["pane", "tab", "expectedAnchorSessionId", "expectedViewId", "expectedDocumentId"] {
        #expect(!schemaAccepts(list.input, .object([key: .string("x")])))
        #expect(!schemaAccepts(remove.input, .object(["site": .string("example.com"), key: .string("x")])))
    }
    #expect(schemaAccepts(remove.result, .object(["cleared": .bool(true), "scope": .string("site"), "storage": .string("persistent"), "host": .string("Example.COM")]), definitions: AutomationContracts.webDefinitions))
}
