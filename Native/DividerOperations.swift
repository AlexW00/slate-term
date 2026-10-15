import AppKit
import SlateTermCore

@MainActor
final class NativeDividerGesture {
    weak var controller: WorkspaceSplitController?
    weak var window: WorkspaceWindow?
    let tab: TabID
    let path: [Branch]
    let layoutRevision: String
    let bounds: NSRect
    let scale: CGFloat
    let operation = WorkspaceOperationContext(origin: .native)
    var fraction: Double

    init(controller: WorkspaceSplitController, window: WorkspaceWindow, tab: TabID, path: [Branch], revision: String, fraction: Double) {
        self.controller = controller; self.window = window
        self.tab = tab; self.path = path; layoutRevision = revision
        bounds = controller.splitView.bounds; scale = window.backingScaleFactor
        self.fraction = fraction
    }
}

@MainActor
extension WorkspaceHost {
    func splitController(tab: TabID, path: [Branch]) -> WorkspaceSplitController? {
        var current = windows[tab]?.contentViewController
        for branch in path {
            guard let split = current as? WorkspaceSplitController, split.splitViewItems.count == 2 else { return nil }
            current = split.splitViewItems[branch == .first ? 0 : 1].viewController
        }
        return current as? WorkspaceSplitController
    }

    func beginNativeDivider(_ controller: WorkspaceSplitController, tab: TabID, path: [Branch]) -> ClosedRange<Double>? {
        guard canHandleNativeDivider, !settlingNativeLayouts else { return nil }
        do {
            drainNativeLayouts()
            try finishNativeDivider(cancelled: false)
            guard splitController(tab: tab, path: path) === controller,
                  let model = workspace.tabs.first(where: { $0.id == tab }), model.zoomedPane == nil,
                  rendered[tab] == model.layout, let window = windows[tab],
                  window.isVisible, window.isKeyWindow, !window.isMiniaturized,
                  (window.tabGroup?.selectedWindow ?? window) === window,
                  controller.view.window === window, !controller.view.isHiddenOrHasHiddenAncestor,
                  let revision = revisions.layoutRevision(tab),
                  case .split(_, let fraction, _, _) = try model.layout.node(at: path),
                  let content = window.contentView else { return nil }
            let node = try model.layout.node(at: path)
            let divider = Double(controller.splitView.dividerThickness)
            var size = LayoutSizing.Size(width: content.bounds.width, height: content.bounds.height)
            var projected = model.layout
            for branch in path {
                guard case .split(let axis, let fraction, let first, let second) = projected else { return nil }
                let available = (axis == .horizontal ? size.width : size.height) - divider
                let leading = available * fraction
                let extent = branch == .first ? leading : available - leading
                if axis == .horizontal { size.width = extent } else { size.height = extent }
                projected = branch == .first ? first : second
            }
            // Both API projection and actual pixel-rounded node bounds must fit. A nested
            // native node can differ from its model projection by a backing pixel.
            let modelRange = try LayoutSizing.resizeRange(of: node, in: size, divider: divider)
            let nativeRange = try LayoutSizing.resizeRange(of: node, in: .init(width: controller.splitView.bounds.width, height: controller.splitView.bounds.height), divider: divider)
            let lower = max(modelRange.lowerBound, nativeRange.lowerBound)
            let upper = min(modelRange.upperBound, nativeRange.upperBound)
            guard lower <= upper else { return nil }
            dividerGesture = NativeDividerGesture(controller: controller, window: window, tab: tab, path: path, revision: revision, fraction: fraction)
            return lower...upper
        } catch { NSLog("Divider begin rejected: %@", String(describing: error)); return nil }
    }

    func previewNativeDivider(_ controller: WorkspaceSplitController, fraction: Double) {
        guard let gesture = dividerGesture, gesture.controller === controller else { return }
        guard nativeDividerIsCurrent(gesture) else { try? finishNativeDivider(cancelled: true); return }
        gesture.fraction = fraction
    }

    func endNativeDivider(_ controller: WorkspaceSplitController, cancelled: Bool) {
        guard dividerGesture?.controller === controller else { return }
        do { try finishNativeDivider(cancelled: cancelled) }
        catch { NSLog("Divider completion rejected: %@", String(describing: error)) }
    }

    private func nativeDividerIsCurrent(_ gesture: NativeDividerGesture) -> Bool {
        guard canHandleNativeDivider, let controller = gesture.controller, let window = gesture.window,
              splitController(tab: gesture.tab, path: gesture.path) === controller,
              windows[gesture.tab] === window, controller.view.window === window,
              controller.splitView.bounds == gesture.bounds, window.backingScaleFactor == gesture.scale,
              window.isVisible, window.isKeyWindow, !window.isMiniaturized, !controller.view.isHiddenOrHasHiddenAncestor,
              (window.tabGroup?.selectedWindow ?? window) === window,
              revisions.layoutRevision(gesture.tab) == gesture.layoutRevision,
              workspace.tabs.first(where: { $0.id == gesture.tab })?.zoomedPane == nil else { return false }
        return true
    }

    func finishNativeDivider(cancelled: Bool) throws {
        guard let gesture = dividerGesture else { return }
        // Consume before any reconciliation, notifications or recursively entered dispatch.
        dividerGesture = nil
        gesture.controller?.retireGesture()
        func restore() {
            guard canHandleNativeDivider, let controller = gesture.controller, !controller.isDetaching,
                  splitController(tab: gesture.tab, path: gesture.path) === controller,
                  let model = workspace.tabs.first(where: { $0.id == gesture.tab }),
                  let node = try? model.layout.node(at: gesture.path) else { return }
            _ = controller.applyModelFractions(node)
        }
        guard !cancelled, nativeDividerIsCurrent(gesture) else { restore(); return }
        do { try commitNativeDivider(gesture) }
        catch { restore(); throw error }
    }

    func settleDividerBeforeMutation(_ method: String) throws {
        // Reads continue to see the authoritative model, with tab geometry withheld.
        // These entry points can change/reparent presentation; settle before their guards.
        if ["layouts.open", "layouts.capture", "command.run", "pane.title", "config.patch", "config.reload", "plugins.register", "plugins.unregister", "plugins.restart", "plugins.settings.patch"].contains(method) {
            try finishNativeDivider(cancelled: false)
        }
    }

    /// Integration-only input injection. Holds one bounded old controller so tests can
    /// deliver a late mouse-up to the retired view rather than retarget its replacement.
    func debugDividerGesture(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let phase = params["phase"]?.string, ["begin", "move", "end", "cancel"].contains(phase) else { throw RPCFailure(code: -32602, message: "A divider phase is required") }
        if phase == "begin" {
            let tab = try targetTab(params)
            let path = try JSONDecoder().decode([Branch].self, from: JSONEncoder().encode(params["path"] ?? .array([])))
            guard path.count <= 64, let split = splitController(tab: tab.id, path: path), split.onGestureBegin != nil,
                  let window = windows[tab.id] else { throw RPCFailure(code: APIError.unavailable, message: "Live divider is unavailable") }
            dividerFixture = (split, window, tab.id)
        }
        guard let target = dividerFixture else { throw RPCFailure(code: APIError.unavailable, message: "Begin an owned divider sequence first") }
        let split = target.controller.splitView
        let length = (split.isVertical ? split.bounds.width : split.bounds.height) - split.dividerThickness
        var position = split.arrangedSubviews.first.map { split.isVertical ? $0.frame.width : $0.frame.height } ?? 0
        if phase == "move" {
            let fraction: Double
            switch params["fraction"] {
            case .number(let value) where value.isFinite: fraction = value
            case .integer(let value): fraction = Double(value)
            default: throw RPCFailure(code: -32602, message: "A finite fraction is required")
            }
            position = length * fraction
        }
        position += split.dividerThickness / 2
        let point = split.isVertical ? NSPoint(x: split.bounds.minX + position, y: split.bounds.midY)
            : NSPoint(x: split.bounds.midX, y: split.isFlipped ? split.bounds.minY + position : split.bounds.maxY - position)
        let windowPoint = split.convert(point, to: nil)
        if phase == "cancel" { target.controller.cancelGesture() }
        else {
            let type: NSEvent.EventType = phase == "begin" ? .leftMouseDown : phase == "move" ? .leftMouseDragged : .leftMouseUp
            let event = NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: target.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: phase == "end" ? 0 : 1)!
            if phase == "begin" {
                _ = split.hitTest(split.superview?.convert(windowPoint, from: nil) ?? point)
                split.mouseDown(with: event)
            } else if phase == "move" { split.mouseDragged(with: event) }
            else { split.mouseUp(with: event); dividerFixture = nil }
        }
        let panes = workspace.tabs.first(where: { $0.id == target.tab })?.layout.paneIDs ?? []
        return .object(["active": .bool(dividerGesture != nil), "backingScale": .number(target.window.backingScaleFactor), "leaves": .array(panes.compactMap { pane in
            guard let view = containers[pane]?.view else { return nil }
            return .object(["paneId": .string(pane.description), "width": .number(view.bounds.width), "height": .number(view.bounds.height)])
        })])
    }
}
