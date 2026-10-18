import Foundation
import Testing
import SlateTermTestSupport
@testable import SlateTermCore

@Test func updateContractsMatchStrictProductionRequests() throws {
    let identities: [JSONValue] = [.string("session-1"), .string("!~"), .string(""), .null, .integer(1),
        .string("has space"), .string("line\n"), .string("\u{7f}"), .string("日本語"),
        .string(String(repeating: "a", count: 256)), .string(String(repeating: "a", count: 257))]
    for action in UpdateAction.allCases {
        let contract = try #require(AutomationContracts.updates[AutomationMethod(rawValue: action.method)!])
        var valid: [String: JSONValue] = [:]
        if [.download, .cancel, .install].contains(action) { valid["updateId"] = .string("session-1") }
        if action == .install { valid["confirm"] = .bool(true) }
        var cases: [[String: JSONValue]] = [valid, [:]]
        for key in ["updateId", "expectedInstanceId"] {
            cases += identities.map { value in valid.merging([key: value]) { _, new in new } }
        }
        for key in ["pane", "tab", "scope", "force", "expectedWorkspaceRevision", "expectedAnchorSessionId", "unknown"] {
            cases.append(valid.merging([key: .string("unexpected")]) { _, new in new })
        }
        for confirmation in [JSONValue.bool(true), .bool(false), .string("true"), .integer(1), .null] {
            cases.append(valid.merging(["confirm": confirmation]) { _, new in new })
        }
        if action == .install { cases.append(valid.filter { $0.key != "confirm" }) }
        for params in cases {
            let accepted = (try? UpdateRequest(action: action, params: params)) != nil
            #expect(schemaAccepts(contract.input, .object(params)) == accepted,
                    "Update contract/parser mismatch for \(action.method): \(params)")
        }
        #expect(contract.guards == ["expectedInstanceId"])
        #expect(contract.errors.contains(APIError.conflict))
        #expect(contract.errors.contains(APIError.unavailable))
    }
}

@Test func updateResultContractsMatchEncodedSnapshotsAndRejectMalformedState() throws {
    let definitions = AutomationContracts.updateDefinitions
    let result = try #require(AutomationContracts.updates[.updatesGet]?.result)
    let release = UpdateRelease(id: "release", version: "0.2.0", build: "2", notes: "Signed notes",
        downloadURL: "https://example.invalid/Slate.zip", contentLength: 1024, signature: "signature")
    let phases: [UpdatePhase] = [.idle, .unavailable, .checking, .available, .downloading, .verifying,
        .ready, .installing, .downloadError, .verificationError, .checkError, .current]
    for phase in phases {
        for snapshot in [UpdateSnapshot(phase: phase, currentVersion: "0.1.0"),
                         UpdateSnapshot(revision: "revision", updateID: "session", phase: phase,
                            currentVersion: "0.1.0", release: release, receivedBytes: 512,
                            expectedBytes: 1024, detail: "Current detail", windowVisible: true)] {
            #expect(schemaAccepts(result, try .encoding(snapshot), definitions: definitions))
        }
    }
    let empty = try JSONValue.encoding(UpdateSnapshot(currentVersion: "0.1.0"))
    #expect(empty.object?["updateId"] == nil)
    #expect(empty.object?["release"] == nil)
    #expect(empty.object?["detail"] == nil)
    let invalid: [String: JSONValue] = ["phase": .string("unknown"), "receivedBytes": .integer(-1),
        "expectedBytes": .number(1.5), "windowVisible": .string("true"), "updateId": .null,
        "release": .object(["version": .string("0.2.0")]), "detail": .null, "unexpected": .bool(true)]
    for (key, value) in invalid {
        let fields = empty.object!.merging([key: value]) { _, new in new }
        #expect(!schemaAccepts(result, .object(fields), definitions: definitions))
    }
    for key in ["revision", "phase", "currentVersion", "receivedBytes", "expectedBytes", "windowVisible"] {
        #expect(!schemaAccepts(result, .object(empty.object!.filter { $0.key != key }), definitions: definitions))
    }
    for contract in AutomationContracts.updates.values { #expect(contract.result == result) }
}

@Test func updateCommandsAndDiscoveryUseSharedContracts() throws {
    let definitions = AutomationCatalog.definitions
    let description = try AutomationCatalog.describe(instanceID: UUID().uuidString, commands: CommandRegistry.commands)
    #expect(description.object?["apiVersion"] == .integer(1))
    #expect(description.object?["updates"] == AutomationCapabilities.updates)
    #expect(schemaAccepts(AutomationCatalog.methods[.describe]!.result, description, definitions: definitions))
    #expect(Set(AutomationContracts.updates.keys.map(\.rawValue)) == Set(UpdateAction.allCases.map(\.method)))
    for (id, method) in [("updates.show", AutomationMethod.updatesShow), ("updates.check", .updatesCheck)] {
        let contract = try #require(AutomationCatalog.commands[id])
        #expect(contract.result == AutomationCatalog.methods[method]?.result)
        #expect(contract.guards == ["expectedInstanceId"])
        #expect(contract.semantics["workspaceIndependentCallerDefaults"] == .bool(true))
        #expect(schemaAccepts(contract.input, .object(["id": .string(id), "expectedInstanceId": .string("epoch")]), definitions: definitions))
        for extra in [["pane": JSONValue.string("p1")], ["expectedInstanceId": .string("bad identity")], ["confirm": .bool(true)]] {
            #expect(!schemaAccepts(contract.input, .object(extra.merging(["id": .string(id)]) { _, new in new }), definitions: definitions))
        }
        let snapshot = try JSONValue.encoding(UpdateSnapshot(currentVersion: "0.1.0"))
        #expect(schemaAccepts(contract.result, snapshot, definitions: definitions))
    }
}
