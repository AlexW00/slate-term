import CryptoKit
import Foundation
import Testing
@testable import SlateTermCore

@Suite struct UpdateTests {
    // Public Ed25519 test vectors 2 and 3 from RFC 8032, section 7.1.
    // https://www.rfc-editor.org/rfc/rfc8032#section-7.1
    private let vectors = [
        (key: "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", // gitleaks:allow -- RFC 8032 public verification key
         message: "72",
         signature: "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
        (key: "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", // gitleaks:allow -- RFC 8032 public verification key
         message: "af82",
         signature: "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a")
    ]

    @Test func installRequiresReleaseIdentityAndExplicitBooleanConsent() throws {
        let request = try UpdateRequest(action: .install, params: [
            "updateId": .string("check-7:release-42"), "confirm": .bool(true),
            "expectedInstanceId": .string("instance-3")
        ])
        #expect(request.updateID == "check-7:release-42")
        #expect(request.expectedInstanceID == "instance-3")
        #expect(request.confirmed)
        #expect(request.action.method == "updates.install")
        // Parsing preserves old identities; only the live host can decide whether they are stale.
        let old = try UpdateRequest(action: .install, params: ["updateId": .string("old-session"), "confirm": .bool(true)])
        #expect(old.updateID == "old-session")
        #expect(old.expectedInstanceID == nil)

        for consent in [nil, .null, .bool(false), .integer(1), .string("true")] as [JSONValue?] {
            var params: [String: JSONValue] = ["updateId": .string("check-7:release-42")]
            params["confirm"] = consent
            expectInvalid(.install, params)
        }
        expectInvalid(.install, ["confirm": .bool(true)])
    }

    @Test func mutationRequestsRequireAnIdentityWithoutBorrowingUnsupportedGuards() throws {
        for action in [UpdateAction.download, .cancel, .install] {
            let extra: [String: JSONValue] = action == .install ? ["confirm": .bool(true)] : [:]
            expectInvalid(action, extra)
            for invalid in [JSONValue.null, .bool(true), .integer(5), .string(""), .string("old\nnew"),
                            .string(String(repeating: "a", count: 257))] {
                expectInvalid(action, extra.merging(["updateId": invalid]) { _, new in new })
            }
            let valid = extra.merging(["updateId": .string("check-2:build-3")]) { _, new in new }
            #expect(try UpdateRequest(action: action, params: valid).updateID == "check-2:build-3")
            for unsupported in ["expectedWriteRevision", "expectedWorkspaceRevision", "expectedDocumentId", "typo"] {
                expectInvalid(action, valid.merging([unsupported: .string("old")]) { _, new in new })
            }
        }
    }

    @Test func noninstallRequestsRejectConsentAndOptionalGuardsRejectNull() throws {
        for action in UpdateAction.allCases {
            var params: [String: JSONValue] = [:]
            if [.download, .cancel, .install].contains(action) { params["updateId"] = .string("update-1") }
            if action == .install { params["confirm"] = .bool(true) }
            #expect(try UpdateRequest(action: action, params: params).expectedInstanceID == nil)
            for invalid in [JSONValue.null, .bool(false), .string(""), .string("instance one")] {
                expectInvalid(action, params.merging(["expectedInstanceId": invalid]) { _, new in new })
            }
            if action != .install {
                expectInvalid(action, params.merging(["confirm": .bool(true)]) { _, new in new })
            }
            if [.get, .show, .check].contains(action) { expectInvalid(action, ["updateId": .string("old")]) }
        }
    }

    @Test func snapshotEncodingRetainsReleaseAndWireIdentity() throws {
        var snapshot = UpdateSnapshot(revision: "instance:u:3", currentVersion: "0.1")
        snapshot.updateID = "check-2"
        snapshot.phase = .ready
        snapshot.release = UpdateRelease(id: "build-4", version: "0.2", build: "4", notes: "## Fixes\n日本語",
                                         downloadURL: "https://example.com/update.zip", contentLength: 52, signature: "signature")
        snapshot.receivedBytes = 52
        snapshot.expectedBytes = 52
        snapshot.windowVisible = true
        let encoded = try JSONValue.encoding(snapshot)
        #expect(encoded.object?["updateId"] == .string("check-2"))
        #expect(encoded.object?["updateID"] == nil)
        #expect(encoded.object?["phase"] == .string("ready"))
        #expect(try JSONDecoder().decode(UpdateSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }

    @Test func secureConfigurationAcceptsOnlyAuthenticatedHTTPS() throws {
        let key = hex(vectors[0].key).base64EncodedString()
        let config = try configuration(feed: "https://example.com/releases/appcast.xml", key: key)
        #expect(config.feedURL.absoluteString == "https://example.com/releases/appcast.xml")
        #expect(config.publicKey == hex(vectors[0].key))
        for feed in [nil, "", "http://example.com/appcast.xml", "file:///tmp/appcast.xml", "//example.com/appcast.xml",
                     "https:///appcast.xml", "https://user@example.com/feed", "https://:secret@example.com/feed",
                     "https://example.com/feed#fragment", "https://example.com/feed#", "https://example.com/bad path",
                     "https://example.com/%wrong", "https://example.com:70000/feed"] as [String?] {
            #expect(throws: RPCFailure.self) { try configuration(feed: feed, key: key) }
        }
    }

    @Test func configurationRejectsMissingOrMalformedKeysAndRelaxedSignaturePolicy() throws {
        for key in [nil, "", "not base64", Data(repeating: 0, count: 32).base64EncodedString(),
                    Data(repeating: 1, count: 31).base64EncodedString(), Data(repeating: 1, count: 33).base64EncodedString(),
                    hex(vectors[0].key).base64EncodedString() + "\n"] as [String?] {
            #expect(throws: RPCFailure.self) { try configuration(key: key) }
        }
        let key = hex(vectors[0].key).base64EncodedString()
        for flags in [(false, true, false), (true, false, false), (true, true, true)] {
            #expect(throws: RPCFailure.self) {
                try UpdateConfiguration(feedURL: "https://example.com/feed", publicKey: key,
                                        requiresSignedFeed: flags.0, verifiesBeforeExtraction: flags.1, signatureFailuresExpire: flags.2)
            }
        }
    }

    @Test func verifiesKnownEd25519SignaturesOverExactArchiveBytes() throws {
        for vector in vectors {
            let data = hex(vector.message)
            try UpdateArchiveVerifier.verify(data: data, expectedLength: UInt64(data.count),
                                             signature: hex(vector.signature).base64EncodedString(), publicKey: hex(vector.key))
            // A separately hashed message is not what Sparkle signs.
            let digest = Data(SHA256.hash(data: data))
            #expect(throws: RPCFailure.self) {
                try UpdateArchiveVerifier.verify(data: digest, expectedLength: UInt64(digest.count),
                                                 signature: hex(vector.signature).base64EncodedString(), publicKey: hex(vector.key))
            }
        }
    }

    @Test func rejectsCorruptUnsignedWrongKeyAndWrongLengthArchives() throws {
        let vector = vectors[0]
        let data = hex(vector.message)
        let signature = hex(vector.signature).base64EncodedString()
        let key = hex(vector.key)
        for corrupt in [Data([0x73]), Data(), Data([0x72, 0x00])] {
            #expect(throws: RPCFailure.self) {
                try UpdateArchiveVerifier.verify(data: corrupt, expectedLength: 1, signature: signature, publicKey: key)
            }
        }
        for invalidSignature in ["", "unsigned", Data(repeating: 0, count: 64).base64EncodedString(),
                                 Data(repeating: 1, count: 63).base64EncodedString(), signature + "\n"] {
            #expect(throws: RPCFailure.self) {
                try UpdateArchiveVerifier.verify(data: data, expectedLength: 1, signature: invalidSignature, publicKey: key)
            }
        }
        for invalidKey in [hex(vectors[1].key), Data(), Data(repeating: 0, count: 32)] {
            #expect(throws: RPCFailure.self) {
                try UpdateArchiveVerifier.verify(data: data, expectedLength: 1, signature: signature, publicKey: invalidKey)
            }
        }
        for length in [UInt64(0), 2, UpdateArchiveVerifier.maxArchiveBytes + 1, UInt64.max] {
            #expect(throws: RPCFailure.self) {
                try UpdateArchiveVerifier.verify(data: data, expectedLength: length, signature: signature, publicKey: key)
            }
        }
        #expect(UpdateArchiveVerifier.maxArchiveBytes == 536_870_912)
    }

    private func expectInvalid(_ action: UpdateAction, _ params: [String: JSONValue], sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try UpdateRequest(action: action, params: params)
            Issue.record("Invalid update request was accepted", sourceLocation: sourceLocation)
        } catch let error as RPCFailure {
            #expect(error.code == -32602, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    private func configuration(feed: String? = "https://example.com/feed", key: String?) throws -> UpdateConfiguration {
        try UpdateConfiguration(feedURL: feed, publicKey: key, requiresSignedFeed: true,
                                verifiesBeforeExtraction: true, signatureFailuresExpire: false)
    }

    private func hex(_ string: String) -> Data {
        let chars = Array(string)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
    }
}
