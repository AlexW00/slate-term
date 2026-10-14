import Foundation

public protocol IdentityKind: Sendable {
    static var prefix: String { get }
}

public enum PaneIdentity: IdentityKind { public static let prefix = "p" }
public enum TabIdentity: IdentityKind { public static let prefix = "t" }
public enum GroupIdentity: IdentityKind { public static let prefix = "w" }
public typealias PaneID = Identity<PaneIdentity>
public typealias TabID = Identity<TabIdentity>
public typealias GroupID = Identity<GroupIdentity>

public struct Identity<Kind: IdentityKind>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let number: Int
    public var description: String { "\(Kind.prefix)\(number)" }

    public init(_ number: Int) {
        precondition(number > 0)
        self.number = number
    }

    public init(parsing value: String) throws {
        guard value.hasPrefix(Kind.prefix),
              let number = Int(value.dropFirst(Kind.prefix.count)), number > 0,
              value == "\(Kind.prefix)\(number)" else {
            throw WorkspaceError.invalidIdentity(value)
        }
        self.number = number
    }

    public init(from decoder: any Decoder) throws {
        try self.init(parsing: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
