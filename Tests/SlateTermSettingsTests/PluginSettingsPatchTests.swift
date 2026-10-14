import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

private func set(_ path: [String], _ value: JSONValue) -> JSONValue {
    .object(["op": .string("set"), "path": .array(path.map(JSONValue.string)), "value": value])
}
private func delete(_ path: [String]) -> JSONValue {
    .object(["op": .string("delete"), "path": .array(path.map(JSONValue.string))])
}

@Test func pluginPatchesPreserveUnrelatedTextAndUseLiteralPathComponents() throws {
    let source = """
    # application comment
    [appearance]
    theme = 'auto' # follow OS
    [plugins."acme.tools"]
    keep = 'untouched' # important
    [plugins."acme.tools".custom]
    count = 7 # count comment
    [plugins.other]
    secret = 'not ours'

    """
    let updated = try PluginSettingsPatch.updating(source: source, pluginID: "acme.tools", operations: [
        set(["custom", "count"], .integer(8)),
        set(["literal.dot", "quoted\"key"], .string("line\n# not syntax"))
    ])
    let parsed = try AppConfiguration.parse(updated)
    #expect(parsed.plugins["acme.tools"]?["custom"]?.object?["count"] == .integer(8))
    #expect(parsed.plugins["acme.tools"]?["literal.dot"]?.object?["quoted\"key"] == .string("line\n# not syntax"))
    #expect(parsed.plugins["other"]?["secret"] == .string("not ours"))
    #expect(updated.contains("keep = 'untouched' # important"))
    #expect(updated.contains("theme = 'auto' # follow OS"))
    #expect(updated.contains("# count comment"))
    #expect(updated.contains("[plugins.other]\nsecret = 'not ours'"))
    let appearance = try AppConfiguration.updating(source: updated, values: ["appearance.theme": "\"dark\""])
    #expect(try AppConfiguration.parse(appearance).plugins == parsed.plugins)
}

@Test func pluginPatchReplaceDeleteAndArraysRemainEditableByNativeSettings() throws {
    let source = """
    [appearance]
    theme = "auto"
    [plugins.demo.options]
    old = true
    [[plugins.demo.items]]
    name = 'first' # retained array
    [[plugins.demo.items]]
    name = 'second'

    """
    let operations = [
        set(["options"], .object(["new": .bool(true), "empty": .object([:])])),
        set(["nested"], .array([.object(["name": .string("new item"), "flags": .array([.bool(false), .integer(2)])])]))
    ]
    let updated = try PluginSettingsPatch.updating(source: source, pluginID: "demo", operations: operations)
    let parsed = try AppConfiguration.parse(updated)
    #expect(parsed.plugins["demo"]?["options"] == .object(["new": .bool(true), "empty": .object([:])]))
    #expect(parsed.plugins["demo"]?["items"] == .array([.object(["name": .string("first")]), .object(["name": .string("second")])]))
    #expect(updated.contains("name = 'first' # retained array"))
    let native = try AppConfiguration.updating(source: updated, values: ["appearance.theme": "\"light\"", "terminal.font_size": "15"])
    #expect(try AppConfiguration.parse(native).plugins == parsed.plugins)
    let deleted = try PluginSettingsPatch.updating(source: native, pluginID: "demo", operations: [delete(["items"]), delete(["options", "new"])])
    let final = try AppConfiguration.parse(deleted)
    #expect(final.plugins["demo"]?["items"] == nil)
    #expect(final.plugins["demo"]?["options"]?.object?["new"] == nil)
    #expect(final.plugins["demo"]?["options"]?.object?["empty"] == .object([:]))
    #expect(try PluginSettingsPatch.updating(source: deleted, pluginID: "demo", operations: [delete(["missing"])]) == deleted)
}

@Test func pluginPatchesRejectAmbiguityNullAndUnsupportedTraversalWithoutReplacingSource() throws {
    let source = "[plugins.demo]\nitems = [1,2]\nname = 'original'\n"
    let invalid: [[JSONValue]] = [
        [set([], .object([:]))], [set(["x"], .null)], [set(["x"], .array([.null]))],
        [set(["x"], .object(["bad": .null]))], [set(["x"], .number(.infinity))],
        [set(["items", "field"], .bool(true))], [delete(["name", "field"])],
        [set(["x"], .object([:])), set(["x", "child"], .bool(true))],
        [set(["x"], .integer(1)), delete(["x"])],
        [.object(["op": .string("merge"), "path": .array([.string("x")]), "value": .integer(1)])],
        [.object(["op": .string("delete"), "path": .array([.string("x")]), "value": .null])],
        [set(["tooBig"], .string(String(repeating: "x", count: 65537)))]
    ]
    for operations in invalid {
        #expect(throws: (any Error).self) { try PluginSettingsPatch.updating(source: source, pluginID: "demo", operations: operations) }
    }
    #expect(throws: (any Error).self) { try PluginSettingsPatch.updating(source: source, pluginID: "../other", operations: [set(["x"], .bool(true))]) }
    #expect(throws: (any Error).self) { try PluginSettingsPatch.updating(source: "invalid TOML", pluginID: "demo", operations: [set(["x"], .bool(true))]) }
    #expect(try AppConfiguration.parse(source).plugins["demo"]?["name"] == .string("original"))
}

@Test func widePluginSubtreesAreBatchedAndSerializedExpansionIsBounded() throws {
    let fields = Dictionary(uniqueKeysWithValues: (0..<512).map { ("key\($0)", JSONValue.object(["enabled": .bool(true), "empty": .object([:])])) })
    let source = try PluginSettingsPatch.updating(source: "", pluginID: "demo", operations: [set(["wide"], .object(fields))])
    #expect(try AppConfiguration.parse(source).plugins["demo"]?["wide"] == .object(fields))
    let native = try AppConfiguration.updating(source: source, values: ["appearance.theme": "\"dark\""])
    #expect(try AppConfiguration.parse(native).plugins["demo"]?["wide"] == .object(fields))
    var expanding = JSONValue.object(Dictionary(uniqueKeysWithValues: (0..<512).map { ("key\($0)", JSONValue.bool(true)) }))
    for _ in 0..<16 { expanding = .object([String(repeating: "x", count: 1024): expanding]) }
    #expect(throws: (any Error).self) { try PluginSettingsPatch.updating(source: "", pluginID: "demo", operations: [set(["wide"], expanding)]) }
}

@Test func nestedArrayTablesRemainOpaqueToApplicationEdits() throws {
    let source = """
    [[plugins.demo.groups]]
    [[plugins.demo.groups.members]]
    name = "one"
    [plugins.demo.groups.options]
    title = "first"
    [[plugins.demo.groups]]
    [[plugins.demo.groups.members]]
    name = "two"
    [plugins.demo.groups.options]
    title = "second"

    """
    let before = try AppConfiguration.parse(source)
    let native = try AppConfiguration.updating(source: source, values: ["appearance.theme": "\"dark\""])
    #expect(try AppConfiguration.parse(native).plugins == before.plugins)
    let patched = try PluginSettingsPatch.updating(source: source, pluginID: "demo", operations: [set(["new"], .bool(true))])
    #expect(try AppConfiguration.parse(patched).plugins["demo"]?["groups"] == before.plugins["demo"]?["groups"])
}

@Test func multilineCompoundValuesCannotMasqueradeAsApplicationSettings() throws {
    let source = """
    [[plugins.demo.items]]
    text = [''''
    [appearance]
    theme = 'auto'
    end = 1 '''']
    [appearance]
    theme = 'auto'

    """
    _ = try AppConfiguration.parse(source)
    #expect(throws: (any Error).self) { try AppConfiguration.updating(source: source, values: ["appearance.theme": "\"dark\""]) }
    #expect(throws: (any Error).self) { try PluginSettingsPatch.updating(source: source, pluginID: "demo", operations: [set(["new"], .bool(true))]) }
    let literal = try PluginSettingsPatch.updating(source: "", pluginID: "demo", operations: [set(["quotes"], .string("''' is literal text"))])
    #expect(try AppConfiguration.parse(literal).plugins["demo"]?["quotes"] == .string("''' is literal text"))
}

@Test func deletingLastDottedDescendantsRetainsEmptyAncestors() throws {
    for source in ["[plugins.demo]\nprefs.enabled = true\n", "plugins.demo.prefs.enabled = true\n"] {
        let updated = try PluginSettingsPatch.updating(source: source, pluginID: "demo", operations: [delete(["prefs", "enabled"])])
        #expect(try AppConfiguration.parse(updated).plugins["demo"]?["prefs"] == .object([:]))
        let again = try PluginSettingsPatch.updating(source: updated, pluginID: "demo", operations: [set(["prefs", "enabled"], .bool(false))])
        #expect(try AppConfiguration.parse(again).plugins["demo"]?["prefs"] == .object(["enabled": .bool(false)]))
    }
}

@Test func pluginPatchesHandleDottedRootAssignmentsWithoutRedeclaringTables() throws {
    let source = "plugins.demo.old = 1\nplugins.demo.keep = 2 # stay\n[appearance]\ntheme = 'auto'\n"
    let updated = try PluginSettingsPatch.updating(source: source, pluginID: "demo", operations: [
        set(["old"], .object(["deep": .object(["value": .integer(3)])])),
        set(["empty"], .object([:]))
    ])
    let parsed = try AppConfiguration.parse(updated)
    #expect(parsed.plugins["demo"]?["old"] == .object(["deep": .object(["value": .integer(3)])]))
    #expect(parsed.plugins["demo"]?["empty"] == .object([:]))
    #expect(updated.contains("plugins.demo.keep = 2 # stay"))
    let again = try PluginSettingsPatch.updating(source: updated, pluginID: "demo", operations: [set(["old"], .string("scalar now")), delete(["empty"])])
    #expect(try AppConfiguration.parse(again).plugins["demo"]?["old"] == .string("scalar now"))
}
