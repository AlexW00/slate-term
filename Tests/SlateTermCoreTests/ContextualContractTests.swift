import Foundation
import Testing
@testable import SlateTermCore
import SlateTermTestSupport

@Test func contextualContractsKeepExplicitRecipesAndSettingsDefaultsDistinct() {
    let defaults = AutomationDefaults(pane: PaneID(1), tab: TabID(1), pluginID: "notes", instanceID: "instance")
    let recipe = AutomationContracts.contextual[.layoutConfiguration]!
    #expect(!schemaAccepts(recipe.input, .object([:])))
    #expect(!schemaAccepts(recipe.input, .object(["tab": .string("t1")])))
    #expect(!schemaAccepts(recipe.input, .object(["contextPane": .string("p1")])))
    #expect(schemaAccepts(recipe.input, .object(AutomationMethod.layoutConfiguration.resolving([:], defaults: defaults))))
    let settings = AutomationContracts.contextual[.settingsGet]!
    #expect(schemaAccepts(settings.input, .object(AutomationMethod.settingsGet.resolving([:], defaults: defaults))))
    #expect(!schemaAccepts(settings.input, .object(["id": .string("notes"), "pane": .string("p1")])))
    let expected = Set(AutomationMethod.publicMethods.filter { $0.family == .contextual && $0 != .contextInspect })
    #expect(Set(AutomationContracts.contextual.keys) == expected)
}

@Test func automaticTitleContractsPreservePairedAutomationIdentityAndByteBounds() {
    let title = AutomationContracts.contextual[.paneTitle]!
    let samples: [[String: JSONValue]] = [[:], ["expectedViewId": .string("view")],
        ["expectedViewId": .string("view"), "expectedDocumentId": .string("document")],
        ["expectedViewId": .string("view\n"), "expectedDocumentId": .string("document")],
        ["expectedViewId": .string(String(repeating: "a", count: 129)), "expectedDocumentId": .string("document")]]
    for sample in samples {
        let accepted: Bool
        do { _ = try WebIdentity.expected(in: sample); accepted = true } catch { accepted = false }
        let params = sample.merging(["title": .null]) { _, value in value }
        #expect(schemaAccepts(title.input, .object(params)) == accepted)
    }
    #expect(schemaAccepts(title.input, .object(["title": .string(String(repeating: "é", count: 256))])))
    #expect(!schemaAccepts(title.input, .object(["title": .string(String(repeating: "é", count: 257))])))
    #expect(!schemaAccepts(title.input, .object([:])))
    #expect(schemaAccepts(title.result, .null))
}
