import Foundation

/// User-selected palettes live beside config.toml, independently of Apply/Revert.
public struct PaletteLibrary: Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let url: URL
        public var id: String { url.path }
        public var name: String { url.deletingPathExtension().lastPathComponent }
    }

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func entries() throws -> [Entry] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
        return try files.filter { file in
            let name = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "conf", (try? AppConfiguration.TerminalTheme(parsing: name)) != nil,
                  AppConfiguration.BundledTerminalTheme(rawValue: name) == nil else { return false }
            return try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }.map { Entry(url: $0) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Imports normalized colors, not arbitrary engine options. Never overwrites
    /// a different palette; importing the same named colors again reuses the copy.
    public func importPalette(from source: URL) throws -> Entry {
        let palette = try TerminalPalette.load(from: source)
        let name = source.deletingPathExtension().lastPathComponent
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for suffix in 1...1000 {
            let candidate = name + (suffix == 1 ? "" : "-\(suffix)")
            _ = try AppConfiguration.TerminalTheme(parsing: candidate)
            if AppConfiguration.BundledTerminalTheme(rawValue: candidate) != nil { continue }
            let file = directory.appendingPathComponent(candidate + ".conf")
            do {
                try Data(palette.source.utf8).write(to: file, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return Entry(url: file)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                if (try? TerminalPalette.load(from: file, followingSymbolicLinks: false)) == palette { return Entry(url: file) }
            }
        }
        throw ConfigurationError.invalid("Too many palettes named \(name). Rename the source file before importing it.")
    }
}
