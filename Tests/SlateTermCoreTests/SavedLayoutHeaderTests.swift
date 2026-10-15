import Foundation
import Testing
import SlateTermCore

@Suite struct SavedLayoutHeaderTests {
    @Test func recipesRoundTripAndOpenWithFreshRuntimeState() throws {
        var definition = SavedLayoutDefinition.blank()
        definition.tabs[0].panes[0].headerVisible = false
        _ = try definition.splitPane(PaneID(1), axis: .horizontal)
        #expect(definition.tabs[0].panes[1].headerVisible)
        let parsed = try SavedLayoutDefinition.parse(JSONEncoder().encode(definition))
        #expect(parsed == definition)
        let opening = try parsed.opening(in: Workspace())
        for (runtime, recipe) in opening.panes {
            #expect(opening.workspace.panes.first { $0.id == runtime }?.headerVisible == recipe.headerVisible)
        }
        #expect(try Workspace.restore(opening.workspace.encoded()) == opening.workspace)
        // Replacing content configuration must not change slot chrome.
        definition.tabs[0].panes[0].type = "browser"
        definition.tabs[0].panes[0].configuration = ["url": .string("about:blank")]
        #expect(!(try definition.validated()).tabs[0].panes[0].headerVisible)
    }

    @Test func legacyRecipeDefaultsShownAndOnlyBooleanIsAccepted() throws {
        let original = SavedLayoutDefinition.blank()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        var tabs = object["tabs"] as! [[String: Any]]
        var panes = tabs[0]["panes"] as! [[String: Any]]
        panes[0].removeValue(forKey: "headerVisible")
        tabs[0]["panes"] = panes; object["tabs"] = tabs
        #expect(try SavedLayoutDefinition.parse(JSONSerialization.data(withJSONObject: object)) == original)
        for invalid: Any in [NSNull(), "false", 0, []] {
            panes[0]["headerVisible"] = invalid
            tabs[0]["panes"] = panes; object["tabs"] = tabs
            #expect(throws: RPCFailure.self) { try SavedLayoutDefinition.parse(JSONSerialization.data(withJSONObject: object)) }
        }
    }
}
