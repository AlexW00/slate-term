import Foundation

/// Historical display text only. It never describes a process to resume or a command to execute.
public struct SavedTerminalOutput: Codable, Equatable, Sendable {
    public static let maximumLines = 100_000
    public static let maximumBytes = 4 * 1024 * 1024
    public static let maximumWorkspaceBytes = 32 * 1024 * 1024

    /// Preserve the screen before shutdown and any output received while it closes.
    public static func mergingShutdown(before: String, after: String) -> String {
        let earlier = before.trimmingCharacters(in: .newlines)
        let final = after.trimmingCharacters(in: .newlines)
        if earlier.isEmpty || final.hasPrefix(earlier) { return final }
        if final.isEmpty || earlier == final { return earlier }
        let oldLines = earlier.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = final.split(separator: "\n", omittingEmptySubsequences: false)
        var common = 0
        while common < min(oldLines.count, newLines.count), oldLines[common] == newLines[common] { common += 1 }
        if common == newLines.count { return earlier }

        // A bounded scrollback can lose its oldest lines while shutdown adds new ones.
        // Match the old suffix to the new prefix in linear time, including repeated lines.
        var prefix = [Int](repeating: 0, count: newLines.count)
        var matched = 0
        for index in 1..<newLines.count {
            while matched > 0 && newLines[index] != newLines[matched] { matched = prefix[matched - 1] }
            if newLines[index] == newLines[matched] { matched += 1 }
            prefix[index] = matched
        }
        matched = 0
        for line in oldLines {
            while matched > 0 && (matched == newLines.count || line != newLines[matched]) { matched = prefix[matched - 1] }
            if line == newLines[matched] { matched += 1 }
        }
        if matched == newLines.count { return earlier }
        if common > matched {
            return earlier + "\n\n── Output received while closing ──\n" + newLines.dropFirst(common).joined(separator: "\n")
        }
        let tail = newLines.dropFirst(matched).joined(separator: "\n")
        return earlier + (matched > 0 ? "\n" : "\n\n── Output received while closing ──\n") + tail
    }

    public var text: String
    public var capturedAt: Date
    /// Whether the terminal's process had already exited when this text was captured.
    public var ended: Bool

    public init(text: String, capturedAt: Date, ended: Bool) {
        self.text = text
        self.capturedAt = capturedAt
        self.ended = ended
    }

    enum CodingKeys: String, CodingKey { case text, capturedAt, ended }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        ended = try container.decode(Bool.self, forKey: .ended)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Saved terminal output exceeds its bounds or has an invalid capture date"))
        }
    }

    public var isValid: Bool {
        let timestamp = capturedAt.timeIntervalSince1970
        // Restrict persisted dates to calendar years 1 through 9999.
        return timestamp.isFinite && (-62_135_596_800...253_402_300_799).contains(timestamp)
            && text.utf8.count <= Self.maximumBytes && Self.lineCount(text) <= Self.maximumLines
    }

    /// Normalize display text before passing it to the terminal's plain-text renderer.
    public var terminalDisplayText: String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var result = ""
        for scalar in normalized.unicodeScalars {
            switch scalar.value {
            case 10: result.append("\n")
            case 9: result.append("    ")
            case 0...31, 127...159: result.append("\u{FFFD}")
            default: result.unicodeScalars.append(scalar)
            }
        }
        return Self.boundedText(result, lineLimit: Self.maximumLines)
    }

    /// A final newline ends the last line; it does not introduce an additional empty line.
    public static func lineCount(_ text: String) -> Int {
        guard let last = text.last else { return 0 }
        return text.reduce(0) { $0 + ($1.isNewline ? 1 : 0) } + (last.isNewline ? 0 : 1)
    }

    /// Retains the newest logical lines without splitting Unicode characters or CRLF endings.
    /// The byte cap can shorten a long line. Invalid limits and zero return no text.
    public static func boundedText(_ text: String, lineLimit: Int, byteLimit: Int = maximumBytes) -> String {
        guard (1...maximumLines).contains(lineLimit), byteLimit > 0 else { return "" }
        let budget = min(byteLimit, maximumBytes)
        var start = text.endIndex
        var bytes = 0
        var lines = 0
        while start > text.startIndex {
            let previous = text.index(before: start)
            let character = text[previous]
            if character.isNewline && start != text.endIndex {
                lines += 1
                if lines >= lineLimit { break }
            }
            let size = text[previous..<start].utf8.count
            guard size <= budget - bytes else { break }
            bytes += size
            start = previous
        }
        return String(text[start...])
    }
}
