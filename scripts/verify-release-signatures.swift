#!/usr/bin/env swift
import CryptoKit
import Foundation

struct Request: Decodable {
    struct File: Decodable { let path: String; let signature: String }
    let publicKey: String
    let files: [File]
}

do {
    let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
    guard let bytes = Data(base64Encoded: request.publicKey) else { throw CocoaError(.fileReadCorruptFile) }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
    for file in request.files {
        guard let signature = Data(base64Encoded: file.signature),
              key.isValidSignature(signature, for: try Data(contentsOf: URL(fileURLWithPath: file.path))) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    print("Verified feed, archive and notes signatures")
} catch {
    FileHandle.standardError.write(Data("Release signature verification failed\n".utf8))
    exit(1)
}
