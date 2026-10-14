import Darwin
import Foundation
import SlateTermCore

public struct WorkspaceStore: Sendable {
    public let url: URL
    private let directory: URL
    private let lease: WorkspaceLease

    public init(directory: URL) throws {
        self.directory = directory
        url = directory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var attributes = stat()
        guard lstat(directory.path, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o777 == 0o700 else {
            throw ConfigurationError.invalid("Workspace state directory must be owned by this user and have mode 0700")
        }
        let descriptor = open(directory.appendingPathComponent("workspace.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var owned = false
        defer { if !owned { Darwin.close(descriptor) } }
        var lock = stat()
        guard fstat(descriptor, &lock) == 0, lock.st_uid == getuid(), lock.st_mode & S_IFMT == S_IFREG,
              lock.st_mode & 0o777 == 0o600 else {
            throw ConfigurationError.invalid("Workspace lock must be a private regular file owned by this user")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK {
                throw ConfigurationError.invalid("Another Slate Terminal instance owns this state directory; use a different SLATE_TERM_STATE_DIR for an independent workspace")
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        lease = WorkspaceLease(descriptor: descriptor)
        owned = true
    }

    public func load() throws -> Workspace? {
        defer { withExtendedLifetime(lease) {} }
        do { return try Workspace.restore(Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    public func save(_ workspace: Workspace) throws {
        defer { withExtendedLifetime(lease) {} }
        let data = try workspace.encoded()
        let temporary = directory.appendingPathComponent("\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        guard chmod(temporary.path, 0o600) == 0, rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// Copies of the value store share ownership. Closing the descriptor releases the
/// flock, including on process death; never unlink a lock another process may hold.
private final class WorkspaceLease: Sendable {
    let descriptor: Int32
    init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }
}
