import Foundation
import Testing
@testable import SlateTermCore

@Test func browserDownloadRequestsRejectAmbiguousAndUnknownParameters() throws {
    let id = UUID().uuidString
    #expect(try BrowserDownloadRequest(method: "browser.downloads", params: [:]).kind == .list)
    #expect(try BrowserDownloadRequest(method: "browser.showDownloads", params: ["popupId": .string(id)]).kind == .show)
    #expect(try BrowserDownloadRequest(method: "browser.download", params: ["downloadId": .string(id)]).downloadID == id)
    for method in ["browser.download", "browser.saveDownload", "browser.cancelDownload"] {
        for params: [String: JSONValue] in [[:], ["downloadId": .null], ["downloadId": .string("guessed")],
            ["downloadId": .string(id), "force": .bool(true)]] {
            #expect(throws: RPCFailure.self) { try BrowserDownloadRequest(method: method, params: params) }
        }
    }
    for path in ["relative.txt", "/", "/tmp/", "/tmp/.", "/tmp/..", "/tmp/line\nbreak", "/tmp/\0", "/" + String(repeating: "x", count: 4096)] {
        #expect(throws: RPCFailure.self) {
            try BrowserDownloadRequest(method: "browser.saveDownload", params: ["downloadId": .string(id), "path": .string(path)])
        }
    }
    for method in ["browser.downloads", "browser.download", "browser.cancelDownload"] {
        #expect(throws: RPCFailure.self) {
            try BrowserDownloadRequest(method: method, params: ["downloadId": .string(id), "path": .string("/tmp/a")])
        }
    }
}

@Test func browserDownloadDestinationsProtectFilesDirectoriesAndDanglingLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-download-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = root.appendingPathComponent("existing.txt")
    try Data("keep".utf8).write(to: existing)
    let dangling = root.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("missing"))
    for path in [existing.path, root.path, dangling.path, root.appendingPathComponent("missing/file").path] {
        #expect(throws: RPCFailure.self) { try BrowserDownloadRequest.destinationURL(for: path) }
    }
    let fresh = root.appendingPathComponent("new.txt")
    #expect(try BrowserDownloadRequest.destinationURL(for: fresh.path) == fresh)
    #expect(!FileManager.default.fileExists(atPath: fresh.path))
    #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
}

@Test func browserDownloadSuggestedNamesCannotBecomePathsOrHiddenFiles() {
    for name in ["../../secret", "C:\\path\\file", "\0\n", ".", "..", ".hidden", "a\u{202e}txt", String(repeating: "界", count: 200)] {
        let safe = BrowserDownloadRequest.safeSuggestedFilename(name)
        #expect(!safe.isEmpty && !safe.hasPrefix(".") && safe.utf8.count <= 240)
        #expect(!safe.contains("/") && !safe.contains("\\") && !safe.contains(":"))
        #expect(!safe.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format })
    }
    #expect(BrowserDownloadRequest.safeSuggestedFilename("report.pdf") == "report.pdf")
    #expect(BrowserDownloadRequest.safeSuggestedFilename("  ") == "download")
}

@Test func browserDownloadPublicationProtectsDestinationsCreatedDuringTransfer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-download-publish-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let staged = root.appendingPathComponent("staged")
    let destination = root.appendingPathComponent("destination")
    try Data("download".utf8).write(to: staged)
    _ = try BrowserDownloadRequest.destinationURL(for: destination.path)
    try Data("keep".utf8).write(to: destination)
    #expect(throws: RPCFailure.self) { try BrowserDownloadRequest.publish(stagedFile: staged, destination: destination) }
    #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
    #expect(try String(contentsOf: staged, encoding: .utf8) == "download")
    let fresh = root.appendingPathComponent("fresh")
    try BrowserDownloadRequest.publish(stagedFile: staged, destination: fresh)
    #expect(try String(contentsOf: fresh, encoding: .utf8) == "download")
    #expect(!FileManager.default.fileExists(atPath: staged.path))
}
