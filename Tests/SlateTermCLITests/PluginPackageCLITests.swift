import Testing
import SlateTermCore
@testable import SlateTermCLI

@Test func pluginPackageCLIUsesZIPOnlyOptions() throws {
    let install = try Plugins.parse(["register", "--package", "tools.zip", "--replace"])
    #expect(install.package == "tools.zip" && install.replace)
    #expect(throws: (any Error).self) { try Plugins.parse(["register", "--manifest", "plugin.json"]) }
    for arguments in [
        ["register"], ["register", "tools", "--package", "tools.zip"],
        ["register", "--package", "tools.zip", "--force"],
        ["validate", "--package", "tools.zip", "--replace"],
        ["validate", "--package", "tools.zip", "--socket", "/tmp/not-a-socket"],
        ["list", "--package", "tools.zip"],
        ["service", "list", "--package", "tools.zip"],
        ["data", "get", "tools", "--package", "tools.zip"]
    ] {
        let command = try Plugins.parse(arguments)
        #expect(throws: (any Error).self) { try command.run() }
    }
}

@Test func packageValidationIsPublicReadAndDoesNotInheritPageTargets() {
    let method = AutomationMethod.pluginsValidate
    #expect(method.isPublic && method.admission == .read)
    #expect(method.resolving(["packagePath": .string("/tmp/tools.zip")], defaults: .init(pane: PaneID(1), tab: TabID(1), pluginID: "tools")) == ["packagePath": .string("/tmp/tools.zip")])
}
