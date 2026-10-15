import Foundation

/// Browser locations only; plugin origins and search templates have separate rules.
public enum BrowserURL {
    public static func parse(_ text: String, assumingHTTPS: Bool = false) throws -> URL {
        let value = assumingHTTPS ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw invalid()
        }
        if value.hasPrefix("/") || value.hasPrefix("~/") {
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        }
        let normalized = assumingHTTPS && !value.contains("://") && !value.hasPrefix("about:") && !value.lowercased().hasPrefix("file:") ? "https://" + value : value
        // Interactive/API entry keeps Foundation's URL escaping; saved recipes stay strict.
        guard let url = URL(string: normalized, encodingInvalidCharacters: assumingHTTPS), allows(url) else { throw invalid() }
        return url
    }

    public static func allows(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url.host?.isEmpty == false && (url.port == nil || (0...65_535).contains(url.port!))
        case "file":
            guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding else { return false }
            return (url.host == nil || url.host == "" || url.host?.lowercased() == "localhost") && url.port == nil && path.hasPrefix("/") &&
                !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        case "about": return url.absoluteString == "about:blank"
        default: return false
        }
    }

    private static func invalid() -> RPCFailure {
        RPCFailure(code: -32602, message: "Use an HTTP/HTTPS URL, about:blank, or a local file URL or absolute path")
    }
}
