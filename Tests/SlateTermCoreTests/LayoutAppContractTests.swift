import Foundation
import Testing
@testable import SlateTermCore
import SlateTermTestSupport

@Test func layoutAppManagementContractsRequireExplicitRevisionAndRuntimeAvailability() throws {
    let definitions = AutomationCatalog.definitions
    let list = try #require(AutomationCatalog.methods[.layoutAppsList])
    let refresh = try #require(AutomationCatalog.methods[.layoutAppsRefresh])
    let id = UUID().uuidString
    #expect(schemaAccepts(list.input, .object([:])))
    #expect(!schemaAccepts(list.input, .object(["layoutAppID": .string(id)])))
    #expect(!schemaAccepts(refresh.input, .object(["layoutAppID": .string(id)])))
    let valid: [String: JSONValue] = ["layoutAppID": .string(id), "expectedBundleRevision": .string("bundle-revision")]
    #expect(schemaAccepts(refresh.input, .object(valid)))
    #expect(!schemaAccepts(refresh.input, .object(valid.merging(["pane": .string("p1")]) { _, value in value })))
    #expect(!schemaAccepts(refresh.input, .object(valid.merging(["expectedBundleRevision": .string("")]) { _, value in value })))
    let record: JSONValue = .object(["layoutAppID": .string(id), "layoutID": .string(UUID().uuidString),
        "name": .string("Project"), "path": .string("/tmp/Project.app"), "runtimeVersion": .string("1.0"),
        "runtimeBuild": .string("10"), "revision": .string("bundle-revision"), "running": .bool(false), "available": .bool(true),
        "shellCodeHash": .string("shell-hash"), "updateReady": .bool(false)])
    #expect(schemaAccepts(refresh.result, record, definitions: definitions))
    #expect(schemaAccepts(list.result, .array(Array(repeating: record, count: 256)), definitions: definitions))
    #expect(!schemaAccepts(list.result, .array(Array(repeating: record, count: 257)), definitions: definitions))
    #expect(AutomationMethod.layoutAppsList.admission == .read)
    #expect(AutomationMethod.layoutAppsRefresh.admission == .mutation)
    for method in [AutomationMethod.layoutAppsList, .layoutAppsRefresh, .layoutsLauncher] {
        let contract = try #require(AutomationCatalog.methods[method])
        #expect(contract.errors.contains(APIError.layoutAppManagementUnavailable))
        #expect(contract.availability.array!.contains(.object(["requires": .string("standardSlateRuntime")])))
        #expect(method.resolving([:], defaults: AutomationDefaults(pane: PaneID(1), tab: TabID(1))) == [:])
    }
    #expect(APIError.layoutAppManagementUnavailable == -32060)
    #expect(APIError.layoutAppManagementMessage == "Manage layout apps from Slate Terminal")
}

@Test func layoutAppCreationContractChangesShortcutResultAndAllowsOptionalPrivateDataCopy() throws {
    let launcher = try #require(AutomationCatalog.methods[.layoutsLauncher])
    let id = UUID().uuidString
    let input: [String: JSONValue] = ["id": .string(id), "path": .string("/tmp/Project.app")]
    #expect(schemaAccepts(launcher.input, .object(input)))
    #expect(schemaAccepts(launcher.input, .object(input.merging(["copyPluginData": .bool(false)]) { _, value in value })))
    #expect(!schemaAccepts(launcher.input, .object(input.merging(["copyPluginData": .null]) { _, value in value })))
    #expect(launcher.input.object?["properties"]?.object?["copyPluginData"]?.object?["default"] == .bool(true))
    #expect(!schemaAccepts(launcher.result, .object(input)))
    #expect(schemaAccepts(launcher.result, .object(input.merging([
        "layoutAppID": .string(UUID().uuidString), "runtimeVersion": .string("1.0"), "runtimeBuild": .string("10"), "syncedPluginIDs": .array([]), "copiedPluginDataIDs": .array([]),
        "unavailablePlugins": .array([]), "launchServicesRegistered": .bool(true), "launchServicesStatus": .integer(0)
    ]) { _, value in value })))
    #expect(APIGuards.names.contains("expectedBundleRevision"))
    #expect(!schemaAccepts(AutomationCatalog.methods[.layoutsGet]!.input,
        .object(["id": .string(id), "expectedBundleRevision": .string("revision")])))
}

@Test func configOverrideResetRequiresKnownKeysAndLocalSourceGuard() throws {
    let contract = try #require(AutomationCatalog.methods[.configResetOverrides])
    func accepts(_ keys: [JSONValue], revision: JSONValue? = .string("source")) -> Bool {
        var fields: [String: JSONValue] = ["keys": .array(keys)]
        fields["expectedSourceRevision"] = revision
        return schemaAccepts(contract.input, .object(fields), definitions: AutomationCatalog.definitions)
    }
    #expect(accepts([.string("appearance.theme"), .string("terminal.font_size")]))
    #expect(!accepts([]))
    #expect(!accepts([.string("terminal.unknown")]))
    #expect(!accepts([.string("plugins.notes.color")]))
    #expect(!accepts([.string("appearance.theme"), .string("appearance.theme")]))
    #expect(!accepts([.string("appearance.theme")], revision: nil))
    #expect(AutomationMethod.configResetOverrides.resolving([:], defaults: .init(pane: PaneID(1))) == [:])
    #expect(contract.result == APISchema.reference("ConfigurationWrite"))
}

@Test func layoutAppDiscoveryDistinguishesPrivateLibrariesFromTheSourceRecipe() throws {
    let description = try AutomationCatalog.describe(instanceID: UUID().uuidString, commands: CommandRegistry.commands)
    let layouts = try #require(description.object?["savedLayouts"]?.object)
    #expect(layouts["libraryScope"] == .string("currentApplication"))
    #expect(layouts["layoutAppLibrary"] == .string("private"))
    #expect(layouts["layoutAppFreshOpeningSource"] == .string("parentSourceRecipe"))
}

@Test func parentManagedResourcesAdvertiseTheSameRestrictionForAllTrustedClients() throws {
    for method in [AutomationMethod.pluginsRegister, .pluginsUnregister,
                   .skillsInstall, .skillsUninstall, .paletteImport, .layoutsLauncher, .layoutAppsList, .layoutAppsRefresh] {
        let contract = try #require(AutomationCatalog.methods[method])
        #expect(contract.errors.contains(APIError.layoutAppManagementUnavailable))
        #expect(contract.availability.array!.contains(.object(["requires": .string("standardSlateRuntime")])))
    }
    #expect(!AutomationCatalog.methods[.pluginsValidate]!.errors.contains(APIError.layoutAppManagementUnavailable))
    #expect(AutomationCatalog.commands["layouts.launcher"]!.errors.contains(APIError.layoutAppManagementUnavailable))
}

@Test func runtimeAvailabilitySharesStandardAndLayoutAppPolicies() throws {
    let standard = try #require(AutomationCatalog.runtimeAvailability(layoutApp: false).object)
    let layoutApp = try #require(AutomationCatalog.runtimeAvailability(layoutApp: true).object)
    let description = try AutomationCatalog.describe(instanceID: UUID().uuidString, commands: CommandRegistry.commands)
    #expect(description.object?["runtimeAvailability"] == .object(standard))
    #expect(Set(standard.keys) == Set(AutomationMethod.publicMethods.map(\.rawValue)))
    #expect(Set(layoutApp.keys) == Set(standard.keys))
    for method in [AutomationMethod.configResetOverrides, .updatesOpenParent] {
        #expect(standard[method.rawValue] == .bool(false))
        #expect(layoutApp[method.rawValue] == .bool(true))
    }
    let parentRequirement = JSONValue.object(["requires": .string("standardSlateRuntime")])
    for (method, contract) in AutomationCatalog.methods where contract.availability.array?.contains(parentRequirement) == true {
        #expect(standard[method.rawValue] == .bool(true))
        #expect(layoutApp[method.rawValue] == .bool(false))
    }
    for method in [AutomationMethod.updatesGet, .updatesCheck, .updatesInstall, .layoutsList, .layoutsCreate, .pluginsEnable, .pluginsDisable] {
        #expect(standard[method.rawValue] == .bool(true))
        #expect(layoutApp[method.rawValue] == .bool(true))
    }
}

@Test func restoreOriginalLayoutIsGuardedAndAvailableOnlyInLayoutApps() throws {
    let contract = try #require(AutomationCatalog.methods[.layoutsRestoreOriginal])
    #expect(schemaAccepts(contract.input, .object([:])))
    #expect(schemaAccepts(contract.input, .object(["force": .bool(true), "expectedWorkspaceRevision": .string("revision")])))
    for invalid: [String: JSONValue] in [["force": .string("true")], ["pane": .string("p1")], ["id": .string(UUID().uuidString)], ["expectedLayoutRevision": .string("revision")]] {
        #expect(!schemaAccepts(contract.input, .object(invalid)))
    }
    #expect(contract.errors.contains(-32010))
    #expect(contract.errors.contains(APIError.unavailable))
    #expect(contract.availability.array!.contains(.object(["requires": .string("layoutAppRuntime")])))
    #expect(AutomationMethod.layoutsRestoreOriginal.resolving([:], defaults: .init(pane: PaneID(1), tab: TabID(1))) == [:])
    #expect(AutomationCatalog.runtimeAvailability(layoutApp: false).object?["layouts.restoreOriginal"] == .bool(false))
    #expect(AutomationCatalog.runtimeAvailability(layoutApp: true).object?["layouts.restoreOriginal"] == .bool(true))
    let command = try #require(AutomationCatalog.commands["layouts.restoreOriginal"])
    #expect(command.result == contract.result)
    #expect(command.guards == contract.guards)
    #expect(schemaAccepts(command.input, .object(["id": .string("layouts.restoreOriginal"), "force": .bool(true)])))
}
