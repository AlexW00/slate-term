import Foundation

/// Data clearing is distinct from navigation: never guess a scheme or use live focus/URL for API calls.
public struct BrowserDataRequest: Sendable {
    public enum Kind: Sendable { case all, site }
    public let kind: Kind
    public let host: String?

    public init(kind: Kind, params: [String: JSONValue]) throws {
        let allowed: Set<String> = kind == .all ? [] : ["pane", "tab", "url"]
        guard Set(params.keys).isSubset(of: allowed) else { throw Self.invalid("Unknown browser data parameter") }
        self.kind = kind
        if kind == .all { host = nil; return }
        guard let text = params["url"]?.string else { throw Self.invalid("url is required") }
        host = try Self.siteHost(text)
        for key in ["pane", "tab"] where params[key] != nil {
            guard let value = params[key]?.string, !value.isEmpty else { throw Self.invalid("\(key) must be a nonempty string") }
        }
        guard params["pane"] != nil else { throw Self.invalid("An explicit browser pane is required") }
    }

    public static func siteHost(_ text: String) throws -> String {
        guard text.utf8.count <= 16_384, !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              text.range(of: "%(?![0-9a-fA-F]{2})", options: .regularExpression) == nil,
              let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              url.port == nil || (0...65_535).contains(url.port!),
              let host = url.host, !host.isEmpty else { throw Self.invalid("Use an absolute HTTP or HTTPS URL without credentials") }
        let normalized = normalizedHost(host)
        guard !normalized.isEmpty else { throw Self.invalid("URL host must not be empty") }
        return normalized
    }

    private static func normalizedHost(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }
    private static func invalid(_ message: String) -> RPCFailure { RPCFailure(code: -32602, message: message) }
}
