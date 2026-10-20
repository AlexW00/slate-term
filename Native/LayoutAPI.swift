import AppKit
import SlateTermCore

@MainActor
extension WorkspaceHost {
    func validateMutationAdmission(_ id: String, params: [String: JSONValue]) throws {
        if WorkspaceMutationCommand.layoutGuarded.contains(id), params["expectedLayoutRevision"]?.string == nil {
            throw RPCFailure(code: -32602, message: "expectedLayoutRevision is required; inspect the target layout first")
        }
        if id == "pane.move" {
            guard let raw = params["target"]?.string else { throw RPCFailure(code: -32602, message: "target pane is required") }
            let target = try PaneID(parsing: raw)
            let source = try targetTab(params)
            let destination: Tab
            do { destination = try workspace.resolvedTab(pane: target) }
            catch { throw RPCFailure(code: APIError.unavailable, message: "Destination pane no longer exists") }
            if source.id != destination.id, params["expectedWorkspaceRevision"]?.string == nil {
                throw RPCFailure(code: -32602, message: "Cross-tab pane.move requires expectedWorkspaceRevision; inspect the workspace first")
            }
        }
        if WorkspaceMutationCommand.workspaceGuarded.contains(id), params["expectedWorkspaceRevision"]?.string == nil {
            throw RPCFailure(code: -32602, message: "expectedWorkspaceRevision is required; inspect the workspace first")
        }
    }

    func mutationFrames(layout: Layout, tab: TabID) -> [PaneID: NSRect]? {
        guard dividerGesture?.tab != tab, !nativeGeometryUnavailable(tab), let window = windows[tab],
              let displayed = window.tabGroup?.selectedWindow ?? windows[tab],
              displayed.isVisible, !displayed.isMiniaturized,
              let content = displayed.contentView,
              content.bounds.width.isFinite, content.bounds.height.isFinite,
              content.bounds.width > 0, content.bounds.height > 0 else { return nil }
        let divider = (window.contentViewController as? WorkspaceSplitController)?.splitView.dividerThickness
            ?? WorkspaceSplitController(fraction: 0.5).splitView.dividerThickness
        return PaneMoveGeometry.frames(for: layout, in: content.convert(content.bounds, to: nil), divider: divider)
    }

    func validateMutationGeometry(_ id: String, params: [String: JSONValue], next: Workspace, result: JSONValue) throws {
        guard WorkspaceMutationCommand.layoutGuarded.contains(id) || id.hasPrefix("split.") else { return }
        let sourceTab = try targetTab(params)
        let tab: Tab
        if id == "pane.move" {
            guard mutationFrames(layout: sourceTab.layout, tab: sourceTab.id) != nil,
                  let raw = params["target"]?.string else { throw RPCFailure(code: APIError.unavailable, message: "Source layout is unavailable") }
            tab = try workspace.resolvedTab(pane: PaneID(parsing: raw))
        } else { tab = sourceTab }
        guard let layout = next.tabs.first(where: { $0.id == tab.id })?.layout,
              let frames = mutationFrames(layout: layout, tab: tab.id) else {
            throw RPCFailure(code: APIError.unavailable, message: "Native layout geometry is unavailable")
        }
        let affected: [PaneID]
        if id == "pane.move" {
            affected = [try targetPaneID(params), try PaneID(parsing: params["target"]!.string!)]
        } else if id == "layout.resize" {
            let path = try JSONDecoder().decode([Branch].self, from: JSONEncoder().encode(params["path"]!))
            affected = try layout.node(at: path).paneIDs
        } else if params["target"] == .string("root") { affected = layout.paneIDs }
        else {
            affected = [try targetPaneID(params), try PaneID(parsing: result.object!["paneId"]!.string!)]
        }
        guard affected.allSatisfy({ id in
            guard let rect = frames[id] else { return false }
            return rect.width >= PaneMoveGeometry.minimumExtent && rect.height >= PaneMoveGeometry.minimumExtent
        }) else { throw RPCFailure(code: APIError.unavailable, message: "The requested layout would make affected panes smaller than 80 points; enlarge the window or choose another fraction") }
    }

    func splitUnavailableReason(_ id: String, params: [String: JSONValue]) -> String? {
        guard id.hasPrefix("split.") else { return nil }
        do {
            var next = workspace
            let result = try CommandRegistry.execute(id, params: params, workspace: &next)
            try validateMutationGeometry(id, params: params, next: next, result: result)
            return nil
        } catch { return (error as? RPCFailure)?.message ?? String(describing: error) }
    }

    func mutationResponse(_ id: String, result: JSONValue) -> JSONValue {
        guard WorkspaceMutationCommand.ids.contains(id), var value = result.object else { return result }
        value["workspaceRevision"] = .string(revisions.revision)
        if id == "pane.move", let raw = value["sourceTabId"]?.string, let source = try? TabID(parsing: raw) {
            value["sourceLayoutRevision"] = revisions.layoutRevision(source).map(JSONValue.string) ?? .null
        }
        if let raw = value["tabId"]?.string, let tab = try? TabID(parsing: raw), let model = workspace.tabs.first(where: { $0.id == tab }) {
            value["layoutRevision"] = revisions.layoutRevision(tab).map(JSONValue.string)
            if let raw = value["paneId"]?.string, let pane = try? PaneID(parsing: raw) {
                value["path"] = model.layout.path(to: pane).map { .array($0.map { .string($0.rawValue) }) } ?? .null
            }
        }
        return .object(value)
    }

    func nativeWindowsInfo(_ params: [String: JSONValue]) throws -> JSONValue {
        let allowed: Set<String> = ["limit", "cursor", "expectedInstanceId", "expectedWorkspaceRevision"]
        guard Set(params.keys).isSubset(of: allowed) else { throw RPCFailure(code: -32602, message: "Unknown window.list parameters") }
        let limit: Int
        if let value = params["limit"] {
            guard case .integer(let number) = value, (1...64).contains(number) else { throw RPCFailure(code: -32602, message: "limit must be 1...64") }
            limit = number
        } else { limit = 32 }
        let cursor: InspectionCursor?
        if let value = params["cursor"] {
            guard let text = value.string else { throw RPCFailure(code: -32602, message: "cursor must be a string") }
            cursor = try InspectionCursor.decode(text, revision: revisions.revision, scope: "windows")
        } else { cursor = nil }
        let tabs = workspace.tabs.filter { windows[$0.id] != nil }
        let offset = cursor?.offset ?? 0
        guard offset <= tabs.count else { throw RPCFailure(code: APIError.conflict, message: "Cursor exceeds this window snapshot") }
        let end = min(tabs.count, offset + limit)
        let eventCursor = cursor?.eventCursor ?? events.head.object!["cursor"]!.string!
        let next = end == tabs.count ? nil : try InspectionCursor(revision: revisions.revision, scope: "windows", offset: end, eventCursor: eventCursor).encoded()
        let value: JSONValue = .object([
            "appInstanceId": .string(instanceID), "workspaceRevision": .string(revisions.revision),
            "eventCursor": .string(eventCursor), "nextCursor": next.map(JSONValue.string) ?? .null,
            "totalWindows": .integer(tabs.count), "sampledAt": .number(Date().timeIntervalSince1970),
            "windows": .array(tabs[offset..<end].map { nativeWindowInfo(windows[$0.id]!, tab: $0.id) })])
        guard try JSONEncoder().encode(value).count <= 262_144 else { throw RPCFailure(code: APIError.unavailable, message: "Window snapshot exceeds its envelope bound; request a smaller page") }
        return value
    }

    func targetNativeWindow(_ params: [String: JSONValue], focusing: Bool = false) throws -> (tab: TabID, window: WorkspaceWindow) {
        guard params["pane"] == nil, params["tab"] == nil else { throw RPCFailure(code: -32602, message: "Native window operations target windowId, not pane/tab") }
        var allowed: Set<String> = ["windowId", "expectedInstanceId", "expectedWorkspaceRevision"]
        if focusing { allowed.formUnion(["id", "activate"]) }
        guard Set(params.keys).isSubset(of: allowed) else { throw RPCFailure(code: -32602, message: "Unknown native window parameters") }
        guard let id = params["windowId"]?.string else { throw RPCFailure(code: -32602, message: "windowId is required; use window.list") }
        guard let pair = windows.first(where: { $0.value.identity == id }) else { throw RPCFailure(code: APIError.unavailable, message: "Native window no longer exists") }
        return (pair.key, pair.value)
    }

    func nativeWindowInfo(_ window: WorkspaceWindow, tab: TabID) -> JSONValue {
        let frame = window.frame
        return .object(["windowId": .string(window.identity), "tabId": .string(tab.description),
                        "title": .string(workspace.tabs.first { $0.id == tab }?.title ?? workspace.defaultTabTitle),
                        "groupId": workspace.groups.first(where: { $0.tabs.contains(tab) }).map { .string($0.id.description) } ?? .null,
                        "nativeWindowNumber": .integer(window.windowNumber), "visible": .bool(window.isVisible),
                        "selected": .bool(window.tabGroup?.selectedWindow === window), "key": .bool(window.isKeyWindow),
                        "minimized": .bool(window.isMiniaturized), "fullscreen": .bool(window.styleMask.contains(.fullScreen)),
                        "presentationRevision": .string(window.presentationRevision),
                        "fullscreenTransition": .string(window.fullscreenTransition),
                        "fullscreenTransitionPending": .bool(window.fullscreenTransitionPending),
                        "visibleScreenFrame": window.screen.map { screen in .object([
                            "x": .number(screen.visibleFrame.minX), "y": .number(screen.visibleFrame.minY),
                            "width": .number(screen.visibleFrame.width), "height": .number(screen.visibleFrame.height)]) } ?? .null,
                        "screenName": window.screen.map { .string(String($0.localizedName.prefix(512))) } ?? .null,
                        "frame": .object(["x": .number(frame.minX), "y": .number(frame.minY), "width": .number(frame.width), "height": .number(frame.height),
                                          "coordinateSpace": .string("screen-global-bottom-left-points")])])
    }
}
