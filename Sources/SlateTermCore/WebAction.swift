import Foundation

/// Public automation identity, never a plugin bridge credential or bridge document ID.
public struct WebIdentity: Encodable, Equatable, Sendable {
    public let viewID: String
    public let documentID: String
    enum CodingKeys: String, CodingKey { case viewID = "viewId", documentID = "documentId" }

    public init(viewID: String, documentID: String) throws {
        guard Self.valid(viewID), Self.valid(documentID) else {
            throw RPCFailure(code: -32602, message: "Automation identities must be bounded opaque ASCII identifiers")
        }
        self.viewID = viewID
        self.documentID = documentID
    }

    public static func expected(in params: [String: JSONValue]) throws -> WebIdentity? {
        guard params["expectedViewId"] != nil || params["expectedDocumentId"] != nil else { return nil }
        guard let view = params["expectedViewId"]?.string, let document = params["expectedDocumentId"]?.string else {
            throw RPCFailure(code: -32602, message: "Supply both expectedViewId and expectedDocumentId from web inspection")
        }
        return try WebIdentity(viewID: view, documentID: document)
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// New web methods reuse the DOM validator; legacy browser methods keep their
/// optional-guard contract. An opaque ref carries both view and document guards.
public struct WebAction: Sendable {
    public let action: BrowserAction
    public let identity: WebIdentity?

    public init(kind: String, params: [String: JSONValue]) throws {
        let expected = try WebIdentity.expected(in: params)
        var input = params
        input.removeValue(forKey: "expectedViewId")
        input.removeValue(forKey: "expectedDocumentId")
        action = try BrowserAction(kind: kind, params: input)
        if let reference = action.parameters["ref"]?.string {
            let parts = reference.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, let number = UInt64(parts[2]), number > 0, String(number) == parts[2] else {
                throw RPCFailure(code: -32602, message: "Use an opaque element ref from a current web snapshot")
            }
            let bound = try WebIdentity(viewID: String(parts[0]), documentID: String(parts[1]))
            guard expected == nil || expected == bound else {
                throw RPCFailure(code: APIError.conflict, message: "Element ref and expected automation identity disagree")
            }
            identity = bound
        } else {
            if [.click, .fill, .select, .scroll, .focus, .key, .check, .setValue].contains(action.kind), expected == nil {
                throw RPCFailure(code: -32602, message: "Web mutations without a ref require expectedViewId and expectedDocumentId")
            }
            identity = expected
        }
    }
}
