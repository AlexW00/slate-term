import CryptoKit
import Foundation

public enum UpdatePhase: String, Codable, Sendable {
    case idle, unavailable, checking, available, downloading, verifying, ready, installing
    case downloadError, verificationError, checkError, current
}

public struct UpdateRelease: Codable, Equatable, Sendable {
    public var id: String
    public var version: String
    public var build: String
    public var notes: String
    public var downloadURL: String
    public var contentLength: UInt64
    public var signature: String

    public init(id: String, version: String, build: String, notes: String = "", downloadURL: String,
                contentLength: UInt64, signature: String) {
        self.id = id
        self.version = version
        self.build = build
        self.notes = notes
        self.downloadURL = downloadURL
        self.contentLength = contentLength
        self.signature = signature
    }
}

public struct UpdateSnapshot: Codable, Equatable, Sendable {
    public var revision: String
    public var updateID: String?
    public var phase: UpdatePhase
    public var currentVersion: String
    public var release: UpdateRelease?
    public var receivedBytes: UInt64
    public var expectedBytes: UInt64
    public var detail: String?
    public var windowVisible: Bool

    public init(revision: String = "0", updateID: String? = nil, phase: UpdatePhase = .idle,
                currentVersion: String, release: UpdateRelease? = nil, receivedBytes: UInt64 = 0,
                expectedBytes: UInt64 = 0, detail: String? = nil, windowVisible: Bool = false) {
        self.revision = revision
        self.updateID = updateID
        self.phase = phase
        self.currentVersion = currentVersion
        self.release = release
        self.receivedBytes = receivedBytes
        self.expectedBytes = expectedBytes
        self.detail = detail
        self.windowVisible = windowVisible
    }

    private enum CodingKeys: String, CodingKey {
        case revision, updateID = "updateId", phase, currentVersion, release, receivedBytes, expectedBytes, detail, windowVisible
    }
}

public enum UpdateAction: String, Codable, CaseIterable, Sendable {
    case get, show, check, download, cancel, install
    public var method: String { "updates.\(rawValue)" }
}

/// Validates consent syntax. The host must compare identities again before acting.
public struct UpdateRequest: Equatable, Sendable {
    public let action: UpdateAction
    public let expectedInstanceID: String?
    public let updateID: String?
    public let confirmed: Bool

    public init(action: UpdateAction, params: [String: JSONValue]) throws {
        let requiresIdentity = [.download, .cancel, .install].contains(action)
        var allowed: Set<String> = ["expectedInstanceId"]
        if requiresIdentity { allowed.insert("updateId") }
        if action == .install { allowed.insert("confirm") }
        guard Set(params.keys).isSubset(of: allowed) else {
            throw RPCFailure(code: -32602, message: "Unknown or unsupported update parameter")
        }
        self.action = action
        expectedInstanceID = try Self.identity("expectedInstanceId", params: params, required: false)
        updateID = try Self.identity("updateId", params: params, required: requiresIdentity)
        if action == .install {
            guard params["confirm"] == .bool(true) else {
                throw RPCFailure(code: -32602, message: "Installing an update requires confirm: true")
            }
            confirmed = true
        } else {
            confirmed = false
        }
    }

    private static func identity(_ key: String, params: [String: JSONValue], required: Bool) throws -> String? {
        guard let value = params[key] else {
            if !required { return nil }
            throw RPCFailure(code: -32602, message: "\(key) is required")
        }
        guard case .string(let text) = value, !text.isEmpty, text.utf8.count <= 256,
              text.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0)
                  && !CharacterSet.controlCharacters.contains($0) }) else {
            throw RPCFailure(code: -32602, message: "\(key) must be a bounded, nonempty ASCII identity")
        }
        return text
    }
}

public struct UpdateConfiguration: Sendable {
    public let feedURL: URL
    public let publicKey: Data

    public init(feedURL: String?, publicKey: String?, requiresSignedFeed: Bool,
                verifiesBeforeExtraction: Bool, signatureFailuresExpire: Bool) throws {
        guard requiresSignedFeed, verifiesBeforeExtraction, !signatureFailuresExpire else {
            throw RPCFailure(code: APIError.unavailable, message: "Updates require permanent signature enforcement before extraction")
        }
        guard let text = feedURL, !text.isEmpty, text.utf8.count <= 16_384,
              !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) }),
              text.range(of: "%(?![0-9a-fA-F]{2})", options: .regularExpression) == nil,
              let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.port == nil || (1...65_535).contains(components.port!),
              let url = components.url else {
            throw RPCFailure(code: APIError.unavailable, message: "Updates require an absolute HTTPS feed URL without credentials or a fragment")
        }
        guard let publicKey, let key = Data(base64Encoded: publicKey), key.count == 32,
              key.contains(where: { $0 != 0 }) else {
            throw RPCFailure(code: APIError.unavailable, message: "Updates require a valid 32-byte Ed25519 public key")
        }
        self.feedURL = url
        self.publicKey = key
    }
}

public enum UpdateArchiveVerifier {
    public static let maxArchiveBytes: UInt64 = 512 * 1_024 * 1_024

    public static func verify(data: Data, expectedLength: UInt64, signature: String, publicKey: Data) throws {
        guard expectedLength > 0, expectedLength <= maxArchiveBytes,
              UInt64(data.count) == expectedLength else {
            throw RPCFailure(code: APIError.unavailable, message: "The update archive has an invalid or unexpected size")
        }
        guard publicKey.count == 32, publicKey.contains(where: { $0 != 0 }),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              let signatureData = Data(base64Encoded: signature), signatureData.count == 64 else {
            throw RPCFailure(code: APIError.unavailable, message: "The update archive requires a valid Ed25519 key and signature")
        }
        // Sparkle signs the archive bytes directly, without a separate digest step.
        guard key.isValidSignature(signatureData, for: data) else {
            throw RPCFailure(code: APIError.unavailable, message: "The update archive signature is invalid")
        }
    }
}
