import Foundation
import WebKit
import SlateTermCore
import SlateTermSettings

/// One named persistent profile per application state directory, never WebKit's global default.
/// Plugin stores are deliberately not owned here. Private panes each allocate a fresh ephemeral store.
@MainActor
final class BrowserData {
    private let identifier: UUID
    // Private-only/terminal launches must not create an unused on-disk WebKit profile.
    lazy var persistent = WKWebsiteDataStore(forIdentifier: identifier)
    private var clearing: Set<ObjectIdentifier> = []

    init(directory: URL) throws {
        let file = try PrivateJSONStore(url: directory.appendingPathComponent("browser-profile.json"), maximumBytes: 128)
        let identifier: UUID
        if let saved = try file.load(UUID.self) { identifier = saved }
        else { identifier = UUID(); try file.save(identifier) }
        guard identifier != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else {
            throw RPCFailure(code: -32602, message: "Invalid browser profile identifier")
        }
        self.identifier = identifier
    }

    static func removeTestProfile(directory: URL) async throws {
        let file = try PrivateJSONStore(url: directory.appendingPathComponent("browser-profile.json"), maximumBytes: 128)
        guard let identifier = try file.load(UUID.self) else { return }
        // Initialize WebKit without creating the very profile we want to remove.
        // Terminal/private/plugin-only fixtures have an ID but no persistent store;
        // instantiating it here races lazy disk creation against removal.
        let initializationStore = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(initializationStore) {} }
        let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
        guard identifiers.contains(identifier) else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func store(for type: PaneType) -> WKWebsiteDataStore {
        precondition(type.isBrowser)
        return type == .privateBrowser ? .nonPersistent() : persistent
    }

    /// Ask WebKit to classify the host in a disposable in-memory cookie store. Suffix
    /// matching alone would incorrectly clear github.io when targeting alice.github.io
    /// (a separate PSL site), especially when the target has no existing data record.
    /// No network request or mutation of the selected store is involved.
    private func siteDomain(for host: String) async throws -> String {
        let probe = WKWebsiteDataStore.nonPersistent()
        guard let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: "slate-site-probe", .value: "1"]) else {
            throw RPCFailure(code: -32602, message: "WebKit could not identify this site's data group")
        }
        await probe.httpCookieStore.setCookie(cookie)
        let records = await probe.dataRecords(ofTypes: [WKWebsiteDataTypeCookies])
        guard records.count == 1, let domain = records.first?.displayName, !domain.isEmpty else {
            throw RPCFailure(code: -32602, message: "WebKit could not identify this site's data group")
        }
        return domain
    }

    func sites() async -> [String] {
        let records = await persistent.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return Set(records.map(\.displayName)).sorted()
    }

    func clear(_ request: BrowserDataRequest, store: WKWebsiteDataStore,
               beforeSubmission: @MainActor () throws -> Void) async throws -> JSONValue {
        let identity = ObjectIdentifier(store)
        guard clearing.insert(identity).inserted else { throw RPCFailure(code: -32020, message: "Browser data clearing is already in progress") }
        defer { clearing.remove(identity) }
        try Task.checkCancellation()
        try beforeSubmission()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        if let host = request.host {
            let domain = request.kind == .storedSite ? host : try await siteDomain(for: host)
            let records = await store.dataRecords(ofTypes: types)
            try Task.checkCancellation()
            try beforeSubmission() // Fetching yielded: a pane/caller/guard may have retired.
            let matching = records.filter { $0.displayName == domain }
            if !matching.isEmpty { await store.removeData(ofTypes: types, for: matching) }
        } else {
            await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        }
        return .object(["cleared": .bool(true), "scope": .string(request.host == nil ? "all" : "site"),
                        "storage": .string(store.isPersistent ? "persistent" : "private"),
                        "host": request.host.map(JSONValue.string) ?? .null])
    }
}
