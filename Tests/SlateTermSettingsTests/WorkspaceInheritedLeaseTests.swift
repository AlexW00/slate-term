import Darwin
import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

@Suite struct WorkspaceInheritedLeaseTests {
    @Test func adoptsMatchingLeaseAndKeepsItsOwnDescriptor() throws {
        let bootstrap = try BootstrapWorkspaceLease()
        defer { withExtendedLifetime(bootstrap) {} }
        var store: WorkspaceStore? = try WorkspaceStore(directory: bootstrap.directory,
                                                        inheritedDescriptor: bootstrap.descriptor)
        bootstrap.close()
        try store?.save(Workspace())
        #expect(try store?.load() == Workspace())
        _ = withExtendedLifetime(store) {
            #expect(throws: ConfigurationError.self) {
                try WorkspaceStore(directory: bootstrap.directory)
            }
        }
        store = nil
        let reopened = try WorkspaceStore(directory: bootstrap.directory)
        #expect(try reopened.load() == Workspace())
    }

    @Test func rejectsAnotherInodeWithoutClosingEitherLease() throws {
        let bootstrap = try BootstrapWorkspaceLease()
        defer { withExtendedLifetime(bootstrap) {} }
        let other = open(bootstrap.directory.appendingPathComponent("other.lock").path,
                         O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard other >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(other) }
        #expect(throws: ConfigurationError.self) {
            try WorkspaceStore(directory: bootstrap.directory, inheritedDescriptor: other)
        }
        #expect(fcntl(other, F_GETFD) >= 0)
        #expect(fcntl(bootstrap.descriptor, F_GETFD) >= 0)
        #expect(throws: ConfigurationError.self) {
            try WorkspaceStore(directory: bootstrap.directory)
        }
        bootstrap.close()
        let reopened = try WorkspaceStore(directory: bootstrap.directory)
        try reopened.save(Workspace())
    }

    @Test func bootstrapStillExcludesWritersAfterAdoptedStoreIsReleased() throws {
        let bootstrap = try BootstrapWorkspaceLease()
        defer { withExtendedLifetime(bootstrap) {} }
        var store: WorkspaceStore? = try WorkspaceStore(directory: bootstrap.directory,
                                                        inheritedDescriptor: bootstrap.descriptor)
        try store?.save(Workspace())
        store = nil
        #expect(fcntl(bootstrap.descriptor, F_GETFD) >= 0)
        #expect(throws: ConfigurationError.self) {
            try WorkspaceStore(directory: bootstrap.directory)
        }
        bootstrap.close()
        let reopened = try WorkspaceStore(directory: bootstrap.directory)
        #expect(try reopened.load() == Workspace())
    }
}

/// Mirrors the lock acquired before the native runtime is loaded, without starting an app.
private final class BootstrapWorkspaceLease {
    let directory: URL
    private(set) var descriptor: Int32 = -1

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("slate-inherited-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent("workspace.lock").path,
                          O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close()
            try? FileManager.default.removeItem(at: directory)
            throw failure
        }
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }

    deinit {
        close()
        try? FileManager.default.removeItem(at: directory)
    }
}
