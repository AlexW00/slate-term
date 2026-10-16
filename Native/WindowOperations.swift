import AppKit
import SlateTermCore

extension WorkspaceHost {
    func windowWillEnterFullScreen(_ notification: Notification) { recordFullscreen(notification.object as? WorkspaceWindow, state: "entering", pending: true) }
    func windowWillExitFullScreen(_ notification: Notification) { recordFullscreen(notification.object as? WorkspaceWindow, state: "exiting", pending: true) }
    func windowDidEnterFullScreen(_ notification: Notification) { recordFullscreen(notification.object as? WorkspaceWindow, state: "idle", pending: false) }
    func windowDidExitFullScreen(_ notification: Notification) { recordFullscreen(notification.object as? WorkspaceWindow, state: "idle", pending: false) }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { recordFullscreen(window as? WorkspaceWindow, state: "failed", pending: false) }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { recordFullscreen(window as? WorkspaceWindow, state: "failed", pending: false) }

    private func recordFullscreen(_ window: WorkspaceWindow?, state: String, pending: Bool) {
        window?.fullscreenTransition = state
        window?.fullscreenTransitionPending = pending
        observeWindowPresentation(window)
    }

    func windowDidMove(_ notification: Notification) { observeWindowPresentation(notification.object as? WorkspaceWindow) }
    func windowDidResize(_ notification: Notification) { observeWindowPresentation(notification.object as? WorkspaceWindow) }
    func windowDidMiniaturize(_ notification: Notification) { observeWindowPresentation(notification.object as? WorkspaceWindow) }
    func windowDidDeminiaturize(_ notification: Notification) { observeWindowPresentation(notification.object as? WorkspaceWindow) }

    private func observeWindowPresentation(_ window: WorkspaceWindow?) {
        guard let window, let tab = windows.first(where: { $0.value === window })?.key else { return }
        let info = nativeWindowInfo(window, tab: tab).object!
        let sample = info.filter { ["frame", "minimized", "fullscreen", "fullscreenTransition", "fullscreenTransitionPending"].contains($0.key) }
        guard sample != window.presentationSample else { return }
        window.presentationSample = sample
        window.presentationRevision = UUID().uuidString
        // Observational native callbacks, not a rollbackable workspace-model commit.
        events.publishHost("host.window.changed", payload: .object([
            "windowId": .string(window.identity), "presentationRevision": .string(window.presentationRevision),
            "workspaceRevision": .string(revisions.revision), "origin": .object(["kind": .string("native")])
        ]), tab: tab)
    }

    /// Presentation operations never rebuild the workspace or implicitly activate the app.
    func runWindowCommand(_ id: String, params: [String: JSONValue], operation: WorkspaceOperationContext) throws -> JSONValue {
        let request = try NativeWindowAction(command: id, params: withoutAPIGuards(params))
        let target = try targetNativeWindow(["windowId": .string(request.windowID)])
        // An inactive tab is not permission to mutate another tab's presentation.
        guard target.window.tabGroup?.selectedWindow == nil || target.window.tabGroup?.selectedWindow === target.window else {
            throw RPCFailure(code: APIError.unavailable, message: "Select the target tab with window.focus before changing its window")
        }
        let window = target.window
        guard window.attachedSheet == nil, !window.inLiveResize, !window.fullscreenTransitionPending else {
            throw RPCFailure(code: APIError.conflict, message: "Native window has a sheet, resize gesture or fullscreen transition in progress")
        }
        let fullscreen = window.styleMask.contains(.fullScreen)
        if id != "window.fullscreen.set", fullscreen {
            throw RPCFailure(code: APIError.unavailable, message: "Leave fullscreen before changing window frame or minimization")
        }
        var changed = false
        if let frame = request.frame {
            guard !window.isMiniaturized else { throw RPCFailure(code: APIError.unavailable, message: "Restore the window before changing its frame") }
            let desired = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            let content = window.contentRect(forFrameRect: desired)
            guard desired.width >= window.minSize.width, desired.height >= window.minSize.height,
                  content.width >= window.contentMinSize.width, content.height >= window.contentMinSize.height,
                  desired.width <= window.maxSize.width, desired.height <= window.maxSize.height,
                  NSScreen.screens.contains(where: { $0.visibleFrame.contains(desired) }) else {
                throw RPCFailure(code: -32602, message: "Frame must meet native size limits and fit entirely inside one screen's visible frame")
            }
            changed = window.frame != desired
            if changed {
                window.setFrame(desired, display: true, animate: false)
                window.contentView?.layoutSubtreeIfNeeded()
                drainNativeLayouts()
            }
        } else if let desired = request.fullscreen {
            guard !window.isMiniaturized else { throw RPCFailure(code: APIError.unavailable, message: "Restore the window before changing fullscreen state") }
            changed = fullscreen != desired
            if changed { window.toggleFullScreen(nil) }
        } else if id == "window.minimize" {
            changed = !window.isMiniaturized
            if changed { window.miniaturize(nil) }
        } else {
            changed = window.isMiniaturized
            if changed { window.deminiaturize(nil) }
        }
        try operation.validateCaller()
        guard windows[target.tab] === window else {
            throw RPCFailure(code: APIError.conflict, message: "Native window retired during presentation; inspect before further changes")
        }
        var result = nativeWindowInfo(window, tab: target.tab).object!
        result["accepted"] = .bool(true)
        result["changed"] = .bool(changed)
        let matches: Bool
        if let frame = request.frame {
            matches = window.frame == NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        } else if let desired = request.fullscreen {
            matches = window.styleMask.contains(.fullScreen) == desired
        } else { matches = window.isMiniaturized == (id == "window.minimize") }
        result["settled"] = .bool(!window.fullscreenTransitionPending && matches)
        return .object(result)
    }
}
