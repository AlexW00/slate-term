import Foundation
import Darwin

/// Download identities belong to a browser owner and survive document navigation.
public struct BrowserDownloadRequest: Sendable {
    public enum Kind: Sendable { case list, status, save, cancel, show }
    public let kind: Kind
    public let downloadID: String?
    public let path: String?

    public init(method: String, params: [String: JSONValue]) throws {
        switch method {
        case "browser.downloads": kind = .list
        case "browser.download": kind = .status
        case "browser.saveDownload": kind = .save
        case "browser.cancelDownload": kind = .cancel
        case "browser.showDownloads": kind = .show
        default: throw RPCFailure(code: -32601, message: "Unknown browser download method")
        }
        var allowed: Set<String> = ["pane", "tab", "popupId"]
        if kind != .list && kind != .show { allowed.insert("downloadId") }
        if kind == .save { allowed.insert("path") }
        guard Set(params.keys).isSubset(of: allowed) else { throw Self.invalid("Unknown browser download parameter") }
        for key in ["pane", "tab", "popupId"] where params[key] != nil {
            guard let value = params[key]?.string, !value.isEmpty, value.utf8.count <= 128 else {
                throw Self.invalid("\(key) must be a nonempty bounded string")
            }
        }
        if kind == .list || kind == .show { downloadID = nil }
        else {
            guard let id = params["downloadId"]?.string, id.utf8.count == 36, UUID(uuidString: id) != nil else {
                throw Self.invalid("A downloadId from browser.downloads is required")
            }
            downloadID = id
        }
        if kind == .save {
            guard let path = params["path"]?.string else { throw Self.invalid("An absolute destination path is required") }
            try Self.validatePath(path)
            self.path = path
        } else { path = nil }
    }

    /// Never accept an existing item, including a dangling symbolic link.
    public static func destinationURL(for path: String) throws -> URL {
        try validatePath(path)
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let files = FileManager.default
        if (try? files.attributesOfItem(atPath: url.path)) != nil {
            throw RPCFailure(code: APIError.conflict, message: "Download destination already exists; choose a new filename")
        }
        let parent = url.deletingLastPathComponent()
        var directory: ObjCBool = false
        guard files.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue,
              files.isWritableFile(atPath: parent.path) else {
            throw Self.invalid("Download destination needs an existing writable parent directory")
        }
        return url
    }

    /// The staging file shares the destination volume. Exclusive rename closes the overwrite race.
    public static func publish(stagedFile: URL, destination: URL) throws {
        guard stagedFile.isFileURL, destination.isFileURL,
              renamex_np(stagedFile.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw RPCFailure(code: APIError.conflict, message: "Could not save the completed download without replacing an existing item")
        }
    }

    /// Suggested names are untrusted page content, never paths.
    public static func safeSuggestedFilename(_ suggested: String) -> String {
        let scalars = suggested.unicodeScalars.prefix(1024).filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format
                && !"/\\:".unicodeScalars.contains($0)
        }
        var name = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        while name.utf8.count > 240 { name.removeLast() }
        return name.isEmpty ? "download" : name
    }

    private static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.hasSuffix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ![".", ".."].contains((path as NSString).lastPathComponent) else {
            throw invalid("Use an absolute file path without control characters, at most 4096 UTF-8 bytes")
        }
    }

    private static func invalid(_ message: String) -> RPCFailure { RPCFailure(code: -32602, message: message) }
}
