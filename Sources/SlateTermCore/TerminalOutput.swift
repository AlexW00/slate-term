/// Bounded current-screen text. This is not a per-command stdout stream.
public struct TerminalOutput: Encodable, Sendable {
    public static let maximumBytes = 128 * 1024
    public let text: String
    public let truncated: Bool

    public init(_ text: String) {
        truncated = text.utf8.count > Self.maximumBytes
        guard truncated else { self.text = text; return }
        var suffix = text.utf8.suffix(Self.maximumBytes)
        // Preserve a valid UTF-8 suffix rather than inserting a replacement character.
        while let first = suffix.first, first & 0xC0 == 0x80 { suffix = suffix.dropFirst() }
        self.text = String(decoding: suffix, as: UTF8.self)
    }
}
