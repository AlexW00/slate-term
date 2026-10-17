import Foundation

public enum JSONValue: Equatable, Sendable, Codable {
    case null, bool(Bool), integer(Int), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

public struct RPCRequest: Codable, Sendable {
    public var jsonrpc = "2.0"
    public let id: JSONValue?
    public let method: String
    public let params: [String: JSONValue]?
    public let metadata: RPCMetadata?

    public init(id: JSONValue?, method: String, params: [String: JSONValue]? = nil, metadata: RPCMetadata? = nil) {
        self.id = id
        self.method = method
        self.params = params
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params, metadata }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = container.contains(.id) ? try container.decode(JSONValue.self, forKey: .id) : nil
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent([String: JSONValue].self, forKey: .params)
        metadata = container.contains(.metadata) ? try container.decode(RPCMetadata.self, forKey: .metadata) : nil
    }

    public static func decode(_ data: Data) throws -> RPCRequest {
        do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw ProtocolError.parseError }
        let request: RPCRequest
        do { request = try JSONDecoder().decode(RPCRequest.self, from: data) }
        catch { throw ProtocolError.invalidRequest }
        guard request.jsonrpc == "2.0", !request.method.isEmpty else { throw ProtocolError.invalidRequest }
        switch request.id {
        case nil, .null?, .integer?, .string?: return request
        default: throw ProtocolError.invalidRequest
        }
    }
}

public struct RPCResponse: Codable, Sendable {
    public var jsonrpc = "2.0"
    public let id: JSONValue
    public let result: JSONValue?
    public let error: RPCFailure?

    public init(id: JSONValue, result: JSONValue) { self.id = id; self.result = result; error = nil }
    public init(id: JSONValue, error: RPCFailure) { self.id = id; result = nil; self.error = error }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decode(JSONValue.self, forKey: .id)
        result = container.contains(.result) ? try container.decode(JSONValue.self, forKey: .result) : nil
        error = try container.decodeIfPresent(RPCFailure.self, forKey: .error)
    }
}

public struct RPCFailure: Error, Codable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?
    public init(code: Int, message: String, data: JSONValue? = nil) { self.code = code; self.message = message; self.data = data }
}

public enum ProtocolError: Error, Sendable {
    case oversizedMessage, parseError, invalidRequest, handshakeRequired, incompatibleVersion
}

public struct LineFramer: Sendable {
    private var pending = Data()
    private let maximumBytes: Int
    public init(maximumBytes: Int = 1_048_576) { self.maximumBytes = maximumBytes }

    public mutating func append(_ data: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in data {
            if byte == 10 {
                lines.append(pending)
                pending = Data()
            } else {
                guard pending.count < maximumBytes else { throw ProtocolError.oversizedMessage }
                pending.append(byte)
            }
        }
        return lines
    }
}

public struct ProtocolSession: Sendable {
    public enum Accepted: Equatable { case hello, command }
    public private(set) var handshaken = false
    public init() {}

    public mutating func accept(_ request: RPCRequest) throws -> Accepted {
        if request.method == "hello" {
            handshaken = false // A failed renegotiation cannot retain the previous session.
            guard request.metadata == nil else { throw ProtocolError.invalidRequest }
            guard request.params?["protocolVersion"] == .integer(1) else { throw ProtocolError.incompatibleVersion }
            handshaken = true
            return .hello
        }
        guard handshaken else { throw ProtocolError.handshakeRequired }
        return .command
    }
}
