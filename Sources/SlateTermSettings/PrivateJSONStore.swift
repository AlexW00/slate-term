import Darwin
import Foundation

/// Small private JSON documents. Callers own serialization across writers (the
/// app's workspace lease does this); replacement is atomic, not fsync durability.
public struct PrivateJSONStore: Sendable {
    public let url: URL
    private let maximumBytes: Int
    private let prettyPrinted: Bool
    public init(url: URL, maximumBytes: Int = 2_097_152, prettyPrinted: Bool = false) throws {
        guard url.isFileURL, maximumBytes > 0 else { throw ConfigurationError.invalid("Invalid private store location or size limit") }
        self.url = url
        self.maximumBytes = maximumBytes
        self.prettyPrinted = prettyPrinted
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw ConfigurationError.invalid("Private store directory must be owned by this user with mode 0700") }
    }

    public func load<Value: Decodable>(_ type: Value.Type) throws -> Value? {
        guard try checkExisting() else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ConfigurationError.invalid("Private JSON document exceeds its size limit") }
        return try JSONDecoder().decode(type, from: data)
    }

    public func save<Value: Encodable>(_ value: Value) throws {
        _ = try checkExisting()
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys]
        var data = try encoder.encode(value)
        if prettyPrinted { data.append(10) }
        guard data.count <= maximumBytes else { throw ConfigurationError.invalid("Private JSON document exceeds its size limit") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        guard chmod(temporary.path, 0o600) == 0, rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func checkExisting() throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600 else {
            throw ConfigurationError.invalid("Private JSON document must be a regular file owned by this user with mode 0600")
        }
        guard info.st_size <= maximumBytes else { throw ConfigurationError.invalid("Private JSON document exceeds its size limit") }
        return true
    }
}
