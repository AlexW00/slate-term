import Foundation
import Testing
@testable import SlateTermCore

@Test func browserDataRequestsFailClosed() throws {
    for params: [String: JSONValue] in [[:], ["url": .string("https://example.com")],
        ["pane": .string("p1")], ["pane": .null, "url": .string("https://example.com")],
        ["pane": .string("p1"), "url": .null],
        ["pane": .string("p1"), "url": .string("https://example.com"), "force": .bool(true)]] {
        #expect(throws: RPCFailure.self) { try BrowserDataRequest(kind: .site, params: params) }
    }
    for url in ["example.com", "about:blank", "file:///tmp/a", "https://", "https://user:pass@example.com",
                "https://example.com:99999", "https://.", " https://example.com", "https://exa mple.com", "https://example.com\n", "https://example.com/bad%xy"] {
        #expect(throws: RPCFailure.self) { try BrowserDataRequest(kind: .site, params: ["pane": .string("p1"), "url": .string(url)]) }
    }
    #expect(try BrowserDataRequest(kind: .all, params: [:]).host == nil)
    for key in ["pane", "tab", "url", "all", "force", "id"] {
        #expect(throws: RPCFailure.self) { try BrowserDataRequest(kind: .all, params: [key: .string("anything")]) }
    }
    #expect(try BrowserDataRequest.siteHost("HTTPS://WWW.Example.COM.:443/path?q=1#x") == "www.example.com")
    #expect(try BrowserDataRequest.siteHost("http://127.0.0.1:8080/") == "127.0.0.1")
    #expect(try BrowserDataRequest.siteHost("http://[::1]:8080/") == "::1")
    #expect(try BrowserDataRequest.siteHost("https://bücher.example/日本語") == "xn--bcher-kva.example")
}

@Test func browserPaneKindsRoundTripAndUseBuiltInSavedLayoutValidation() throws {
    for kind: PaneType in [.browser, .privateBrowser] {
        #expect(kind.isBrowser)
        #expect(PaneType(identifier: kind.identifier) == kind)
        var workspace = Workspace()
        _ = try CommandRegistry.execute("pane.type", params: ["type": .string(kind.identifier)], workspace: &workspace)
        #expect(workspace.panes[0].type == kind)
        #expect(try Workspace.restore(workspace.encoded()) == workspace)
        var layout = SavedLayoutDefinition.blank()
        layout.tabs[0].panes[0].type = kind.identifier
        layout.tabs[0].panes[0].configuration = ["url": .string("https://example.com")]
        let opening = try layout.opening(in: Workspace())
        #expect(opening.workspace.panes.last?.type == kind)
        layout.tabs[0].panes[0].configuration = ["url": .string("file:///tmp/private.html")]
        #expect(try layout.validated() == layout)
        layout.tabs[0].panes[0].configuration = ["url": .string("file://remote/tmp/private.html")]
        #expect(throws: RPCFailure.self) { try layout.validated() }
        layout.tabs[0].panes[0].configuration = ["typo": .string("bad")]
        #expect(throws: RPCFailure.self) { try layout.validated() }
        #expect(SavedLayoutPaneType.available(plugins: []).contains { $0.id == kind.identifier })
    }
}

@Test func browserDataMethodsHaveSharedMutationAndDefaultContracts() {
    let defaults = AutomationDefaults(pane: PaneID(2), tab: TabID(1))
    #expect(AutomationMethod.browserClearData.admission == .mutation)
    #expect(AutomationMethod.browserClearSiteData.admission == .mutation)
    #expect(AutomationMethod.browserClearData.resolving([:], defaults: defaults).isEmpty)
    let site = AutomationMethod.browserClearSiteData.resolving(["url": .string("https://example.com")], defaults: defaults)
    #expect(site["pane"] == .string("p2"))
    #expect(site["url"] == .string("https://example.com"))
    #expect(CommandContract.forCommand("browser.clearData").workspaceIndependent)
    #expect(!CommandContract.forCommand("browser.clearSiteData").requiresArguments) // Native URL capture.
    #expect(CommandRegistry.commands.contains { $0.id == "browser.clearData" })
    #expect(CommandRegistry.commands.contains { $0.id == "browser.clearSiteData" })
}
