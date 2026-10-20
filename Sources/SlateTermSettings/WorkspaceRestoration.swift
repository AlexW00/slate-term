import Foundation
import SlateTermCore

/// Starting locations, window geometry, and saved text, never executable recipes or live sessions.
/// Stored atomically beside topology in the same private workspace snapshot.
public struct WorkspaceRestoration: Codable, Equatable, Sendable {
    public var version = 1
    public var directories: [String: String] = [:]
    public var browserURLs: [String: String] = [:]
    public var windowFrames: [String: Frame] = [:]
    public var terminalOutput: [String: SavedTerminalOutput] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case version, directories, browserURLs, windowFrames, terminalOutput }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        directories = try container.decode([String: String].self, forKey: .directories)
        browserURLs = try container.decode([String: String].self, forKey: .browserURLs)
        windowFrames = try container.decode([String: Frame].self, forKey: .windowFrames)
        terminalOutput = try container.contains(.terminalOutput)
            ? container.decode([String: SavedTerminalOutput].self, forKey: .terminalOutput) : [:]
    }

    /// AppKit screen coordinates, in points. Group IDs identify windows across launches;
    /// native window numbers and app-epoch window selectors deliberately do not.
    public struct Frame: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var isValid: Bool {
            [x, y, width, height].allSatisfy(\.isFinite) && abs(x) <= 100_000 && abs(y) <= 100_000 &&
                (100...20_000).contains(width) && (100...20_000).contains(height)
        }
        /// Keep the complete title bar and frame on a currently connected screen.
        /// With no intersection (e.g. a removed monitor), use the preferred first screen.
        public func fitted(to screens: [Frame]) -> Frame {
            let screens = screens.filter(\.isValid)
            guard let first = screens.first else { return self }
            func overlap(_ screen: Frame) -> Double {
                max(0, min(x + width, screen.x + screen.width) - max(x, screen.x)) *
                max(0, min(y + height, screen.y + screen.height) - max(y, screen.y))
            }
            let screen = screens.reduce(first) { overlap($1) > overlap($0) ? $1 : $0 }
            let fittedWidth = min(width, screen.width), fittedHeight = min(height, screen.height)
            return Frame(x: min(max(x, screen.x), screen.x + screen.width - fittedWidth),
                         y: min(max(y, screen.y), screen.y + screen.height - fittedHeight), width: fittedWidth, height: fittedHeight)
        }
    }

    public static func allowsDirectory(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 && !value.utf8.contains(0)
    }

    public static func allowsBrowserURL(_ value: String) -> Bool {
        guard value.utf8.count <= 16_384, let url = try? BrowserURL.parse(value) else { return false }
        return url.absoluteString == value // Only canonical URLs, never implicit paths/searches.
    }

    /// Restoration only hints where things were. On load, an entry whose pane or window no
    /// longer fits (a pane changed type, or was removed by hand) is dropped instead of
    /// rejecting the workspace; a private pane's location is never applied either way.
    /// Malformed values still fail `validate`.
    public func retained(for workspace: Workspace) -> WorkspaceRestoration {
        let terminals = Set(workspace.panes.filter { $0.type == .terminal }.map { $0.id.description })
        let browsers = Set(workspace.panes.filter { $0.type == .browser }.map { $0.id.description })
        let groups = Set(workspace.groups.map { $0.id.description })
        var kept = self
        kept.directories = directories.filter { terminals.contains($0.key) }
        kept.terminalOutput = terminalOutput.filter { terminals.contains($0.key) }
        kept.browserURLs = browserURLs.filter { browsers.contains($0.key) }
        kept.windowFrames = windowFrames.filter { groups.contains($0.key) }
        return kept
    }

    public func validate(for workspace: Workspace) throws {
        let terminals = Set(workspace.panes.filter { $0.type == .terminal }.map { $0.id.description })
        // A private pane's location must not enter a workspace file, even on load.
        let browsers = Set(workspace.panes.filter { $0.type == .browser }.map { $0.id.description })
        let groups = Set(workspace.groups.map { $0.id.description })
        guard version == 1, Set(directories.keys).isSubset(of: terminals),
              Set(terminalOutput.keys).isSubset(of: terminals), terminalOutput.values.allSatisfy(\.isValid),
              terminalOutput.values.reduce(0, { $0 + $1.text.utf8.count }) <= SavedTerminalOutput.maximumWorkspaceBytes,
              Set(browserURLs.keys).isSubset(of: browsers), Set(windowFrames.keys).isSubset(of: groups),
              directories.values.allSatisfy(Self.allowsDirectory),
              browserURLs.values.allSatisfy(Self.allowsBrowserURL), windowFrames.values.allSatisfy(\.isValid) else {
            throw WorkspaceError.invalidSnapshot("Invalid restoration locations, saved output, window geometry, or identity references")
        }
    }
}
