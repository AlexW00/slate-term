import Foundation
import Testing
@testable import SlateTermCore
import SlateTermTestSupport

@Test func persistencePatchContractsMatchBoundedLiteralKeyParser() throws {
    let definitions = AutomationCatalog.definitions
    let schema = definitions["PluginPersistencePatch"]!
    func set(_ key: String, _ value: JSONValue) -> JSONValue { .object(["op": .string("set"), "key": .string(key), "value": value]) }
    var deep: JSONValue = .null
    for _ in 0..<30 { deep = .array([deep]) }
    let samples: [JSONValue] = [
        .array([set("draft", .null)]), .array([set("literal.key", .bool(true))]), .array([set("\0", .integer(1))]),
        .array([set("", .null)]), .array([set(String(repeating: "é", count: 129), .null)]),
        .array([set("duplicate", .null), set("duplicate", .integer(1))]), .array([]),
        .array([.object(["op": .string("delete"), "key": .string("draft"), "value": .null])]),
        .array([.object(["op": .string("set"), "key": .string("draft")])]),
        .array([set("depth", deep)]), .array([set("depth", .array([deep]))]),
        .array([set("bytes", .string(String(repeating: "x", count: PluginPersistence.valueBytes)))]),
        .array((0..<33).map { set(String($0), .null) })
    ]
    for sample in samples {
        let accepted = (try? PluginPersistence.patch([:], operations: sample, panel: false)) != nil
        #expect(schemaAccepts(schema, sample, definitions: definitions) == accepted)
    }
    let document = PluginDataDocument()
    let changed = try document.changing(operations: .array([set("draft", .null)]), expectedRevision: document.revision)
    #expect(changed.values["draft"] == .null)
    let read: JSONValue = .object(["id": .string("notes"), "revision": .string(changed.revision), "values": .object(changed.values)])
    #expect(schemaAccepts(AutomationContracts.pluginPersistence[.pluginDataGet]!.result, read, definitions: definitions))
}

@Test func persistenceContractsKeepNamespacesPanelIdentityAndGuardsSeparate() {
    let definitions = AutomationCatalog.definitions
    func accepts(_ method: AutomationMethod, _ fields: [String: JSONValue]) -> Bool {
        schemaAccepts(AutomationContracts.pluginPersistence[method]!.input, .object(fields), definitions: definitions)
    }
    #expect(accepts(.pluginDataGet, ["id": .string("notes")]))
    #expect(!accepts(.pluginDataGet, ["id": .string("terminal")]))
    #expect(!accepts(.pluginDataGet, ["id": .string("notes"), "pane": .string("p1")]))
    #expect(!accepts(.pluginDataGet, ["id": .string("notes"), "expectedWorkspaceRevision": .string("revision")]))
    let reset: [String: JSONValue] = ["id": .string("notes"), "expectedDataRevision": .string("revision"), "force": .bool(true)]
    #expect(accepts(.pluginDataReset, reset))
    #expect(!accepts(.pluginDataReset, reset.filter { $0.key != "force" }))
    #expect(!accepts(.pluginDataReset, reset.merging(["force": .string("true")]) { _, v in v }))
    #expect(!accepts(.panelStateGet, [:]))
    #expect(accepts(.panelStateGet, ["pane": .string("p1"), "tab": .string("t1")]))
    let panel: [String: JSONValue] = ["pane": .string("p1"), "expectedPanelId": .string("panel"), "expectedStateRevision": .string("revision")]
    #expect(accepts(.panelStateReset, panel))
    #expect(!accepts(.panelStateReset, panel.filter { $0.key != "expectedPanelId" }))
    #expect(!accepts(.panelStateReset, panel.merging(["expectedDataRevision": .string("revision")]) { _, v in v }))
    #expect(!accepts(.panelStateReset, panel.merging(["contextPane": .string("p2")]) { _, v in v }))
    #expect(schemaAccepts(AutomationCatalog.commands["plugins.panelState.reset"]!.input,
        .object(panel.merging(["id": .string("plugins.panelState.reset")]) { _, v in v }), definitions: definitions))
    for old in ["storage.get", "storage.set", "storage.delete"] { #expect(AutomationMethod(rawValue: old) == nil) }
}

@Test func requestMetadataContractMatchesCurrentDecoderAndPresentationOnlyHome() throws {
    let definitions = AutomationCatalog.definitions
    let schema = definitions["RequestMetadata"]!
    let actors: [JSONValue] = [
        .object(["name": .string("codex"), "home": .string("legacy_home"), "note": .string("  checking tests  ")]),
        .object(["name": .string("codex"), "note": .string("bad\nline")]),
        .object(["name": .string("codex"), "note": .string(String(repeating: "a", count: 81))]),
        .object(["name": .string("codex"), "home": .null]), .object(["name": .string("bad name")]),
        .object(["name": .string("codex"), "authority": .bool(true)]), .null
    ]
    var samples = actors.map { JSONValue.object(["version": .integer(1), "actor": $0]) }
    samples += [.object(["version": .integer(1)]), .object(["version": .integer(2)]),
        .object(["version": .integer(1), "cause": .string("cause_1"), "actor": actors[0]]),
        .object(["version": .integer(1), "cause": .null]), .object(["version": .integer(1), "extra": .bool(true)])]
    for sample in samples {
        let bytes = try JSONEncoder().encode(sample)
        let accepted = (try? JSONDecoder().decode(RPCMetadata.self, from: bytes)) != nil
        #expect(schemaAccepts(schema, sample, definitions: definitions) == accepted)
    }
    #expect(AutomationCatalog.document.object?["requestMetadata"] == APISchema.reference("RequestMetadata"))
    // A named public call can fail metadata decoding before method dispatch.
    for contract in Array(AutomationCatalog.methods.values) + Array(AutomationCatalog.commands.values) {
        #expect(contract.errors.contains(-32600))
    }
}

@Test func presenceContractsPreserveExplicitTargetAndLeaseBounds() {
    let hold = AutomationContracts.presence[.presenceHold]!
    for ttl in [JSONValue.integer(1), .number(1.5), .integer(600), .integer(0), .integer(601), .string("60"), .null] {
        let accepted: Bool
        switch ttl {
        case .integer(let value): accepted = (1...600).contains(value)
        case .number(let value): accepted = (1...600).contains(value)
        default: accepted = false
        }
        #expect(schemaAccepts(hold.input, .object(["pane": .string("p2"), "ttlSeconds": ttl])) == accepted)
    }
    #expect(!schemaAccepts(hold.input, .object([:])))
    #expect(!schemaAccepts(hold.input, .object(["pane": .string("p2"), "tab": .string("t1")])))
    #expect(!schemaAccepts(AutomationContracts.presence[.presenceList]!.input, .object(["pane": .string("p2")])))
    #expect(schemaAccepts(AutomationContracts.presence[.presenceRelease]!.result,
        .object(["pane": .string("p2"), "released": .bool(false)])))
}
