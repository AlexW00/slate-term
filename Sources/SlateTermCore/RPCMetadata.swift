import Foundation

/// Versioned transport metadata, never mixed into contributed command arguments.
/// A cause is an opaque delivery reference, not caller-selected provenance.
public struct RPCMetadata: Codable, Equatable, Sendable {
    public let cause: String?
    /// Presentation-only agent identity. Hosts advertise support with `api.describe.presence`.
    public let actor: PresenceActor?

    public init(cause: String? = nil, actor: PresenceActor? = nil) throws {
        guard cause.map(isValidCausationToken) ?? true else { throw OperationAdmissionError.invalidContext }
        self.cause = cause
        self.actor = actor
    }

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let fields = value.object, fields["version"] == .integer(1),
              Set(fields.keys).isSubset(of: ["version", "cause", "actor"]),
              fields["cause"] == nil || fields["cause"]?.string != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid request metadata"))
        }
        let actor: PresenceActor?
        do { actor = try fields["actor"].map(PresenceActor.init(json:)) }
        catch { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid request metadata actor: \(error)")) }
        try self.init(cause: fields["cause"]?.string, actor: actor)
    }

    public func encode(to encoder: any Encoder) throws {
        var fields: [String: JSONValue] = ["version": .integer(1)]
        if let cause { fields["cause"] = .string(cause) }
        if let actor { fields["actor"] = actor.json }
        try JSONValue.object(fields).encode(to: encoder)
    }

    /// The same metadata without the actor, for hosts that do not show presence.
    public var withoutActor: RPCMetadata? {
        guard actor != nil else { return self }
        return cause == nil ? nil : try? RPCMetadata(cause: cause)
    }
}

func isValidCausationToken(_ value: String) -> Bool {
    (1...64).contains(value.utf8.count) && value.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
    }
}
