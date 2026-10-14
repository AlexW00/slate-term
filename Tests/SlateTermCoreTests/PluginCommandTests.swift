import Foundation
import Testing
@testable import SlateTermCore

private func commandPlugin(_ commands: String, extra: String = "") throws -> PluginRegistration {
    try PluginRegistration.parse(Data("{\"id\":\"tools\",\"title\":\"Tools\",\"commands\":\(commands)\(extra)}".utf8))
}

@Test func commandOnlyAndMixedPluginsRoundtripWithoutAnActivePanel() throws {
    let commands = #"[{"id":"toggle","title":"Toggle","executable":"/bin/sh","arguments":["/tmp/toggle.sh"]}]"#
    let plugin = try commandPlugin(commands)
    #expect(!plugin.hasPanel)
    #expect(plugin.entryURL == nil)
    #expect(plugin.origin == nil)
    #expect(plugin.commands[0].timeoutSeconds == 30)
    #expect(plugin.workspaceCommands[0].id == "plugin.tools.toggle")
    #expect(plugin.workspaceCommands[0].title == "Tools: Toggle")
    #expect(plugin.workspaceCommands[0].key.isEmpty)
    #expect(try PluginRegistration.parse(JSONEncoder().encode(plugin)) == plugin)
    let mixed = try commandPlugin(commands, extra: #", "source":{"kind":"directory","path":"/tmp/tools","entry":"index.html"}"#)
    #expect(mixed.hasPanel)
    #expect(mixed.workspaceCommands[0].id == "plugin.tools.toggle")
    #expect(try PluginRegistration.parse(JSONEncoder().encode(mixed)) == mixed)
}

@Test func pluginCommandsRejectInvalidAndAmbiguousManifests() {
    for commands in [
        "[]",
        #"[{"id":"toggle","title":"Toggle","executable":"sh"}]"#,
        #"[{"id":"toggle.x","title":"Toggle","executable":"/bin/sh"}]"#,
        #"[{"id":"toggle","title":" ","executable":"/bin/sh"}]"#,
        #"[{"id":"toggle","title":"Toggle","executable":"/bin/sh","timeoutSeconds":0}]"#,
        #"[{"id":"toggle","title":"Toggle","executable":"/bin/sh","timeoutSeconds":296}]"#,
        #"[{"id":"toggle","title":"Toggle","executable":"/bin/sh","directory":"relative"}]"#,
        #"[{"id":"toggle","title":"Toggle","executable":"/bin/sh","environment":{"BAD=KEY":"x"}}]"#,
        #"[{"id":"toggle","title":"Toggle","executable":"/bin/sh","arguments":["\u0000"]}]"#,
        #"[{"id":"toggle","title":"Toggle","executable":"/bin/sh","hotkey":"cmd+k"}]"#,
        #"[{"id":"toggle","title":"One","executable":"/bin/sh"},{"id":"toggle","title":"Two","executable":"/bin/sh"}]"#,
    ] { #expect(throws: (any Error).self) { try commandPlugin(commands) } }
    #expect(throws: (any Error).self) {
        try commandPlugin(#"[{"id":"toggle","title":"Toggle","executable":"/bin/sh"}]"#, extra: #", "process":{"executable":"/bin/sh"}"#)
    }
    let commands = (0..<33).map { #"{"id":"c"# + String($0) + #"","title":"Command","executable":"/bin/sh"}"# }.joined(separator: ",")
    #expect(throws: (any Error).self) { try commandPlugin("[\(commands)]") }
}

@Test func pluginCommandNamespaceIsDistinctFromBuiltins() {
    for id in ["plugin.tools.toggle", "plugin.acme.tools.do-stuff", "plugin.my-tools.go"] {
        #expect(PluginCommand.isNamespacedID(id))
    }
    for id in ["split.right", "plugin.tools", "plugin..run", "plugin.tools.Run", "plugin.tools.run\n", "plugin.tools._run"] {
        #expect(!PluginCommand.isNamespacedID(id))
    }
}
