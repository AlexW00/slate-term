import Foundation

/// Checked DOM-automation input. Routing belongs to the host, not page script arguments.
public struct BrowserAction: Sendable {
    public enum Kind: String, Sendable { case snapshot, click, fill, select, scroll, wait, focus, key, check, setValue }
    public let kind: Kind
    public let parameters: [String: JSONValue]
    public let timeoutMilliseconds: Int

    public init(kind name: String, params: [String: JSONValue]) throws {
        guard let kind = Kind(rawValue: name) else { throw Self.invalid("Unknown browser action") }
        self.kind = kind
        var allowed: Set<String> = ["pane", "tab"]
        var checked: [String: JSONValue] = [:]
        let needsTarget = [.click, .fill, .select, .wait, .focus, .key, .check, .setValue].contains(kind)
        if needsTarget || kind == .scroll {
            allowed.formUnion(["selector", "ref"])
            let targets = ["selector", "ref"].filter { params[$0] != nil }
            guard targets.count <= 1, !needsTarget || targets.count == 1 else {
                throw Self.invalid("Supply exactly one selector or ref for an element action")
            }
            if let target = targets.first {
                checked[target] = .string(try Self.string(target, in: params, maximumBytes: 2_048, allowEmpty: false))
            }
        }
        var timeout = 10_000
        switch kind {
        case .snapshot:
            allowed.insert("maxElements")
            checked["maxElements"] = .integer(try Self.integer("maxElements", in: params, default: 128, range: 1...256))
        case .click, .focus: break
        case .key:
            allowed.insert("key")
            let chord = try Self.string("key", in: params, maximumBytes: 128, allowEmpty: false)
            let pieces = chord.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            let modifiers = Array(pieces.dropLast())
            let named = ["enter", "tab", "escape", "space", "backspace", "delete", "home", "end",
                         "arrowleft", "arrowright", "arrowup", "arrowdown", "pageup", "pagedown"]
            guard let key = pieces.last,
                  named.contains(key) || (key.utf8.count == 1 && key.utf8.allSatisfy({ (33...126).contains($0) })),
                  Set(modifiers).count == modifiers.count, modifiers.allSatisfy({ ["ctrl", "alt", "shift", "meta"].contains($0) }) else {
                throw Self.invalid("Use a named web key or ASCII character with unique ctrl/alt/shift/meta modifiers")
            }
            checked["key"] = .string(key)
            checked["modifiers"] = .array(modifiers.map(JSONValue.string))
        case .check:
            allowed.insert("checked")
            guard case .bool(let value) = params["checked"] else { throw Self.invalid("checked must be a Boolean") }
            checked["checked"] = .bool(value)
        case .setValue:
            allowed.insert("value")
            checked["value"] = .string(try Self.string("value", in: params, maximumBytes: 4096, allowEmpty: true))
        case .fill:
            allowed.insert("text")
            checked["text"] = .string(try Self.string("text", in: params, maximumBytes: 65_536, allowEmpty: true))
        case .select:
            allowed.insert("values")
            guard case .array(let values) = params["values"], values.count <= 64 else {
                throw Self.invalid("values must be an array of at most 64 strings")
            }
            for value in values {
                guard let string = value.string, string.utf8.count <= 4_096 else { throw Self.invalid("Option values must be strings of at most 4096 UTF-8 bytes") }
            }
            checked["values"] = .array(values)
        case .scroll:
            allowed.formUnion(["x", "y"])
            for key in ["x", "y"] {
                let number: Double
                switch params[key] {
                case nil: number = 0
                case .integer(let value): number = Double(value)
                case .number(let value): number = value
                default: throw Self.invalid("\(key) must be a finite scroll distance in CSS pixels")
                }
                guard number.isFinite, abs(number) <= 10_000_000 else { throw Self.invalid("Scroll distances must be within 10 million CSS pixels") }
                checked[key] = .number(number)
            }
        case .wait:
            allowed.formUnion(["state", "timeoutMilliseconds"])
            let state = params["state"] == nil ? "visible" : try Self.string("state", in: params, maximumBytes: 16, allowEmpty: false)
            guard ["attached", "detached", "visible", "hidden"].contains(state) else { throw Self.invalid("state must be attached, detached, visible, or hidden") }
            checked["state"] = .string(state)
            timeout = try Self.integer("timeoutMilliseconds", in: params, default: 10_000, range: 0...10_000)
        }
        guard params.keys.allSatisfy({ allowed.contains($0) }) else { throw Self.invalid("Unknown parameter for browser.\(name)") }
        parameters = checked
        timeoutMilliseconds = timeout
    }

    private static func string(_ key: String, in params: [String: JSONValue], maximumBytes: Int, allowEmpty: Bool) throws -> String {
        guard let value = params[key]?.string, value.utf8.count <= maximumBytes, allowEmpty || !value.isEmpty else {
            throw invalid("\(key) must be \(allowEmpty ? "a" : "a nonempty") string of at most \(maximumBytes) UTF-8 bytes")
        }
        return value
    }
    private static func integer(_ key: String, in params: [String: JSONValue], default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = params[key] else { return fallback }
        guard case .integer(let integer) = value, range.contains(integer) else { throw invalid("\(key) must be an integer in \(range)") }
        return integer
    }
    private static func invalid(_ message: String) -> RPCFailure { RPCFailure(code: -32602, message: message) }
}
