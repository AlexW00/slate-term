import Foundation

/// Provisional product copy. Native presentation and CLI output share this one source;
/// changing the wording must never reset the separately persisted acknowledgement.
public struct WelcomeContent: Codable, Equatable, Sendable {
    public let title: String
    public let paragraphs: [String]
    public static let skillCommand = "slate-term skill setup"
    public static let readCommand = "slate-term welcome --read"
    public static let current = WelcomeContent(
        title: "Welcome to Slate Terminal",
        paragraphs: [
            "Start with a terminal. Build your own workspace with apps, widgets, and your coding agent.",
            "Give your coding agent the Slate Terminal skill. Choose where to install it with \(skillCommand)",
            "To stop showing this message, run \(readCommand)"
        ])

    public var text: String { ([title] + paragraphs).joined(separator: "\n\n") + "\n" }
}

/// A null acknowledgement means the preference could not be read, not 'unread'.
/// Revision is an opaque app-lifetime token; it is independent of workspace revisions.
public struct WelcomeSnapshot: Codable, Equatable, Sendable {
    public let content: WelcomeContent
    public let acknowledged: Bool?
    public let automaticDisplayEnabled: Bool
    public let revision: String
    public let error: String?

    public init(acknowledged: Bool?, revision: String, error: String?) {
        content = .current
        self.acknowledged = acknowledged
        automaticDisplayEnabled = acknowledged == false
        self.revision = revision
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case content, acknowledged, automaticDisplayEnabled, revision, error }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(content, forKey: .content)
        try values.encode(acknowledged, forKey: .acknowledged)
        try values.encode(automaticDisplayEnabled, forKey: .automaticDisplayEnabled)
        try values.encode(revision, forKey: .revision)
        try values.encode(error, forKey: .error)
    }
}
