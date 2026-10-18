import Foundation
import Testing
import SlateTermTestSupport
@testable import SlateTermCore

@Test func eventSchemasMatchTopicsRecipientsAndJournalEncoding() throws {
    let definitions = AutomationContracts.eventDefinitions
    let emit = AutomationContracts.events[.eventsEmit]!.input
    for topic in ["custom.ready", "custom.ready\n", "custom", "a-b.c_d", "host.ready", "*", "custom.*", "Bad", "a..b", String(repeating: "a", count: 129)] {
        var journal = try EventJournal()
        let accepted = (try? journal.append(topic: topic, source: .client)) != nil
        #expect(schemaAccepts(emit, .object(["topic": .string(topic)]), definitions: definitions) == accepted)
    }
    let poll = AutomationContracts.events[.eventsPoll]!.input
    for topic in ["host.*", "host.*\n", "a.b", "*", "a.*.b", "a..b"] {
        #expect(schemaAccepts(poll, .object(["topics": .array([.string(topic)])]), definitions: definitions)
            == ((try? EventFilter(topics: [topic])) != nil))
    }
    #expect(!schemaAccepts(poll, .object(["scope": .string("tab"), "pane": .string("p1")]), definitions: definitions))
    #expect(schemaAccepts(poll, .object(["scope": .string("tab"), "pane": .string("p1"), "tab": .string("t1")]), definitions: definitions))
    #expect(!schemaAccepts(poll, .object(["pane": .string("p1\n")]), definitions: definitions))
    let selectors: [JSONValue] = [.string("all"), .object(["instanceId": .string("live")]),
        .object(["instanceId": .string("bad id")]), .object(["serviceId": .string("service"), "generation": .string("gen")]),
        .object(["serviceId": .string("service\n"), "generation": .string("gen")]),
        .object(["serviceId": .string("service")]), .object(["serviceId": .string("service"), "generation": .string("gen"), "extra": .bool(true)])]
    for selector in selectors {
        #expect(schemaAccepts(poll, .object(["recipient": selector]), definitions: definitions)
            == ((try? EventObserver.selecting(selector, default: .administrator)) != nil))
    }
    #expect(!schemaAccepts(emit, .object(["topic": .string("custom.ready"), "targetInstanceId": .string("instance"),
        "targetService": .object(["serviceId": .string("service"), "generation": .string("gen")])]), definitions: definitions))
    var journal = try EventJournal()
    let cursor = journal.cursor
    let recipient = try ServiceEventRecipient(serviceID: "service", generation: "generation")
    let sources: [EventSource] = [.host, .client, .plugin(type: "notes", instanceId: "instance"), .service(pluginID: "notes", recipient: recipient)]
    for source in sources {
        let event = try journal.append(topic: "custom.ready", payload: .object(["arbitrary": .array([.null, .integer(5)])]), source: source)
        #expect(schemaAccepts(definitions["WorkspaceEvent"]!, try .encoding(event), definitions: definitions))
    }
    #expect(schemaAccepts(AutomationContracts.events[.eventsPoll]!.result, try .encoding(journal.batch(after: cursor)), definitions: definitions))
}

@Test func notificationSchemasPreserveSanitizationExclusiveTargetsAndNullableWelcomeState() throws {
    let definitions = AutomationContracts.notificationDefinitions
    let post = AutomationContracts.notifications[.notificationsPost]!.input
    for title in ["hello", " \n ", "\u{202e}", "日本語", String(repeating: "é", count: 129)] {
        #expect(schemaAccepts(post, .object(["title": .string(title)]))
            == ((try? NotificationStore.validate(title: title, body: "", key: nil)) != nil))
    }
    #expect(!schemaAccepts(post, .object(["title": .string("hello"), "active": .bool(false)])))
    #expect(!schemaAccepts(post, .object(["title": .string("hello"), "active": .bool(true), "pane": .string("p1")])))
    let dismiss = AutomationContracts.notifications[.notificationsDismiss]!.input
    #expect(schemaAccepts(dismiss, .object(["all": .bool(true)])))
    #expect(schemaAccepts(dismiss, .object(["id": .string("gone") ])))
    #expect(!schemaAccepts(dismiss, .object(["id": .string("gone"), "all": .bool(true)])))
    #expect(!schemaAccepts(dismiss, .object([:])))
    var store = NotificationStore()
    store.insert(title: "hello", body: "body", key: nil, source: .object(["kind": .string("administrative")]),
        anchor: .init(pane: PaneID(1), tab: TabID(1), lifetime: "session"), automatic: false,
        now: 10, disposition: "submitted", reason: nil)
    #expect(schemaAccepts(AutomationContracts.notifications[.notificationsList]!.result, try .encoding(store.records), definitions: definitions))
    #expect(schemaAccepts(definitions["NotificationPolicy"]!, try .encoding(NotificationPolicy()), definitions: definitions))
    for snapshot in [WelcomeSnapshot(acknowledged: false, revision: "r", error: nil), WelcomeSnapshot(acknowledged: nil, revision: "r", error: "unreadable")] {
        #expect(schemaAccepts(AutomationContracts.notifications[.welcomeGet]!.result, try .encoding(snapshot), definitions: definitions))
    }
}

@Test func serviceContractsRequirePairedSelectorsWithoutInventingCallerPrivileges() {
    let ready = AutomationContracts.services[.serviceReady]!
    #expect(schemaAccepts(ready.input, .object(["version": .integer(1)]))) // Bound-owner default is a runtime condition.
    #expect(schemaAccepts(ready.input, .object(["version": .integer(1), "serviceId": .string("s"), "generation": .string("g")])))
    #expect(!schemaAccepts(ready.input, .object(["version": .integer(1), "serviceId": .string("s")])))
    #expect(!schemaAccepts(ready.input, .object(["version": .integer(2), "serviceId": .string("s"), "generation": .string("g")])))
    for method in [AutomationMethod.serviceStart, .serviceStop, .serviceStatus, .serviceLogs] {
        let contract = AutomationContracts.services[method]!
        #expect(schemaAccepts(contract.input, .object(["id": .string("notes"), "expectedInstanceId": .string("epoch")])))
        #expect(!schemaAccepts(contract.input, .object(["id": .string("notes"), "expectedWorkspaceRevision": .string("revision")])))
    }
    #expect(!schemaAccepts(AutomationContracts.services[.serviceList]!.input, .object(["id": .string("notes")])))
    let methods = Set(AutomationContracts.events.keys).union(AutomationContracts.notifications.keys).union(AutomationContracts.services.keys)
    let expected = Set(AutomationMethod.publicMethods.filter { [.events, .notifications, .services].contains($0.family) || $0 == .welcomeGet })
    #expect(methods == expected)
}
