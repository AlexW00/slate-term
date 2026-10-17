import Foundation
import Testing
@testable import SlateTermCore

@Test func portableManifestResolvesAllRuntimePathsWithoutShellExpansion() throws {
    let manifest = try PluginManifest(data: Data(#"{"id":"tools","title":"Tools","source":{"kind":"url","url":"http://127.0.0.1:0/"},"process":{"executable":"./bin/server","arguments":["{port}","{pluginRoot}/server.js"]},"service":{"executable":"/bin/sh"},"commands":[{"id":"run","title":"Run","executable":"./bin/tool","directory":"scripts","arguments":["{pluginRoot}","$HOME","*.txt"]}]}"#.utf8))
    let resolved = try manifest.registration(root: URL(fileURLWithPath: "/managed/plugin"), validateFiles: false)
    #expect(resolved.process?.executable == "/managed/plugin/bin/server")
    #expect(resolved.process?.arguments == ["{port}", "/managed/plugin/server.js"])
    #expect(resolved.service?.directory == "/managed/plugin")
    #expect(resolved.commands[0].directory == "/managed/plugin/scripts")
    #expect(resolved.commands[0].arguments == ["/managed/plugin", "$HOME", "*.txt"])
    #expect(resolved.packageRoot == "/managed/plugin")
    #expect(manifest.value.object?["process"]?.object?["executable"] == .string("./bin/server"))
}

@Test func portableManifestRejectsExternalResourceRootsAndAmbiguousPaths() throws {
    for path in ["/Downloads/plugin", "../plugin", "web/../plugin", "web//assets", "web\\assets", ""] {
        let data = try JSONEncoder().encode(JSONValue.object(["id": .string("notes"), "title": .string("Notes"), "source": .object(["kind": .string("directory"), "path": .string(path)])]))
        #expect(throws: (any Error).self) { try PluginManifest(data: data) }
    }
    for spec in [#"{"executable":"python3"}"#, #"{"executable":"/bin/sh","directory":"/tmp"}"#, #"{"executable":"/bin/sh","arguments":["{pluginRoot}/../outside"]}"#, #"{"executable":"/bin/sh","arguments":["prefix{pluginRoot}"]}"#] {
        #expect(throws: (any Error).self) { try PluginManifest(data: Data("{\"id\":\"tools\",\"title\":\"Tools\",\"service\":\(spec)}".utf8)) }
    }
}
