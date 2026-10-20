import Darwin
import Foundation
import SlateTermCore

public struct WorkspaceStore: Sendable {
    public let url: URL
    private let directory: URL
    private let lease: WorkspaceLease

    public init(directory: URL, inheritedDescriptor: Int32? = nil) throws {
        self.directory = directory
        url = directory.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var attributes = stat()
        guard lstat(directory.path, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o777 == 0o700 else {
            throw ConfigurationError.invalid("Workspace state directory must be owned by this user and have mode 0700")
        }
        let lockPath = directory.appendingPathComponent("workspace.lock").path
        let descriptor: Int32
        if let inheritedDescriptor {
            var inherited = stat(), expected = stat()
            guard fstat(inheritedDescriptor, &inherited) == 0, lstat(lockPath, &expected) == 0,
                  inherited.st_dev == expected.st_dev, inherited.st_ino == expected.st_ino else {
                throw ConfigurationError.invalid("The startup lease does not belong to this workspace")
            }
            descriptor = fcntl(inheritedDescriptor, F_DUPFD_CLOEXEC, 0)
        } else {
            descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
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

    public func load() throws -> Workspace? { try loadSnapshot()?.workspace }

    public func loadSnapshot() throws -> (workspace: Workspace, restoration: WorkspaceRestoration)? {
        defer { withExtendedLifetime(lease) {} }
        do {
            let data = try Data(contentsOf: url)
            let workspace = try Workspace.restore(data)
            let root = try JSONDecoder().decode(JSONValue.self, from: data).object!
            let restoration = try root["restoration"].map {
                try JSONDecoder().decode(WorkspaceRestoration.self, from: JSONEncoder().encode($0))
            }.map { $0.retained(for: workspace) } ?? WorkspaceRestoration()
            try restoration.validate(for: workspace)
            return (workspace, restoration)
        }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    public func save(_ workspace: Workspace, restoration: WorkspaceRestoration = .init()) throws {
        defer { withExtendedLifetime(lease) {} }
        try restoration.validate(for: workspace)
        var root = try JSONDecoder().decode(JSONValue.self, from: workspace.encoded()).object!
        root["restoration"] = try .encoding(restoration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(JSONValue.object(root))
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
