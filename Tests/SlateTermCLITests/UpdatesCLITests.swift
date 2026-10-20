import Foundation
import JavaScriptCore
import Testing
import SlateTermCore
@testable import SlateTermCLI

@Suite struct UpdatesCLITests {
    @Test func routesEveryActionThroughTheSharedUpdateContract() throws {
        for action in UpdateAction.allCases {
            var arguments = [action.rawValue, "--json"]
            var expected: [String: JSONValue] = [:]
            if [.download, .cancel, .install].contains(action) {
                arguments += ["--update-id", "check-3:release-5"]
                expected["updateId"] = .string("check-3:release-5")
            }
            if action == .install {
                arguments += ["--confirm"]
                expected["confirm"] = .bool(true)
            }
            let command = try UpdatesCLI.parse(arguments)
            let request = try command.request
            #expect(command.connection.json)
            #expect(request.method == action.method)
            #expect(request.params == expected)
            #expect(try UpdateRequest(action: action, params: request.params).action == action)
            #expect(try SlateTermCLI.parseAsRoot(["updates"] + arguments) is UpdatesCLI)
        }
    }

    @Test func rejectsMissingConsentMissingIdentityAndExtraneousParameters() {
        for arguments in [
            [], ["install"], ["install", "--confirm"], ["install", "--update-id", "check-1"],
            ["download"], ["cancel"], ["download", "--update-id", ""],
            ["get", "--confirm"], ["show", "--update-id", "check-1"],
            ["check", "--confirm"], ["cancel", "--update-id", "check-1", "--confirm"],
            ["install", "--update-id", "check-1", "--confirm", "false"],
            ["get", "--pane", "p1"], ["get", "--tab", "t1"], ["get", "--force"],
            ["get", "--expected-workspace-revision", "old"], ["install", "--update-id", "check-1", "--yes"],
            ["get", "--expected-instance-id", ""]
        ] {
            #expect(throws: (any Error).self) { try UpdatesCLI.parse(arguments) }
        }
    }

    @Test func preservesExplicitInstanceGuardWithoutAddingWorkspaceTargets() throws {
        let command = try UpdatesCLI.parse(["install", "--update-id", "check-1", "--confirm", "--expected-instance-id", "app-1"])
        #expect(try command.request.params == ["updateId": .string("check-1"), "confirm": .bool(true), "expectedInstanceId": .string("app-1")])
        let defaults = AutomationDefaults(pane: PaneID(2), tab: TabID(3), pluginID: "fixture", instanceID: "fixture", scope: "tab")
        for action in UpdateAction.allCases {
            let method = try #require(AutomationMethod(rawValue: action.method))
            #expect(method.family == .synchronous)
            #expect(method.admission == (action == .get ? .read : .mutation))
            #expect(method.isPublic)
            #expect(method.resolving([:], defaults: defaults).isEmpty)
        }
    }

    @Test func updateCommandsOnlyExposeExplicitNonInstallingActions() throws {
        let commands = CommandRegistry.commands.filter { $0.id.hasPrefix("updates.") }
        #expect(Set(commands.map(\.id)) == ["updates.check", "updates.show", "updates.openParent"])
        let defaults = AutomationDefaults(pane: PaneID(2), tab: TabID(3), scope: "pane")
        for command in commands {
            #expect(command.contract.workspaceIndependent)
            #expect(!command.contract.requiresArguments)
            #expect(AutomationMethod.commandRun.resolving(["id": .string(command.id)], defaults: defaults) == ["id": .string(command.id)])
        }
    }

    @Test func pageHelpersKeepInstallConfirmationExplicit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Native/PluginPane.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "updates:Object.freeze({"))
        let end = try #require(source.range(of: "}),", range: start.upperBound..<source.endIndex))
        let helper = String(source[start.upperBound..<end.lowerBound])
        let context = try #require(JSContext())
        context.evaluateScript("const call=(method,params,options)=>({method,params,options}); const updates={\(helper)};")
        #expect(context.exception == nil)
        for action in UpdateAction.allCases {
            let args: String
            if action == .install { args = "'check-1',true,{cause:'cause-1'}" }
            else if [.download, .cancel].contains(action) { args = "'check-1',{cause:'cause-1'}" }
            else { args = "{cause:'cause-1'}" }
            let result = try #require(context.evaluateScript("JSON.stringify(updates.\(action.rawValue)(\(args)))")?.toString())
            let object = try #require(JSONDecoder().decode(JSONValue.self, from: Data(result.utf8)).object)
            #expect(object["method"] == .string(action.method))
            #expect(object["options"]?.object?["cause"] == .string("cause-1"))
            let request = try UpdateRequest(action: action, params: try #require(object["params"]?.object))
            #expect(request.confirmed == (action == .install))
        }
        for confirmation in ["undefined", "false", "'true'", "1", "null"] {
            let result = try #require(context.evaluateScript("JSON.stringify(updates.install('check-1',\(confirmation)))")?.toString())
            let object = try #require(JSONDecoder().decode(JSONValue.self, from: Data(result.utf8)).object)
            let params = try #require(object["params"]?.object)
            #expect(throws: RPCFailure.self) { try UpdateRequest(action: .install, params: params) }
        }
    }
}
