import AppKit
import WebKit
import SlateTermCore

extension WorkspaceHost {
    static let webMethods = ["web.get", "web.snapshot", "web.click", "web.fill", "web.select", "web.scroll", "web.wait"]

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

    func callWeb(_ method: String, params: [String: JSONValue], operation: WorkspaceOperationContext) async throws -> JSONValue {
        guard Self.webMethods.contains(method) || method == "web.screenshot" else {
            throw RPCFailure(code: -32601, message: "Unknown web method")
        }
        guard params["pane"]?.string != nil else { throw RPCFailure(code: -32602, message: "Web methods require an explicit pane") }
        let pane = try targetPaneID(params)
        guard let controller = leaves[pane], let automation = webAutomation(for: pane) else {
            throw RPCFailure(code: APIError.unavailable, message: "Target pane does not support web automation")
        }
        let captured = params.merging(["tab": .string(try workspace.resolvedTab(pane: pane).id.description)]) { _, new in new }
        let validate: @MainActor () throws -> Void = { [weak self, weak controller, weak automation] in
            try Task.checkCancellation()
            guard let self, let controller, let automation, self.leaves[pane] === controller,
                  self.webAutomation(for: pane) === automation else {
                throw RPCFailure(code: APIError.conflict, message: "Web pane was replaced")
            }
            try operation.validateCaller()
            try self.validateAPIGuards(captured, method: method)
            if method != "web.get" {
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
