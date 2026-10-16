import Foundation
import SlateTermCore

/// Owned by the host's main actor and existing single-writer state-directory lease.
/// Optional onboarding state must not become a prerequisite for starting a terminal.
public final class WelcomeStore {
    private let url: URL
    public private(set) var acknowledged: Bool?
    public private(set) var revision = UUID().uuidString
    public private(set) var diagnostic: String?

    public init(url: URL) {
        self.url = url
        do { acknowledged = try store().load(Bool.self) ?? false }
        catch { diagnostic = String(describing: error) }
    }

    public var snapshot: WelcomeSnapshot {
        WelcomeSnapshot(acknowledged: acknowledged, revision: revision,
                        error: acknowledged == nil ? "Welcome preference could not be read; automatic display is paused." : nil)
    }

    /// Explicit acknowledgement/reset can repair malformed content; merely reading or
    /// opening a terminal never overwrites it. Permissions/symlink guards still apply.
    @discardableResult
    public func setAcknowledged(_ value: Bool) throws -> Bool {
        guard acknowledged != value else { return false }
        do { try store().save(value) }
        catch { diagnostic = String(describing: error); throw error }
        acknowledged = value
        revision = UUID().uuidString
        diagnostic = nil
        return true
    }

    private func store() throws -> PrivateJSONStore {
        try PrivateJSONStore(url: url, maximumBytes: 128)
    }
}
