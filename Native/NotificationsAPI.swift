import AppKit
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    static let notificationDescriptor: JSONValue = .object([
        "version": .integer(1), "capacity": .integer(NotificationStore.capacity),
        "titleBytes": .integer(NotificationStore.titleBytes), "bodyBytes": .integer(NotificationStore.bodyBytes),
        "keyBytes": .integer(NotificationStore.keyBytes), "persistent": .bool(false),
        "postParameters": .object(["title": .string("required nonempty string"), "body": .string("optional string"),
            "key": .string("optional replacement key"), "pane": .string("optional pane ID"), "tab": .string("optional tab ID"),
            "active": .string("true, exclusive with pane/tab"), "expectedAnchorSessionId": .string("optional terminal lifetime guard")]),
        "postResultFields": .array(["id", "disposition", "reason", "retained"].map(JSONValue.string)),
        "globalRatePerSecond": .integer(5), "globalBurst": .integer(10), "sourceRatePerSecond": .integer(1), "sourceBurst": .integer(5),
        "pendingPostLimit": .integer(32), "authorizationQueryLimit": .integer(1),
        "escapeSequences": .array([.string("OSC 9"), .string("OSC 777")]),
        "automaticThresholdSeconds": .integer(30), "permissionPromptOnPost": .bool(false),
        "submissionIsDelivery": .bool(false), "listOrder": .string("oldestFirst"),
        "navigationCommands": .array([.string("notifications.next"), .string("notifications.open")]),
        "topic": .string("host.notifications.changed")])

    func configureNotificationDelivery() {
        notificationDelivery.onOpen = { [weak self] id in
            do { _ = try self?.openNotification(id: id, operation: .init(origin: .native)) }
            catch { NSLog("Notification source no longer available") }
        }
        notificationDelivery.onDismiss = { [weak self] id in self?.removeNotifications { $0.id == id } }
        notificationDelivery.mayPresent = { [weak self] id in self?.mayPresentNotification(id) == true }
    }

    func notificationAnchor(_ params: [String: JSONValue]) throws -> NotificationAnchor {
        if let active = params["active"] {
            guard active == .bool(true), params["pane"] == nil, params["tab"] == nil else {
                throw RPCFailure(code: -32602, message: "active:true is exclusive with pane/tab")
            }
            return try notificationAnchor(["pane": .string(targetPaneID([:]).description)])
        }
        if params["pane"] != nil {
            let pane = try targetPaneID(params)
            guard let lifetime = notificationLifetimes[pane],
                  let tab = workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane) }) else {
                throw RPCFailure(code: APIError.unavailable, message: "Notification source is unavailable")
            }
            return NotificationAnchor(pane: pane, tab: tab.id, lifetime: lifetime)
        }
        if params["tab"] != nil { return NotificationAnchor(tab: try targetTab(params).id) }
        return NotificationAnchor()
    }

    func notificationAnchorIsLive(_ anchor: NotificationAnchor) -> Bool {
        if let pane = anchor.paneId {
            return notificationLifetimes[pane] == anchor.lifetime && leaves[pane] != nil
                && workspace.tabs.contains { $0.layout.paneIDs.contains(pane) }
        }
        if let tab = anchor.tabId { return workspace.tabs.contains { $0.id == tab } }
        return true
    }

    func notificationSourceFocused(_ anchor: NotificationAnchor) -> Bool {
        guard NSApp.isActive, let key = NSApp.keyWindow,
              let tab = workspace.tabs.first(where: { windows[$0.id] === key }), !key.isMiniaturized else { return false }
        if let pane = anchor.paneId { return tab.focusedPane == pane && (tab.zoomedPane == nil || tab.zoomedPane == pane) }
        return anchor.tabId == tab.id
    }

    func mayPresentNotification(_ id: String) -> Bool {
        guard let record = notificationStore.records.first(where: { $0.id == id }), notificationAnchorIsLive(record.anchor) else { return false }
        // The duration threshold was already applied; a changed setting may still suppress delivery.
        return settings.current.notifications.suppression(automatic: record.automatic,
            durationNanoseconds: UInt64.max, appActive: NSApp.isActive, sourceFocused: notificationSourceFocused(record.anchor)) == nil
    }

    func callNotifications(_ method: AutomationMethod, params: [String: JSONValue], operation: WorkspaceOperationContext) async throws -> JSONValue {
        let payload = withoutAPIGuards(params)
        func requireKeys(_ allowed: Set<String>) throws {
            guard Set(payload.keys).isSubset(of: allowed) else { throw RPCFailure(code: -32602, message: "Unknown notification parameter") }
        }
        switch method {
        case .notificationsPost:
            try requireKeys(["title", "body", "key", "pane", "tab", "active"])
            guard let title = payload["title"]?.string,
                  payload["body"] == nil || payload["body"]?.string != nil,
                  payload["key"] == nil || payload["key"]?.string != nil else {
                throw RPCFailure(code: -32602, message: "title, body and key must be strings")
            }
            return try await postNotification(title: title, body: payload["body"]?.string ?? "", key: payload["key"]?.string,
                anchor: notificationAnchor(payload), source: operation.origin.value, operation: operation, guardedParams: params)
        case .notificationsList:
            try requireKeys([])
            refreshNotifications()
            // A moved pane's current tab, not its historical launch tab.
            return .array(try notificationStore.records.map { record in
                var value = try JSONValue.encoding(record).object!
                if let pane = record.anchor.paneId {
                    var anchor = value["anchor"]!.object!
                    anchor["tabId"] = workspace.tabs.first { $0.layout.paneIDs.contains(pane) }.map { .string($0.id.description) } ?? .null
                    value["anchor"] = .object(anchor)
                }
                return .object(value)
            })
        case .notificationsDismiss:
            try requireKeys(["id", "all"])
            guard (payload["id"]?.string != nil && payload["all"] == nil)
                    || (payload["id"] == nil && payload["all"] == .bool(true)) else {
                throw RPCFailure(code: -32602, message: "Dismiss requires id or all:true, exclusively")
            }
            let removed = removeNotifications(lineage: operation.lineage) { payload["all"] == .bool(true) || $0.id == payload["id"]?.string }
            return .object(["dismissed": .array(removed.map(JSONValue.string))])
        case .notificationsStatus:
            try requireKeys([])
            let authorization = await notificationDelivery.authorization()
            try operation.validateCaller()
            return .object(["authorization": .string(authorization), "policy": try .encoding(settings.current.notifications),
                "outstanding": .integer(notificationStore.records.count), "capacity": .integer(NotificationStore.capacity),
                "deliveryBackend": .string(notificationTesting ? "test" : "macOS"), "persistent": .bool(false)])
        default: throw RPCFailure(code: -32601, message: "Unknown notification operation")
        }
    }

    func postNotification(title: String, body: String, key: String?, anchor: NotificationAnchor, source: JSONValue,
                          automatic: Bool = false, duration: UInt64? = nil, commandText: String? = nil,
                          operation: WorkspaceOperationContext = .init(origin: .native),
                          guardedParams: [String: JSONValue] = [:]) async throws -> JSONValue {
        try NotificationStore.validate(title: title, body: body, key: key)
        guard notificationPending < 32 else {
            return .object(["id": .null, "disposition": .string("suppressed"), "reason": .string("overloaded"), "retained": .bool(false)])
        }
        notificationPending += 1
        defer { notificationPending -= 1 }
        let authorization = await notificationDelivery.authorization()
        try Task.checkCancellation()
        // Freeze before awaiting authorization, then validate the original content lifetime.
        try operation.validateCaller()
        try validateAPIGuards(guardedParams, method: "notifications.post")
        guard notificationsRunning, notificationAnchorIsLive(anchor) else {
            throw RPCFailure(code: APIError.unavailable, message: "Notification source was closed or replaced")
        }
        let policy = settings.current.notifications
        var reason = policy.suppression(automatic: automatic, durationNanoseconds: duration,
                                       appActive: NSApp.isActive, sourceFocused: notificationSourceFocused(anchor))
        if let reason, ["automaticDisabled", "toolsDisabled", "belowThreshold", "sourceFocused"].contains(reason) {
            return .object(["id": .null, "disposition": .string("suppressed"), "reason": .string(reason), "retained": .bool(false)])
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let budgetSource = String(decoding: try encoder.encode(source), as: UTF8.self) + "\n" + anchor.rateDestination
        guard notificationStore.admit(source: budgetSource, now: ProcessInfo.processInfo.systemUptime) else {
            return .object(["id": .null, "disposition": .string("suppressed"), "reason": .string("rateLimited"), "retained": .bool(false)])
        }
        if reason == nil, authorization != "authorized" {
            reason = authorization == "denied" ? "permissionDenied" : "permissionNotGranted"
        }
        let effectiveBody = automatic && policy.commandDetails ? body + (commandText.map { "\n" + $0 } ?? "") : body
        try NotificationStore.validate(title: title, body: effectiveBody, key: key)
        let inserted = notificationStore.insert(title: title, body: effectiveBody, key: key, source: source, anchor: anchor,
            automatic: automatic, now: Date().timeIntervalSince1970, disposition: reason == nil ? "submitted" : "suppressed", reason: reason)
        notificationDelivery.withdraw(inserted.removed)
        if reason == nil {
            notificationDelivery.submit(inserted.record, sound: policy.sound) { [weak self] success in
                guard let self, !success else { return }
                self.notificationStore.updateDelivery(id: inserted.record.id, disposition: "failed", reason: "nativeSubmissionFailed")
                self.notificationsChanged(lineage: operation.lineage)
            }
        }
        notificationsChanged(lineage: operation.lineage)
        return .object(["id": .string(inserted.record.id), "disposition": .string(inserted.record.disposition),
            "reason": reason.map(JSONValue.string) ?? .null, "retained": .bool(true)])
    }

    @discardableResult
    func removeNotifications(lineage: OperationLineage? = nil, where predicate: (SlateNotification) -> Bool) -> [String] {
        let ids = notificationStore.remove(where: predicate)
        notificationDelivery.withdraw(ids)
        if !ids.isEmpty { notificationsChanged(lineage: lineage) }
        return ids
    }

    func refreshNotifications() {
        removeNotifications { !notificationAnchorIsLive($0.anchor) || notificationSourceFocused($0.anchor) }
        updateNotificationIndicators()
    }

    func notificationsChanged(lineage: OperationLineage? = nil) {
        updateNotificationIndicators()
        events.publishHost("host.notifications.changed", payload: .object(["outstanding": .integer(notificationStore.records.count)]), lineage: lineage)
    }

    func updateNotificationIndicators() {
        let panes = Set(notificationStore.records.compactMap { $0.anchor.paneId })
        for (pane, container) in containers { container.setUnreadNotification(panes.contains(pane)) }
        for (tab, window) in windows {
            guard let model = workspace.tabs.first(where: { $0.id == tab }) else { continue }
            let hasUnread = notificationStore.records.contains { record in
                record.anchor.paneId.map(model.layout.paneIDs.contains) ?? (record.anchor.tabId == tab)
            }
            // The badge decorates presentation only; manual names and NSWindow.title stay authoritative.
            window.tab.title = (hasUnread ? "● " : "") + model.title
        }
        refreshNotificationCommandAvailability()
    }

    func openNotification(id: String?, operation: WorkspaceOperationContext) throws -> JSONValue {
        refreshNotifications()
        let record: SlateNotification?
        if let id { record = notificationStore.records.first { $0.id == id } }
        else { record = notificationStore.records.first }
        guard let record else {
            if id != nil { throw RPCFailure(code: APIError.unavailable, message: "Notification is no longer outstanding") }
            return .object(["opened": .bool(false)])
        }
        guard notificationAnchorIsLive(record.anchor) else { throw RPCFailure(code: APIError.unavailable, message: "Notification source is no longer available") }
        var next = workspace
        if let pane = record.anchor.paneId {
            // focus() reveals a zoom-hidden source and resolves its current tab.
            try next.focus(pane)
        } else if let tab = record.anchor.tabId { try next.focusTab(tab) }
        let transition = try WorkspaceTransition(observing: next, from: workspace, revisions: revisions, action: .nativeFocus)
        let persistence = try reconcileNotificationFocus(next, transition: transition, operation: operation)
        if let pane = record.anchor.paneId, let tab = workspace.tabs.first(where: { $0.layout.paneIDs.contains(pane) }), let window = windows[tab.id] {
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        } else if let tab = record.anchor.tabId, let window = windows[tab] {
            window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        removeNotifications(lineage: operation.lineage) { $0.id == record.id }
        return operationResult(.object(["opened": .bool(true), "notificationId": .string(record.id)]), transition: transition,
                               operation: operation, workspacePersistence: persistence)
    }
}
