import AppKit
import WebKit
import SlateTermCore

extension WorkspaceHost {
    static var webMethods: [String] { AutomationMethod.publicMethods.filter { $0.family == .web }.map(\.rawValue) }

    func webAutomation(for pane: PaneID) -> WebPaneAutomation? {
        if let browser = leaves[pane] as? BrowserPane { return browser.automation }
        if let plugin = leaves[pane] as? PluginPane { return plugin.automation }
        return nil
    }

    func webRenderable(_ pane: PaneID, automation: WebPaneAutomation) throws -> Bool {
        let info = try inspectPane(pane).object!
        if let plugin = leaves[pane] as? PluginPane,
           !plugin.instance.isReady || plugin.web.url.map({ plugin.instance.origin.matches($0) }) != true { return false }
        return info["visible"] == .bool(true) && info["geometryState"] == .string("sampled")
            && automation.web.bounds.width > 0 && automation.web.bounds.height > 0
            && !automation.web.isHiddenOrHasHiddenAncestor
    }

    /// Capture eligibility is not on-screen visibility. Native tab selection may
    /// hide an otherwise attached, laid-out WKWebView; zoom-detached panes remain unavailable.
    func webScreenshotReady(_ pane: PaneID, automation: WebPaneAutomation) -> Bool {
        guard automation.ready, automation.documentID != nil,
              let tab = workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane) }),
              let window = windows[tab.id], let root = window.contentView, let container = containers[pane]?.view,
              (tab.zoomedPane == nil || tab.zoomedPane == pane),
              rendered[tab.id] == tab.layout, renderedZoom[tab.id] == tab.zoomedPane,
              !nativeGeometryUnavailable(tab.id), !window.isMiniaturized,
              container.window === window, automation.web.window === window,
              (container === root || container.isDescendant(of: root)), automation.web.isDescendant(of: container),
              !root.needsLayout, !container.needsLayout, !automation.web.needsLayout,
              !automation.web.isHiddenOrHasHiddenAncestor else { return false }
        // Allow an inactive tab, not an ordered-out/minimized window group.
        let displayed = window.tabGroup?.selectedWindow ?? window
        guard displayed.isVisible, !displayed.isMiniaturized else { return false }
        let bounds = automation.web.bounds
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return false }
        if let plugin = leaves[pane] as? PluginPane,
           !plugin.instance.isReady || plugin.web.url.map({ plugin.instance.origin.matches($0) }) != true { return false }
        return true
    }

    func callWeb(_ method: String, params: [String: JSONValue], operation: WorkspaceOperationContext) async throws -> JSONValue {
        guard AutomationMethod(rawValue: method)?.family == .web else {
            throw RPCFailure(code: -32601, message: "Unknown web method")
        }
        guard params["pane"]?.string != nil else { throw RPCFailure(code: -32602, message: "Web methods require an explicit pane") }
        let pane = try targetPaneID(params)
        guard let controller = leaves[pane], let automation = webAutomation(for: pane) else {
            throw RPCFailure(code: APIError.unavailable, message: "Target pane does not support web automation")
        }
        let tab = try workspace.resolvedTab(pane: pane).id
        let captured = params.merging(["tab": .string(tab.description)]) { _, new in new }
        let screenshot = method == "web.screenshot"
        let captureBounds = automation.web.bounds
        let captureLayoutRevision = revisions.layoutRevision(tab)
        let validate: @MainActor () throws -> Void = { [weak self, weak controller, weak automation] in
            try Task.checkCancellation()
            guard let self, let controller, let automation, self.leaves[pane] === controller,
                  self.webAutomation(for: pane) === automation else {
                throw RPCFailure(code: APIError.conflict, message: "Web pane was replaced")
            }
            try operation.validateCaller()
            try self.validateAPIGuards(captured, method: method)
            if screenshot {
                guard self.webScreenshotReady(pane, automation: automation) else {
                    throw RPCFailure(code: APIError.unavailable, message: "Web document is not ready for an attached viewport screenshot")
                }
                guard automation.web.bounds == captureBounds, self.revisions.layoutRevision(tab) == captureLayoutRevision else {
                    throw RPCFailure(code: APIError.conflict, message: "Web screenshot layout changed; inspect again")
                }
            } else if method != "web.get" {
                guard automation.ready, automation.documentID != nil, try self.webRenderable(pane, automation: automation) else {
                    throw RPCFailure(code: APIError.unavailable, message: "Web document is not ready and renderable")
                }
            }
        }
        try validate()
        var input = withoutAPIGuards(params)
        let expected = try WebIdentity.expected(in: params)
        let result: JSONValue
        switch method {
        case "web.get":
            guard Set(input.keys).isSubset(of: ["pane", "tab"]) else { throw RPCFailure(code: -32602, message: "Unknown web.get parameter") }
            var info = try await automation.inspect(expected: expected, beforeSubmission: validate).object!
            let url = automation.web.url?.absoluteString ?? "", title = automation.web.title ?? ""
            info["url"] = .string(String(String.UnicodeScalarView(url.unicodeScalars.prefix(8192))))
            info["title"] = .string(String(String.UnicodeScalarView(title.unicodeScalars.prefix(512))))
            info["truncated"] = .bool(!url.unicodeScalars.dropFirst(8192).isEmpty || !title.unicodeScalars.dropFirst(512).isEmpty)
            info["renderable"] = .bool(try webRenderable(pane, automation: automation))
            info["screenshotReady"] = .bool(webScreenshotReady(pane, automation: automation))
            result = .object(info)
        case "web.screenshot":
            guard Set(input.keys).isSubset(of: ["pane", "tab", "path"]), let path = input["path"]?.string,
                  path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\0") else {
                throw RPCFailure(code: -32602, message: "An absolute screenshot path of at most 4096 bytes is required")
            }
            let identity = try await automation.inspect(expected: expected, beforeSubmission: validate).object!
            result = try await automation.screenshot(to: path, beforeSubmission: {
                try validate()
                guard identity["documentId"] == automation.documentID.map(JSONValue.string) else {
                    throw RPCFailure(code: APIError.conflict, message: "Web document changed before screenshot output")
                }
            })
        default:
            input["expectedViewId"] = params["expectedViewId"]
            input["expectedDocumentId"] = params["expectedDocumentId"]
            let action = try WebAction(kind: String(method.dropFirst("web.".count)), params: input)
            result = try await automation.automate(action.action, expected: action.identity, requireReady: true, beforeSubmission: validate)
        }
        var value = result.object ?? [:]
        value["paneId"] = .string(pane.description)
        value["viewId"] = .string(automation.viewID)
        if method == "web.screenshot" { value["documentId"] = automation.documentID.map(JSONValue.string) ?? .null }
        value["sampledAt"] = .number(Date().timeIntervalSince1970)
        return .object(value)
    }
}
