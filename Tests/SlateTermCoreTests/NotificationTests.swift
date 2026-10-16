import Foundation
import Testing
@testable import SlateTermCore

@Test func notificationPolicyDefaultsAndFocus() {
    var policy = NotificationPolicy()
    #expect(policy.minimumSeconds == 30 && !policy.sound && policy.automatic && policy.tools)
    #expect(policy.suppression(automatic: true, durationNanoseconds: 29_999_999_999, appActive: false, sourceFocused: false) == "belowThreshold")
    #expect(policy.suppression(automatic: true, durationNanoseconds: 30_000_000_000, appActive: true, sourceFocused: false) == nil)
    #expect(policy.suppression(automatic: false, appActive: true, sourceFocused: true) == "sourceFocused")
    policy.banners = .otherApps
    #expect(policy.suppression(automatic: false, appActive: true, sourceFocused: false) == "appActive")
    policy.banners = .off
    #expect(policy.suppression(automatic: false, appActive: false, sourceFocused: false) == "bannersDisabled")
    policy.tools = false
    #expect(policy.suppression(automatic: false, appActive: false, sourceFocused: false) == "toolsDisabled")
}

@Test func notificationBoundsSanitizationAndScopedReplacement() throws {
    #expect(throws: RPCFailure.self) { try NotificationStore.validate(title: "\u{202e}\u{0}", body: "", key: nil) }
    #expect(throws: RPCFailure.self) { try NotificationStore.validate(title: String(repeating: "é", count: 129), body: "", key: nil) }
    #expect(throws: RPCFailure.self) { try NotificationStore.validate(title: "x", body: String(repeating: "x", count: 4097), key: nil) }
    #expect(NotificationStore.text("Hello\u{202e}\u{1b}\nthere", title: true) == "Hellothere")
    #expect(NotificationStore.text("Hello\nthere", title: false) == "Hello\nthere")
    var store = NotificationStore()
    let a = NotificationAnchor(pane: PaneID(1), tab: TabID(1), lifetime: "a")
    let b = NotificationAnchor(pane: PaneID(1), tab: TabID(1), lifetime: "b")
    let source: JSONValue = .object(["kind": .string("client")])
    let first = store.insert(title: "a", body: "", key: "job", source: source, anchor: a, automatic: false, now: 0, disposition: "suppressed", reason: "permissionDenied")
    let second = store.insert(title: "b", body: "", key: "job", source: source, anchor: b, automatic: false, now: 1, disposition: "suppressed", reason: nil)
    #expect(second.removed.isEmpty && store.records.count == 2)
    let third = store.insert(title: "c", body: "", key: "job", source: source, anchor: a, automatic: false, now: 2, disposition: "suppressed", reason: nil)
    #expect(third.removed == [first.record.id] && store.records.count == 2)
    let moved = NotificationAnchor(pane: PaneID(1), tab: TabID(2), lifetime: "a")
    #expect(a.hasSameDestination(as: moved))
    #expect(a.rateDestination == moved.rateDestination)
    #expect(NotificationAnchor(tab: TabID(1)).rateDestination != NotificationAnchor(tab: TabID(2)).rateDestination)
    #expect(NotificationAnchor().rateDestination != NotificationAnchor(tab: TabID(1)).rateDestination)
    #expect(a.rateDestination != b.rateDestination)
    let replaced = store.insert(title: "moved", body: "", key: "job", source: source, anchor: moved, automatic: false, now: 3, disposition: "suppressed", reason: nil)
    #expect(replaced.removed == [third.record.id])
    #expect(store.remove { $0.anchor.lifetime == "b" } == [second.record.id])
    for i in 0..<110 { store.insert(title: "\(i)", body: "", key: nil, source: source, anchor: a, automatic: false, now: Double(i), disposition: "suppressed", reason: nil) }
    #expect(store.records.count == 100 && store.records.first?.title == "10")
}

@Test func notificationRateLimitsAndRecovery() {
    var store = NotificationStore()
    for _ in 0..<5 { let admitted = store.admit(source: "a", now: 0); #expect(admitted) }
    let limited = store.admit(source: "a", now: 0); #expect(!limited)
    for _ in 0..<5 { let admitted = store.admit(source: "b", now: 0); #expect(admitted) }
    let globalLimited = store.admit(source: "c", now: 0); #expect(!globalLimited)
    let recovered = store.admit(source: "a", now: 1); #expect(recovered)
    let backwards = store.admit(source: "a", now: 0); #expect(!backwards)
}

@Test func notificationCatalogAndDefaults() {
    let defaults = AutomationDefaults(pane: PaneID(2), tab: TabID(1))
    #expect(AutomationMethod.notificationsPost.resolving([:], defaults: defaults)["pane"] == .string("p2"))
    #expect(AutomationMethod.notificationsPost.resolving(["tab": .string("t3")], defaults: defaults)["pane"] == nil)
    #expect(AutomationMethod.notificationsList.resolving([:], defaults: defaults).isEmpty)
    #expect(AutomationMethod.notificationsPost.resolving(["active": .bool(true)], defaults: defaults)["pane"] == nil)
    #expect(AutomationMethod.notificationsPost.admission == .mutation)
    #expect(AutomationMethod.notificationsList.admission == .read)
    #expect(CommandContract.forCommand("notifications.next").workspaceIndependent)
    #expect(CommandContract.forCommand("notifications.open").required == ["notificationId"])
}
