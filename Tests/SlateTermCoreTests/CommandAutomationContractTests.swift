import Foundation
import Testing
@testable import SlateTermCore
import SlateTermTestSupport

private let builtinContracts = AutomationContracts.workspaceCommands.merging(AutomationContracts.applicationCommands) { _, _ in
    preconditionFailure("Command described twice")
}
private let commandSchemaDefinitions = [AutomationContracts.commandDefinitions, AutomationContracts.applicationCommandDefinitions,
    AutomationContracts.workspaceDefinitions, AutomationContracts.settingsDefinitions, AutomationContracts.notificationDefinitions, AutomationContracts.updateDefinitions,
    AutomationContracts.webDefinitions, AutomationContracts.pluginPersistenceDefinitions].reduce(into: [String: JSONValue]()) { all, definitions in
        all.merge(definitions) { _, _ in preconditionFailure("Duplicate definition") }
    }

@Test func commandSchemasCoverEveryBuiltinWithSelfIdentifyingInputsAndClosedReferences() {
    #expect(Set(builtinContracts.keys) == Set(CommandRegistry.commands.map(\.id)))
    func references(_ value: JSONValue) -> [String] {
        switch value {
        case .array(let values): values.flatMap(references)
        case .object(let fields): fields.values.flatMap(references) + (fields["$ref"]?.string.map { [$0] } ?? [])
        default: []
        }
    }
    for (id, contract) in builtinContracts {
        #expect(contract.input.object?["properties"]?.object?["id"] == APISchema.constant(.string(id)))
        #expect(contract.descriptor(for: .commandRun).object?["admission"] == .string("mutation"))
        #expect(contract.semantics["workspaceIndependentCallerDefaults"] == .bool(CommandContract.forCommand(id).workspaceIndependent))
        for reference in references(contract.descriptor(for: .commandRun)) {
            #expect(reference.hasPrefix("#/$defs/"))
            #expect(commandSchemaDefinitions[String(reference.dropFirst(8))] != nil)
        }
    }
    for definition in commandSchemaDefinitions.values {
        for reference in references(definition) { #expect(commandSchemaDefinitions[String(reference.dropFirst(8))] != nil) }
    }
}

@Test func workspaceCommandModelResultsFitTheirPublicResultFields() throws {
    let hostFields: Set<String> = ["operationId", "workspaceRevision", "outcome", "workspacePersistence", "layoutRevision", "sourceLayoutRevision", "contentRecreated", "path"]
    for (id, contract) in AutomationContracts.workspaceCommands where id != "window.focus" {
        var workspace = Workspace()
        _ = try workspace.split(PaneID(1), direction: .right)
        _ = try workspace.newTab(in: GroupID(1))
        _ = try workspace.newTab()
        try workspace.focus(PaneID(1))
        let revisions = WorkspaceRevisions(epoch: "contracts", workspace: workspace)
        var params: [String: JSONValue] = ["id": .string(id), "pane": .string("p1")]
        switch id {
        case "pane.split": params.merge(["direction": .string("left"), "target": .string("root"), "focus": .string("preserve")]) { _, value in value }
        case "pane.move": params.merge(["target": .string("p2"), "direction": .string("down")]) { _, value in value }
        case "layout.resize": params.merge(["path": .array([]), "firstChildFraction": .number(0.4)]) { _, value in value }
        case "pane.type": params["type"] = .string("browser")
        case "pane.title.set", "tab.title.set": params["title"] = .string(" Renamed ")
        case "tab.reorder": params["index"] = .integer(1)
        case "tab.move": params["group"] = .string("w2") // Omitted index appends.
        default: break
        }
        if WorkspaceMutationCommand.layoutGuarded.contains(id) { params["expectedLayoutRevision"] = .string(revisions.layoutRevision(TabID(1))!) }
        if WorkspaceMutationCommand.workspaceGuarded.contains(id) { params["expectedWorkspaceRevision"] = .string(revisions.revision) }
        #expect(schemaAccepts(contract.input, .object(params), definitions: commandSchemaDefinitions))
        let transition = try WorkspaceTransition.command(id, parameters: params, workspace: workspace, revisions: revisions)
        let reference = contract.result.object!["$ref"]!.string!
        let result = commandSchemaDefinitions[String(reference.dropFirst(8))]!.object!
        let properties = result["properties"]!.object!.filter { !hostFields.contains($0.key) }
        guard case .array(let required) = result["required"] else { preconditionFailure() }
        let modelSchema = APISchema.object(properties, required: required.compactMap(\.string).filter { !hostFields.contains($0) })
        // The value model is real; native enrichment/geometry/persistence are not
        // simulated here and still require VM response-to-schema verification.
        #expect(schemaAccepts(modelSchema, transition.result, definitions: commandSchemaDefinitions))
    }
}

@Test func commandSchemasPreserveLegacyPermissivenessAndStrictMutationAdmission() throws {
    for id in ["pane.focus", "tab.focus"] {
        let params: [String: JSONValue] = ["id": .string(id), "ignored": .bool(true)]
        #expect(schemaAccepts(builtinContracts[id]!.input, .object(params)))
        var workspace = Workspace()
        _ = try CommandRegistry.execute(id, params: params, workspace: &workspace)
    }
    #expect(!schemaAccepts(builtinContracts["pane.split"]!.input, .object(["id": .string("pane.split"), "direction": .string("right")])))
    #expect(!schemaAccepts(builtinContracts["tab.move"]!.input, .object(["id": .string("tab.move"), "group": .string("w2")])))
    let detach: [String: JSONValue] = ["id": .string("tab.detachCurrent"), "focus": .string("preserve")]
    #expect(!schemaAccepts(builtinContracts["tab.detachCurrent"]!.input, .object(detach)))
    var workspace = Workspace()
    #expect(throws: RPCFailure.self) { try CommandRegistry.execute("tab.detachCurrent", params: detach, workspace: &workspace) }
    for id in ["pane.close", "pane.header.hide"] {
        let input: JSONValue = .object(["id": .string(id), "force": .string("true")])
        #expect(schemaAccepts(builtinContracts[id]!.input, input) == (id == "pane.close"))
    }
    for id in ["settings.open", "pane.close", "terminal.find", "layouts.edit", "notifications.next", "welcome.read"] {
        #expect(schemaAccepts(builtinContracts[id]!.input, .object(["id": .string(id)]), definitions: commandSchemaDefinitions))
        #expect(!schemaAccepts(builtinContracts[id]!.input, .object(["id": .string(id), "expectedUnknownGuard": .string("must-not-ignore")]), definitions: commandSchemaDefinitions))
    }
    for id in ["window.focus", "welcome.read", "browser.clearData", "notifications.next"] {
        #expect(!schemaAccepts(builtinContracts[id]!.input, .object(["id": .string(id), "pane": .string("p1"), "windowId": .string("native")]), definitions: commandSchemaDefinitions))
    }
}

@Test func tabMoveWithoutIndexPreservesSameGroupOrderButAppendsAcrossGroups() throws {
    var initial = Workspace()
    _ = try initial.newTab(in: GroupID(1))
    _ = try initial.newTab()
    let contract = builtinContracts["tab.move"]!
    #expect(contract.semantics["omittedIndex"] == .object(["crossGroup": .string("append"), "sameGroup": .string("preserveOrder")]))
    for group in ["w1", "w2"] {
        var workspace = initial
        let params: [String: JSONValue] = ["id": .string("tab.move"), "tab": .string("t1"), "group": .string(group), "expectedWorkspaceRevision": .string("revision")]
        #expect(schemaAccepts(contract.input, .object(params)))
        _ = try CommandRegistry.execute("tab.move", params: params, workspace: &workspace)
        if group == "w1" { #expect(workspace == initial) }
        else { #expect(workspace.groups.first { $0.id == GroupID(2) }?.tabs == [TabID(3), TabID(1)]) }
    }
}

@Test func commandTitleSchemasApplyBoundsAfterTrimmingRatherThanBefore() throws {
    for text in ["", " \n ", "\tName\n", String(repeating: " ", count: 8192) + "Name ", "in\nside", String(repeating: "🦊", count: 101), String(repeating: "x", count: 4097)] {
        for id in ["pane.title.set", "tab.title.set"] {
            var workspace = Workspace()
            let params: [String: JSONValue] = ["id": .string(id), "title": .string(text)]
            let accepted = (try? CommandRegistry.execute(id, params: params, workspace: &workspace)) != nil
            #expect(schemaAccepts(builtinContracts[id]!.input, .object(params)) == accepted)
        }
    }
}

@Test func applicationCommandsRetainMethodContractsAndDistinctCompletionShapes() {
    for (id, method) in [("browser.clearData", AutomationMethod.browserClearData), ("browser.clearSiteData", .browserClearSiteData)] {
        #expect(builtinContracts[id]!.result == AutomationContracts.web[method]!.result)
        #expect(builtinContracts[id]!.guards == AutomationContracts.web[method]!.guards)
    }
    #expect(builtinContracts["config.reload"]!.result == AutomationContracts.settings[.configReload]!.result)
    #expect(schemaAccepts(builtinContracts["notifications.next"]!.result, .object(["opened": .bool(false)]), definitions: commandSchemaDefinitions))
    #expect(!schemaAccepts(builtinContracts["notifications.open"]!.result, .object(["opened": .bool(false)]), definitions: commandSchemaDefinitions))
    #expect(schemaAccepts(builtinContracts["layouts.openWindow"]!.result, .object([:]), definitions: commandSchemaDefinitions))
    #expect(!schemaAccepts(builtinContracts["pane.close"]!.result, .object([:]), definitions: commandSchemaDefinitions))
    #expect(schemaAccepts(builtinContracts["plugins.reload"]!.result, .object(["paneId": .string("p1"), "reloading": .bool(true)]), definitions: commandSchemaDefinitions))
    #expect(!schemaAccepts(builtinContracts["terminal.find"]!.input, .object(["id": .string("terminal.find"), "query": .string("not-a-command-argument")])))
}

@Test func showAllTabsHasOneGuardedParameterlessCommandContract() throws {
    let command = try #require(CommandRegistry.commands.first { $0.id == "tab.showAll" })
    #expect(command.title == "Show All Tabs")
    #expect(!command.contract.requiresArguments && !command.contract.workspaceIndependent)
    let contract = try #require(builtinContracts[command.id])
    #expect(schemaAccepts(contract.input, .object(["id": .string(command.id), "tab": .string("t2")])))
    #expect(!schemaAccepts(contract.input, .object(["id": .string(command.id), "toggle": .bool(true)])))
    #expect(schemaAccepts(contract.result, .object(["tabId": .string("t2"), "overviewVisible": .bool(true)]), definitions: commandSchemaDefinitions))
    #expect(!schemaAccepts(contract.result, .object(["tabId": .string("t2"), "overviewVisible": .bool(false)]), definitions: commandSchemaDefinitions))
}
