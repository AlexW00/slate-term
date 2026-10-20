import Darwin
import CoreServices
import Foundation

/// Walk absolute filesystem paths; Foundation URL parents can grow dot components at the root.
func observationAncestorPaths(for url: URL) -> [String] {
    var path = (url.standardizedFileURL.path as NSString).deletingLastPathComponent
    if path.isEmpty { path = "/" }
    var result: [String] = []
    while !path.isEmpty {
        result.append(path)
        if path == "/" { break }
        let parent = (path as NSString).deletingLastPathComponent
        // Require progress even if a future path implementation returns an unexpected parent.
        guard !parent.isEmpty, parent.count < path.count else { break }
        path = parent
    }
    return result
}

func canonicalObservationPath(for url: URL) -> String {
    let path = url.standardizedFileURL.path
    // FSEvents uses physical paths, including /private/var, even before the watched tree exists.
    for ancestor in [path] + observationAncestorPaths(for: url) {
        guard let resolved = realpath(ancestor, nil) else { continue }
        let canonical = String(cString: resolved)
        free(resolved)
        let suffix = String(path.dropFirst(ancestor.count))
        return canonical == "/" ? "/" + suffix.drop(while: { $0 == "/" }) : canonical + suffix
    }
    return path
}

/// Watches the parent as well as the file: editors commonly replace the inode.
@MainActor
public final class ConfigurationWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var directorySources: [String: DirectoryObservation] = [:]
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var identity: FileIdentity?
    private var observedContents: FileContents
    private var pending: DispatchWorkItem?
    private var closed = false

    public init(url: URL, createDirectory: Bool = true, onChange: @escaping @MainActor () -> Void) throws {
        self.url = url
        self.onChange = onChange
        observedContents = FileContents.read(url)
        let directory = url.deletingLastPathComponent()
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        refreshDirectorySources()
        guard !directorySources.isEmpty else { throw POSIXError(.ENOENT) }
        refreshFileSource()
    }

    /// Suppress observation of a source already applied by this writer, never a superseding edit.
    public func acknowledgeAppliedContents(_ contents: Data) {
        guard !closed, FileContents.read(url) == .data(contents) else { return }
        observedContents = .data(contents)
        pending?.cancel()
        pending = nil
        refreshFileSource()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        pending?.cancel()
        pending = nil
        fileSource?.cancel()
        fileSource = nil
        for observation in directorySources.values { observation.source.cancel() }
        directorySources.removeAll()
    }

    isolated deinit { close() }

    private func refreshDirectorySources() {
        // Ancestors retain observation when an editor replaces or removes the parent directory.
        var retained = Set<String>()
        for path in observationAncestorPaths(for: url) {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            if descriptor >= 0 {
                var attributes = stat()
                if fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR {
                    retained.insert(path)
                    let identity = FileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
                    if directorySources[path]?.identity == identity { Darwin.close(descriptor) }
                    else {
                        directorySources[path]?.source.cancel()
                        directorySources[path] = DirectoryObservation(identity: identity, source: source(descriptor))
                    }
                } else { Darwin.close(descriptor) }
            }
        }
        for path in Array(directorySources.keys) where !retained.contains(path) {
            directorySources.removeValue(forKey: path)?.source.cancel()
        }
    }

    private func refreshFileSource() {
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            fileSource?.cancel()
            fileSource = nil
            identity = nil
            return
        }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else { Darwin.close(descriptor); return }
        let next = FileIdentity(device: attributes.st_dev, inode: attributes.st_ino)
        guard identity != next else { Darwin.close(descriptor); return }
        fileSource?.cancel()
        identity = next
        fileSource = source(descriptor)
    }

    private func source(_ descriptor: Int32) -> any DispatchSourceFileSystemObject {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend, .revoke], queue: .main)
        source.setCancelHandler { Darwin.close(descriptor) }
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleReload() } }
        source.resume()
        return source
    }

    private func scheduleReload() {
        guard !closed else { return }
        refreshDirectorySources()
        refreshFileSource()
        // Directory notifications also describe sibling files (including our own
        // generated engine config). Only target-content changes start a reload.
        let contents = FileContents.read(url)
        guard contents != observedContents else { return }
        observedContents = contents
        pending?.cancel()
        // Coalesce editor writes; callers still validate the complete candidate
        // and retain the previous configuration if an edit is incomplete.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.pending = nil
                self.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private struct FileIdentity: Equatable { let device: dev_t; let inode: ino_t }
    private struct DirectoryObservation {
        let identity: FileIdentity
        let source: any DispatchSourceFileSystemObject
    }

    private enum FileContents: Equatable {
        case data(Data)
        case unavailable(domain: String, code: Int)

        static func read(_ url: URL) -> FileContents {
            do { return .data(try Data(contentsOf: url)) }
            catch {
                let error = error as NSError
                return .unavailable(domain: error.domain, code: error.code)
            }
        }
    }
}

/// Observes a parent's plugin tree without creating directories or opening every package file.
@MainActor
public final class DirectoryTreeWatcher {
    private let url: URL
    private let watchedPath: String
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var closed = false

    public init(url: URL, onChange: @escaping @MainActor () -> Void) throws {
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        watchedPath = canonicalObservationPath(for: url)
        self.onChange = onChange
        try startStream()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        pending?.cancel()
        pending = nil
        stopStream()
    }

    isolated deinit { close() }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func startStream() throws {
        // Observe an existing ancestor so missing and atomically replaced trees remain visible.
        guard let ancestor = observationAncestorPaths(for: url).first(where: { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }) else { throw POSIXError(.ENOENT) }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(nil, { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryTreeWatcher>.fromOpaque(info).takeUnretainedValue()
            let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            MainActor.assumeIsolated {
                for index in 0..<count {
                    let path = String(cString: names[index])
                    let rescan = eventFlags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
                    if rescan || path == watcher.watchedPath || path.hasPrefix(watcher.watchedPath + "/")
                        || watcher.watchedPath.hasPrefix(path + "/") {
                        watcher.scheduleChange()
                        break
                    }
                }
            }
        }, &context, [ancestor] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else {
            throw POSIXError(.EIO)
        }
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            throw POSIXError(.EIO)
        }
        stream = created
    }

    private func scheduleChange() {
        guard !closed else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.pending = nil
                // Reattach after ancestor replacement; reconciliation reads the complete current tree.
                let previous = self.stream
                do {
                    try self.startStream()
                    if let previous {
                        FSEventStreamStop(previous)
                        FSEventStreamInvalidate(previous)
                        FSEventStreamRelease(previous)
                    }
                }
                catch { NSLog("Parent plugin observation could not restart: %@", String(describing: error)) }
                self.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }
}
