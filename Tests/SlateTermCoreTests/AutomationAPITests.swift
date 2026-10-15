import Foundation
import Testing
@testable import SlateTermCore

@Test func automationCatalogHasOnePublicInventory() {
    let names = AutomationMethod.publicMethods.map(\.rawValue)
    #expect(Set(names).count == names.count)
    for name in ["config.patch", "appearance.get", "skills.list", "skills.install", "browser.eval", "web.screenshot", "plugins.service.start", "storage.get", "pane.title", "service.ready"] {
        #expect(names.contains(name))
    }
    #expect(!names.contains("shell.update"))
    // Shell telemetry is hidden from discovery but token-authenticated, not denied by client kind.
    for method in [AutomationMethod.shellUpdate, .shellRunInput] {
        #expect(method.family == .integration && method.admission == .authenticatedIntegration)
    }
    #expect(!names.contains("debug.inspect"))
    #expect(AutomationMethod(rawValue: "plugin.tools.build") == nil) // command.run payload, not a second RPC
    #expect(AutomationMethod.webScreenshot.family == .web)
    #expect(AutomationMethod.serviceReady.family == .services)
    for method in AutomationMethod.allCases {
        #expect(AdmissionAction.forMethod(method.rawValue) == method.admission)
    }
}

@Test func automationSDKLiteralAliasesBelongToTheSharedCatalog() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sdk = try String(contentsOf: root.appendingPathComponent("Native/PluginPane.swift"), encoding: .utf8)
    let expression = try NSRegularExpression(pattern: #"\bcall\('([^']+)'(?=[,)])"#)
    let names = Set(AutomationMethod.publicMethods.map(\.rawValue))
    let aliases = expression.matches(in: sdk, range: NSRange(sdk.startIndex..., in: sdk)).map {
        String(sdk[Range($0.range(at: 1), in: sdk)!])
    }
    #expect(aliases.count >= 20)
    for name in aliases { #expect(names.contains(name), "SDK alias is missing from the shared API: \(name)") }
    #expect(sdk.contains("AutomationMethod.publicMethods.map"))
    #expect(sdk.contains("rpc:Object.freeze(Object.fromEntries(methodNames.map"))
    let host = try String(contentsOf: root.appendingPathComponent("Native/WorkspaceHost.swift"), encoding: .utf8)
    #expect(!host.contains("apiMethods(plugin:"))
    #expect(!host.contains("pluginAccessible"))
    #expect(host.contains("return try await self.callAsync(method, params: params, metadata: metadata, caller: caller)"))
    #expect(host.contains("return try await callAsync(method, params: params, metadata: metadata, caller: caller)"))
}

@Test func automationEventRecipientsAreQueriesNotCallerPermissions() throws {
    let recipient = try ServiceEventRecipient(serviceID: "service", generation: "generation")
    let observers: [EventObserver] = [.administrator, .plugin(instanceID: "page"), .service(recipient)]
    for fallback in observers {
        #expect(try EventObserver.selecting(nil, default: fallback) == fallback)
        #expect(try EventObserver.selecting(.string("all"), default: fallback) == .administrator)
        #expect(try EventObserver.selecting(.object(["instanceId": .string("other")]), default: fallback) == .plugin(instanceID: "other"))
        #expect(try EventObserver.selecting(.object(["serviceId": .string("service"), "generation": .string("generation")]), default: fallback) == .service(recipient))
    }
    #expect(throws: EventJournalError.self) { try EventObserver.selecting(.object(["instanceId": .string("page"), "generation": .string("generation")]), default: .administrator) }
    let source = EventSource.service(pluginID: "worker", recipient: recipient)
    let encoded = try JSONEncoder().encode(source)
    #expect(try JSONDecoder().decode(EventSource.self, from: encoded) == source)
    #expect(try JSONValue.encoding(source).object?["instanceId"] == nil)
}

@Test func automationDefaultsRespectExplicitTargetsAndGlobalMethods() throws {
    let defaults = AutomationDefaults(pane: PaneID(2), tab: TabID(2), pluginID: "notes", instanceID: "notes-instance", scope: "tab")
    let revision: JSONValue = .string("inactive-tab-revision")
    let resolved = AutomationMethod.webSnapshot.resolving(["expectedLayoutRevision": revision], defaults: defaults)
    #expect(resolved["pane"] == .string("p2"))
    #expect(resolved["tab"] == .string("t2"))
    #expect(resolved["expectedLayoutRevision"] == revision)
    #expect(AutomationMethod.webSnapshot.resolving(["pane": .string("p9")], defaults: defaults)["tab"] == nil)
    #expect(AutomationMethod.webSnapshot.resolving(["tab": .string("t9")], defaults: defaults)["pane"] == nil)
    #expect(AutomationMethod.serviceStart.resolving(["id": .string("worker")], defaults: defaults) == ["id": .string("worker")])
    #expect(AutomationMethod.configGet.resolving([:], defaults: defaults).isEmpty)
    #expect(AutomationMethod.pluginSettingsGet.resolving([:], defaults: defaults)["id"] == .string("notes"))
    #expect(AutomationMethod.pluginSettingsGet.resolving(["id": .string("other")], defaults: defaults)["id"] == .string("other"))
    #expect(AutomationMethod.storageGet.resolving([:], defaults: defaults)["instanceId"] == .string("notes-instance"))
    #expect(AutomationMethod.storageGet.resolving(["pane": .string("p9")], defaults: defaults)["instanceId"] == nil)
}

@Test func automationCommandDefaultsDoNotAttachTargetsToGlobalActions() {
    let defaults = AutomationDefaults(pane: PaneID(2), tab: TabID(2), pluginID: "notes", instanceID: "instance", scope: "tab")
    #expect(AutomationMethod.commandRun.resolving(["id": .string("config.reload")], defaults: defaults)["pane"] == nil)
    #expect(AutomationMethod.commandRun.resolving(["id": .string("pane.zoom")], defaults: defaults)["pane"] == .string("p2"))
    #expect(AutomationMethod.commandRun.resolving(["id": .string("plugin.tools.build")], defaults: defaults)["scope"] == .string("tab"))
    #expect(AutomationMethod.workspaceSnapshot.resolving(["scope": .string("global")], defaults: defaults)["pane"] == nil)
    #expect(AutomationMethod.storageGet.resolving([:], defaults: .init()).isEmpty)
}
