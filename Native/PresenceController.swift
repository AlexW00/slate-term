import AppKit
import SlateTermCore
import SlateTermSettings

/// Tracks agent activity on panes, pushes it to pane overlays and publishes
/// value-free `host.presence.changed` transitions.
@MainActor
final class PresenceController {
    struct Handle {
        let call: PresenceTracker.Call
        let pane: PaneID
        /// Only element actions report a rectangle; eval results are page data, never geometry.
        let reportsElement: Bool
    }

    static let descriptor: JSONValue = AutomationCapabilities.presence

    private weak var host: WorkspaceHost?
    private var tracker = PresenceTracker()
    private var timer: Timer?
    private let start = ContinuousClock.now

    init(host: WorkspaceHost) { self.host = host }

    private var now: Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    // MARK: Calls

    /// Starts presence for an agent call that acts on another pane. Presence never fails a call.
    func begin(actor: PresenceActor, pane: PaneID, method: String, action: PresenceAction) -> Handle? {
        guard pane.description != actor.home else { return nil }
        let (call, transitions) = tracker.begin(actor: actor, pane: pane.description, action: action, now: now)
        publish(transitions)
        render()
        let element = (method.hasPrefix("web.") || method.hasPrefix("browser.")) && (action == .write || action == .wait)
        return call.map { Handle(call: $0, pane: pane, reportsElement: element) }
    }

    func end(_ handle: Handle, result: JSONValue?, failed: Bool) {
        let outcome: PresenceResult
        if failed { outcome = .failed(nil) }
        else if case .integer(let code)? = result?.object?["exitCode"], code != 0 { outcome = .failed("exit \(code)") }
        else { outcome = .ok(nil) }
        let element = failed || !handle.reportsElement ? nil : result.flatMap { elementRect(pane: handle.pane, result: $0) }
        tracker.end(handle.call, result: outcome, element: element, now: now)
        render()
    }

    /// Converts a web action's CSS-pixel rectangle into the pane container's top-left space.
    private func elementRect(pane: PaneID, result: JSONValue) -> PresenceRect? {
        guard let fields = result.object, let rect = fields["rect"]?.object, let viewport = fields["viewport"]?.object,
              let x = rect["x"]?.double, let y = rect["y"]?.double, let width = rect["width"]?.double, let height = rect["height"]?.double,
              let viewportWidth = viewport["width"]?.double, viewportWidth > 0,
              let host, let container = host.containers[pane],
              let web = (host.leaves[pane] as? BrowserPane)?.web ?? (host.leaves[pane] as? PluginPane)?.web else { return nil }
        // Page zoom and magnification both scale CSS pixels by the same factor.
        let scale = web.bounds.width / viewportWidth
        var inWeb = NSRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
        if !web.isFlipped { inWeb.origin.y = web.bounds.height - inWeb.maxY }
        let visible = inWeb.intersection(web.bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        var converted = web.convert(visible, to: container.view)
        if !container.view.isFlipped { converted.origin.y = container.view.bounds.height - converted.maxY }
        return PresenceRect(x: converted.minX, y: converted.minY, width: converted.width, height: converted.height)
    }

    // MARK: API

    func list() -> JSONValue {
        sweep()
        let current = now
        let activities: [JSONValue] = tracker.display(now: current).map { item in
            let record = item.record
            var fields: [String: JSONValue] = [
                "activityId": .string(record.id), "actor": .string(record.actor), "label": .string(item.label),
                "pane": .string(record.pane), "actionKind": .string(record.action.rawValue), "count": .integer(record.count),
                "canFocus": .bool(originPane(record) != nil),
                "live": .bool(record.isLive), "leased": .bool(record.isLeased), "element": .bool(record.element != nil),
            ]
            if let note = record.note { fields["note"] = .string(note) }
            if let home = record.home { fields["home"] = .string(home) }
            if let pane = try? PaneID(parsing: record.pane), let tab = host?.workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane) }) {
                fields["tab"] = .string(tab.id.description)
            }
            if let lease = record.leaseUntil { fields["leaseExpiresInMilliseconds"] = .integer(max(0, Int((lease - current) * 1000))) }
            if let result = record.result {
                switch result {
                case .ok: fields["result"] = .string("ok")
                case .failed: fields["result"] = .string("failed")
                }
            }
            return .object(fields)
        }
        return .object(["visible": .bool(host?.settings.current.showAgentActivity ?? true), "activities": .array(activities)])
    }

    func hold(pane: PaneID, params: [String: JSONValue], actor: PresenceActor?) throws -> JSONValue {
        let actor = try requireActor(actor, method: "presence.hold")
        guard pane.description != actor.home else { throw RPCFailure(code: -32602, message: "An agent's own pane never shows presence; hold another pane") }
        var seconds = PresenceTracker.defaultLeaseSeconds
        if let value = params["ttlSeconds"] {
            guard let number = value.double, number.isFinite, (1...PresenceTracker.maximumLeaseSeconds).contains(number) else {
                throw RPCFailure(code: -32602, message: "ttlSeconds must be a number from 1 to \(Int(PresenceTracker.maximumLeaseSeconds))")
            }
            seconds = number
        }
        let (record, transitions) = tracker.hold(actor: actor, pane: pane.description, seconds: seconds, now: now)
        guard let record else { throw RPCFailure(code: APIError.unavailable, message: "Too many active presence records") }
        publish(transitions)
        render()
        return .object(["activityId": .string(record.id), "pane": .string(pane.description),
                        "expiresInMilliseconds": .integer(Int(seconds * 1000))])
    }

    func release(pane: PaneID, actor: PresenceActor?) throws -> JSONValue {
        let actor = try requireActor(actor, method: "presence.release")
        let released = tracker.release(actor: actor, pane: pane.description, now: now)
        render()
        return .object(["released": .bool(released), "pane": .string(pane.description)])
    }

    /// Never resolve a missing/stale home through terminal history or current focus.
    private func originPane(_ record: PresenceRecord) -> PaneID? {
        guard let host, let origin = record.origin, origin.instanceID == host.instanceID,
              let home = record.home, let pane = try? PaneID(parsing: home),
              host.workspace.panes.contains(where: { $0.id == pane && $0.type == .terminal }),
              host.terminals[pane] != nil, host.shellSessions[pane]?.instanceID == origin.sessionID else { return nil }
        return pane
    }

    func focus(activityID: String, operation: WorkspaceOperationContext) throws -> JSONValue {
        try operation.validateCaller()
        sweep()
        guard let host, let record = tracker.records.first(where: { $0.id == activityID }),
              let pane = originPane(record), let origin = record.origin else {
            return .object(["focused": .bool(false)])
        }
        return try host.focusPresencePane(pane, origin: origin, operation: operation)
    }

    private func requireActor(_ actor: PresenceActor?, method: String) throws -> PresenceActor {
        guard let actor else {
            throw RPCFailure(code: -32602, message: "\(method) requires an agent identity, which only administrative clients such as the CLI can supply: set SLATE_TERM_ACTOR or pass --actor, without --cause")
        }
        return actor
    }

    // MARK: Rendering

    /// Pushes current records to pane overlays and keeps a timer while anything is shown.
    /// Ends records for closed panes and finished activity.
    private func sweep() {
        guard let host else { return }
        publish(tracker.removePanes(notIn: Set(host.workspace.panes.map(\.id.description))))
        publish(tracker.expire(now: now))
    }

    func render() {
        guard let host else { return }
        sweep()
        let current = now
        let shown = host.settings.current.showAgentActivity
        var byPane: [PaneID: [PresenceOverlayItem]] = [:]
        if shown {
            for item in tracker.display(now: current) {
                guard let pane = try? PaneID(parsing: item.record.pane) else { continue }
                byPane[pane, default: []].append(Self.overlayItem(item, originPane: originPane(item.record)))
            }
        }
        for (pane, container) in host.containers {
            let items = byPane[pane] ?? []
            container.onActivatePresence = { [weak self] id in
                _ = try? self?.focus(activityID: id, operation: WorkspaceOperationContext(origin: .native))
            }
            var bottomInset: CGFloat = 0
            if let web = (host.leaves[pane] as? BrowserPane)?.web, web.superview != nil {
                let frame = web.convert(web.bounds, to: container.view)
                bottomInset = max(0, container.view.isFlipped ? container.view.bounds.maxY - frame.maxY : frame.minY)
            }
            container.setPresence(items, contentBottomInset: bottomInset)
        }
        schedule()
    }

    private static func overlayItem(_ item: PresenceDisplay, originPane: PaneID?) -> PresenceOverlayItem {
        let record = item.record
        let status: PresenceOverlayItem.Status
        if record.isLeased { status = .held }
        else if let elapsed = item.elapsed { status = .live(String(format: "%.1fs", elapsed)) }
        else if let result = record.result {
            switch result {
            case .ok(let text): status = .ok(text)
            case .failed(let text): status = .failed(text)
            }
        } else { status = .active }
        let element = record.element.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        // Activity IDs are "a<sequence>", so they also give a stable arrival order.
        let order = Int(record.id.dropFirst()) ?? 0
        return PresenceOverlayItem(id: record.id, label: item.label, note: record.note, rgb: PresenceColor.rgb(for: record.actorKey),
                                   status: status, element: element, pulse: record.pulse, order: order, originPane: originPane?.description)
    }

    /// Ticks at 5 Hz only while an elapsed time is shown; otherwise wakes once at the next expiry.
    private func schedule() {
        timer?.invalidate()
        timer = nil
        let current = now
        let delay: Double
        if tracker.hasElapsedDisplay(now: current) { delay = 0.2 }
        else if let deadline = tracker.nextDeadline { delay = max(0.05, deadline - current + 0.01) }
        else { return }
        let created = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        RunLoop.main.add(created, forMode: .common)
        timer = created
    }

    private func publish(_ transitions: [PresenceTransition]) {
        guard let host else { return }
        for transition in transitions {
            let pane = try? PaneID(parsing: transition.record.pane)
            let tab = pane.flatMap { pane in host.workspace.tabs.first { $0.layout.paneIDs.contains(pane) }?.id }
            host.events.publishHost("host.presence.changed", payload: transition.payload, tab: tab, pane: tab == nil ? nil : pane)
        }
    }

    /// Integration probe of what each pane overlay currently shows.
    func testingState() -> JSONValue {
        guard let host else { return .object([:]) }
        return .object(Dictionary(uniqueKeysWithValues: host.containers.map { ($0.key.description, $0.value.presenceTestingState) }))
    }
}

extension JSONValue {
    var double: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .number(let value): value
        default: nil
        }
    }
}
