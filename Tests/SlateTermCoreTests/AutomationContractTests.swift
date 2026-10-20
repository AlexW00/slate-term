import Foundation
import Testing
import SlateTermTestSupport
@testable import SlateTermCore

@Test func terminalCatalogCoversCanonicalHandleAndLegacyMethodsWithoutPublishingInternals() {
    let expected = Set(AutomationMethod.allCases.filter {
        $0.family == .terminal || $0.family == .terminalOperations || $0 == .panesSend || $0 == .panesCapture
    })
    #expect(Set(AutomationContracts.terminal.keys) == expected)
    for (method, contract) in AutomationContracts.terminal {
        #expect(method.isPublic)
        #expect(Set(contract.guards).isSubset(of: APIGuards.names))
        #expect(contract.descriptor(for: method).object?["retry"] == .string("never-automatic"))
    }
    let legacy = AutomationContracts.terminal[.panesCapture]!.result
    let current = AutomationContracts.terminal[.terminalCapture]!.result
    let capture: JSONValue = .object(["text": .string("screen"), "truncated": .bool(false)])
    #expect(schemaAccepts(legacy, capture))
    #expect(!schemaAccepts(current, capture))
}

@Test func terminalSchemasMatchParserBranchesAndGuardIsolation() throws {
    let search = AutomationContracts.terminal[.terminalSearch]!.input
    let samples: [[String: JSONValue]] = [[:], ["action": .string("set"), "query": .string("")],
        ["action": .string("set")], ["query": .string("orphan")], ["action": .string("next"), "query": .string("extra")],
        ["action": .string("set"), "query": .string(String(repeating: "🦊", count: 1_025))]]
    for sample in samples {
        #expect(schemaAccepts(search, .object(sample)) == ((try? TerminalSearchRequest(sample)) != nil))
    }
    let run = AutomationContracts.terminal[.terminalRun]!.input
    for command in ["", " ", "printf '🦊'\nfalse", "bad\0command", String(repeating: "é", count: 8_193)] {
        var store = TerminalOperationStore()
        let accepted = (try? store.start(pane: PaneID(1), sessionId: "s", command: command, afterSequence: 0)) != nil
        #expect(schemaAccepts(run, .object(["command": .string(command)])) == accepted)
    }
    let wait = AutomationContracts.terminal[.terminalWait]!.input
    #expect(!schemaAccepts(wait, .object(["contains": .string("READY"), "afterSequence": .integer(0)])))
    #expect(!schemaAccepts(run, .object(["command": .string("true"), "pane": .string("p1"), "contextPane": .string("p2")])))
    let handle = AutomationContracts.terminal[.terminalOperationWait]!
    let id = UUID().uuidString
    #expect(schemaAccepts(handle.input, .object(["commandId": .string(id), "expectedInstanceId": .string("epoch")])))
    #expect(!schemaAccepts(handle.input, .object(["commandId": .string(id), "pane": .string("p1")])))
    #expect(!schemaAccepts(handle.input, .object(["commandId": .string(id), "expectedAnchorSessionId": .string("stale")])))
    let legacy = AutomationContracts.terminal[.panesSend]!.input
    #expect(schemaAccepts(legacy, .object(["text": .string("x"), "ignored": .bool(true)])))
    #expect(!schemaAccepts(legacy, .object(["text": .string("x"), "expectedFutureGuard": .string("unsafe")])))
}

@Test func operationResultSchemasAcceptActualEncodersAndRejectMissingIdentity() throws {
    var store = TerminalOperationStore()
    let start = try store.start(pane: PaneID(1), sessionId: "s", command: "false", afterSequence: 1)
    let statusSchema = AutomationContracts.terminal[.terminalOperationStatus]!.result
    #expect(schemaAccepts(statusSchema, try .encoding(start)))
    let line = try store.claimInput(pane: PaneID(1), sessionId: "s", emptyBuffer: true)
    _ = store.observe(pane: PaneID(1), sessionId: "s", report: .init(state: .running, pid: 7, sequence: 2, workingDirectory: "/tmp", command: line, exitCode: nil))
    let pendingCapture = store.observe(pane: PaneID(1), sessionId: "s", report: .init(state: .prompt, pid: 7, sequence: 3, workingDirectory: "/tmp", command: nil, exitCode: 1))
    let capture = try #require(pendingCapture)
    store.completeCapture(capture, text: "retained screen")
    #expect(schemaAccepts(statusSchema, try .encoding(store.status(start.commandId))))
    let result = try JSONValue.encoding(store.result(start.commandId))
    for method in [AutomationMethod.terminalRun, .terminalOperationResult, .terminalOperationWait] {
        #expect(schemaAccepts(AutomationContracts.terminal[method]!.result, result))
    }
    var missingIdentity = try #require(result.object)
    missingIdentity.removeValue(forKey: "sessionId")
    #expect(!schemaAccepts(AutomationContracts.terminal[.terminalOperationResult]!.result, .object(missingIdentity)))
}

@Test func historyContractsDescribeSourcesMetadataAndBoundedOutputs() throws {
    for method in [AutomationMethod.terminalHistory, .terminalHistoryExport] {
        let contract = AutomationContracts.terminal[method]!
        for source: JSONValue? in [nil, .string("current"), .string("previous"), .string("all"), .null, .integer(1)] {
            var params: [String: JSONValue] = method == .terminalHistoryExport ? ["path": .string("/tmp/output.txt")] : [:]
            if let source { params["source"] = source }
            #expect(schemaAccepts(contract.input, .object(params)) == ((try? TerminalHistoryRequest(params)) != nil))
        }
        for source in ["current", "previous"] {
            var fields: [String: JSONValue] = ["paneId": .string("p1"), "sessionId": .string("current-session"),
                "source": .string(source), "available": .bool(true), "capturedAt": source == "previous" ? .number(1_792_454_400) : .null,
                "ended": source == "previous" ? .bool(true) : .null,
                "lineCount": .integer(1), "byteCount": .integer(3), "truncated": .bool(false)]
            fields[method == .terminalHistory ? "text" : "path"] = .string(method == .terminalHistory ? "ok\n" : "/tmp/output.txt")
            #expect(schemaAccepts(contract.result, .object(fields)))
            fields["capturedAt"] = .string("not a timestamp")
            #expect(!schemaAccepts(contract.result, .object(fields)))
            fields["capturedAt"] = .null
            fields.removeValue(forKey: "available")
            #expect(!schemaAccepts(contract.result, .object(fields)))
        }
        #expect(contract.semantics["sessionId"] == .string("currentPaneSessionGuardNotHistoricalSession"))
    }
    let unavailable: JSONValue = .object(["paneId": .string("p1"), "sessionId": .string("current-session"),
        "source": .string("previous"), "available": .bool(false), "capturedAt": .null, "ended": .null,
        "lineCount": .integer(0), "byteCount": .integer(0), "truncated": .bool(false), "text": .string("")])
    #expect(schemaAccepts(AutomationContracts.terminal[.terminalHistory]!.result, unavailable))
}
