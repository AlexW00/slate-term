import Foundation

/// Payload validation only. Native display limits and transitions are checked at submission.
public struct NativeWindowAction: Sendable {
    public static let commands: Set<String> = ["window.frame.set", "window.minimize", "window.restore", "window.fullscreen.set"]
    public struct Frame: Sendable {
        public let x: Double, y: Double, width: Double, height: Double
    }
    public let windowID: String
    public let frame: Frame?
    public let fullscreen: Bool?

    public init(command: String, params: [String: JSONValue]) throws {
        func invalid(_ text: String) -> RPCFailure { RPCFailure(code: -32602, message: text) }
        guard Self.commands.contains(command), let window = params["windowId"]?.string,
              !window.isEmpty, window.utf8.count <= 128 else { throw invalid("An explicit windowId from window.list is required") }
        var allowed: Set<String> = ["id", "windowId"]
        if command == "window.frame.set" { allowed.formUnion(["x", "y", "width", "height"]) }
        if command == "window.fullscreen.set" { allowed.insert("fullscreen") }
        guard Set(params.keys).isSubset(of: allowed) else { throw invalid("Unknown native window parameter") }
        windowID = window
        if command == "window.frame.set" {
            func number(_ key: String) throws -> Double {
                let result: Double
                switch params[key] {
                case .integer(let value): result = Double(value)
                case .number(let value): result = value
                default: throw invalid("\(key) must be a finite number in screen-global bottom-left points")
                }
                guard result.isFinite, abs(result) <= 1_000_000,
                      !["width", "height"].contains(key) || result > 0 else { throw invalid("Invalid window frame \(key)") }
                return result
            }
            frame = try Frame(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
        } else { frame = nil }
        if command == "window.fullscreen.set" {
            guard case .bool(let value) = params["fullscreen"] else { throw invalid("fullscreen must be a Boolean") }
            fullscreen = value
        } else { fullscreen = nil }
    }
}

public enum WarningSuppression {
    public static func value(command: String, params: [String: JSONValue]) throws -> Bool {
        let setter = ["warnings.close.set", "warnings.type.set"].contains(command)
        guard setter || ["warnings.close.reset", "warnings.type.reset"].contains(command),
              Set(params.keys).isSubset(of: setter ? ["id", "suppressed"] : ["id"]) else {
            throw RPCFailure(code: -32602, message: "Unknown warning preference command or parameter")
        }
        if !setter { return false }
        guard case .bool(let value) = params["suppressed"] else { throw RPCFailure(code: -32602, message: "suppressed must be a Boolean") }
        return value
    }
}
