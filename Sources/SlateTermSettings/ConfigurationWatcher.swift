import Darwin
import Foundation

/// Watches the parent as well as the file: editors commonly replace the inode.
@MainActor
public final class ConfigurationWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var identity: FileIdentity?
    private var observedContents: FileContents
    private var pending: DispatchWorkItem?
    private var closed = false

    public init(url: URL, onChange: @escaping @MainActor () -> Void) throws {
        self.url = url
        self.onChange = onChange
        observedContents = FileContents.read(url)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        directorySource = source(descriptor)
        refreshFileSource()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        pending?.cancel()
        pending = nil
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
    }

    isolated deinit { close() }

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
