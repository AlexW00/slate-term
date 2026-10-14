import Foundation
import Testing
@testable import SlateTermCore

@Test func pluginManifestHasExplicitSourcesAndValidatedOrigins() throws {
    let manifest = try PluginRegistration.parse(Data(#"{"id":"notes","title":"Notes","scope":"tab","source":{"kind":"directory","path":"/tmp/notes","entry":"index.html"}}"#.utf8))
    #expect(manifest.id == "notes")
    #expect(manifest.scope == .tab)
    #expect(manifest.entryURL?.absoluteString == "plugin://notes/index.html")
    #expect(manifest.origin!.matches(URL(string: "plugin://notes/other.html")!))
    #expect(!manifest.origin!.matches(URL(string: "plugin://other/index.html")!))
    #expect(try PluginRegistration.parse(JSONEncoder().encode(manifest)) == manifest)
    let remote = try PluginRegistration.parse(Data(#"{"id":"docs","title":"Docs","source":{"kind":"url","url":"https://example.com/start"}}"#.utf8))
    #expect(remote.scope == .pane)
    #expect(remote.origin!.matches(URL(string: "https://example.com:443/path")!))
    #expect(!remote.origin!.matches(URL(string: "http://example.com/path")!))
    #expect(!remote.origin!.matches(URL(string: "https://example.com:444/path")!))
}

@Test func pluginRegistrationRejectsAmbiguousDangerousAndUnknownInputs() {
    for source in [
        #"{"id":"terminal","title":"Reserved","source":{"kind":"directory","path":"/tmp","entry":"index.html"}}"#,
        #"{"id":"../notes","title":"Invalid","source":{"kind":"directory","path":"/tmp","entry":"index.html"}}"#,
        #"{"id":"notes","title":"Notes","source":{"kind":"directory","path":"relative","entry":"index.html"}}"#,
        #"{"id":"notes","title":"Notes","source":{"kind":"directory","path":"/tmp","entry":"../secret"}}"#,
        #"{"id":"notes","title":"Notes","source":{"kind":"url","url":"file:///etc/passwd"}}"#,
        #"{"id":"notes","title":"Notes","source":{"kind":"url","url":"http://example.com"}}"#,
        #"{"id":"notes","title":"Notes","source":{"kind":"url","url":"https://user:secret@example.com"}}"#,
        #"{"id":"notes","title":"Notes","scope":"unknown","source":{"kind":"url","url":"https://example.com"}}"#,
        #"{"id":"notes","title":"Notes","permissions":"all","source":{"kind":"url","url":"https://example.com"}}"#,
    ] {
        #expect(throws: (any Error).self) { try PluginRegistration.parse(Data(source.utf8)) }
    }
}

@Test func managedPluginsHaveVerifiableLoopbackOriginsAndBoundedProcesses() throws {
    func manifest(_ url: String, process: String = #"{"executable":"/bin/sh"}"#) -> Data {
        Data("{\"id\":\"server\",\"title\":\"Server\",\"source\":{\"kind\":\"url\",\"url\":\"\(url)\"},\"process\":\(process)}".utf8)
    }
    let automatic = try PluginRegistration.parse(manifest("http://127.0.0.1:0/"))
    #expect(automatic.origin?.port == 0)
    #expect(automatic.process?.restartLimit == 3)
    #expect(try PluginRegistration.parse(JSONEncoder().encode(automatic)) == automatic)
    #expect(try PluginRegistration.parse(manifest("http://127.0.0.1:8080/")).origin?.port == 8080)
    for url in ["https://example.com", "http://localhost:8080", "http://[::1]:8080", "http://127.0.0.1:65536"] {
        #expect(throws: (any Error).self) { try PluginRegistration.parse(manifest(url)) }
    }
    for process in [#"{"executable":"relative"}"#, #"{"executable":"/bin/sh","restartLimit":11}"#, #"{"executable":"/bin/sh","readyTimeoutSeconds":0}"#, #"{"executable":"/bin/sh","environment":{"BAD=KEY":"x"}}"#] {
        #expect(throws: (any Error).self) { try PluginRegistration.parse(manifest("http://127.0.0.1:8080/", process: process)) }
    }
}

@Test func staticPluginPathsCannotEscapeTheRegisteredRoot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-assets-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("safe".utf8).write(to: directory.appendingPathComponent("index.html"))
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
    let assets = try PluginAssets(root: directory)
    #expect(try assets.file(forPercentEncodedPath: "/").lastPathComponent == "index.html")
    for path in ["/../passwd", "/%2e%2e/passwd", "/escape/passwd", "/a%00b", "/.git/config"] {
        #expect(throws: (any Error).self) { try assets.file(forPercentEncodedPath: path) }
    }
}
