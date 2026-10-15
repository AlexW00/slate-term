import AppKit
import SlateTermCore

@MainActor
final class NativeLayoutObservation {
    weak var controller: WorkspaceSplitController?
    let layoutRevision: String
    let operation = WorkspaceOperationContext(origin: .native)
    var adjustments: [[Branch]: Double] = [:]
    var presentationPaths: Set<[Branch]> = []

    init(controller: WorkspaceSplitController, revision: String) {
        self.controller = controller; layoutRevision = revision
    }
}

@MainActor
struct NativeLayoutTestProbe {
    let tab: TabID
    let pane: PaneID
    weak var container: PaneContainer?
}

@MainActor
extension WorkspaceHost {
    func queueNativeLayout(tab: TabID, source: WorkspaceSplitController, path: [Branch], fraction: Double? = nil, presentationChanged: Bool = false) {
        guard canHandleNativeDivider, !settlingNativeLayouts, dividerGesture?.tab != tab,
              splitController(tab: tab, path: path) === source,
              let root = splitController(tab: tab, path: []), let revision = revisions.layoutRevision(tab) else { return }
        let observation: NativeLayoutObservation
        if let existing = nativeLayoutPending[tab], existing.controller === root, existing.layoutRevision == revision { observation = existing }
        else {
            observation = NativeLayoutObservation(controller: root, revision: revision)
            nativeLayoutPending[tab] = observation
        }
        // An unchanged-extent native divider adjustment (including accessibility) is
        // retained. Descendant extent changes merely request fraction preservation.
        if root.presentationChangedSinceApplication { observation.presentationPaths.insert([]) }
        else if presentationChanged { observation.presentationPaths.insert(path) }
        // A parent adjustment resizes descendants, not the root presentation. Suppress
        // incidental ratios only in those descendant subtrees; preserve the ancestor's
        // genuine adjustment. A root bounds/scale change suppresses the whole tree.
        func incidental(_ path: [Branch]) -> Bool { observation.presentationPaths.contains { path.starts(with: $0) } }
        observation.adjustments = observation.adjustments.filter { !incidental($0.key) }
        if let fraction, !incidental(path) { observation.adjustments[path] = fraction }
        guard !nativeLayoutSyncScheduled else { return }
        nativeLayoutSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.nativeLayoutSyncScheduled = false
            self.drainNativeLayouts()
        }
    }

    func nativeGeometryUnavailable(_ tab: TabID) -> Bool {
        // Admission is blocked for the whole synchronous drain. The same flag is
        // sufficient for internal inspection; a second in-flight identity map is redundant.
        if settlingNativeLayouts || dividerGesture?.tab == tab { return true }
        guard let root = splitController(tab: tab, path: []) else { return false }
        if nativeLayoutPending[tab]?.controller === root { return true }
        return nativeLayoutInvalid[tab] == root.generation
    }

    func drainNativeLayouts() {
        guard canHandleNativeDivider, !settlingNativeLayouts else { return }
        nativeLayoutInvalid = nativeLayoutInvalid.filter { splitController(tab: $0.key, path: [])?.generation == $0.value }
        let pending = nativeLayoutPending
        nativeLayoutPending.removeAll()
        guard !pending.isEmpty else { return }
        settlingNativeLayouts = true
        defer {
            settlingNativeLayouts = false
            finishNativeLayoutCallbacks()
        }
        for tab in workspace.tabs.map(\.id) {
            guard let observation = pending[tab], let root = observation.controller else { continue }
            func current() -> Bool {
                splitController(tab: tab, path: []) === root
                    && revisions.layoutRevision(tab) == observation.layoutRevision
            }
            guard current(), dividerGesture?.tab != tab,
                  let window = windows[tab], root.view.window === window,
                  window.isVisible, !window.isMiniaturized,
                  (window.tabGroup?.selectedWindow ?? window) === window else { continue }
            do {
                var desired = workspace
                for (path, fraction) in observation.adjustments { try desired.resize(tab: tab, path: path, fraction: fraction) }
                guard let model = desired.tabs.first(where: { $0.id == tab }), model.zoomedPane == nil else { continue }
                root.view.layoutSubtreeIfNeeded()
                guard root.applyModelFractions(model.layout) else {
                    throw RPCFailure(code: APIError.unavailable, message: "Native split structure no longer matches the model")
                }
                guard current() else { continue }
                runNativeLayoutProbe(tab: tab)
                let observed = try root.constrainedLayout(matching: model.layout)
                // Applying native geometry can synchronously end a field editor. Use the
                // latest workspace for unrelated titles/focus, but never a replaced layout.
                guard current() else { continue }
                var next = workspace
                func importFractions(_ layout: Layout, path: [Branch]) throws {
                    guard case .split(_, let fraction, let first, let second) = layout else { return }
                    try next.resize(tab: tab, path: path, fraction: fraction)
                    try importFractions(first, path: path + [.first])
                    try importFractions(second, path: path + [.second])
                }
                try importFractions(observed, path: [])
                let transition = try WorkspaceTransition(observing: next, from: workspace, revisions: revisions, action: .nativeResize)
                try commitWorkspace(transition, operation: observation.operation)
                rendered[tab] = observed
                _ = root.applyModelFractions(observed)
                nativeLayoutInvalid.removeValue(forKey: tab)
                if transition.changed { saveNativeLayoutObservation() }
            } catch {
                guard current() else { continue }
                nativeLayoutInvalid[tab] = root.generation
                if let model = workspace.tabs.first(where: { $0.id == tab }) { _ = root.applyModelFractions(model.layout) }
                NSLog("Native layout observation unavailable: %@", String(describing: error))
            }
        }
    }
}
