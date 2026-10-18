import AppKit
import WebKit
import SlateTermCore

@main
@MainActor
struct BrowserDataChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    static func cookie(_ domain: String) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: "/", .name: "fixture", .value: "saved", .expires: Date(timeIntervalSinceNow: 3600)])!
    }
    static func identifier(in directory: URL) throws -> UUID {
        try JSONDecoder().decode(UUID.self, from: Data(contentsOf: directory.appendingPathComponent("browser-profile.json")))
    }
    static func identifiers() async -> [UUID] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
        }
    }
    static func requireRemoved(_ identifier: UUID) async throws {
        try require(!(await identifiers()).contains(identifier), "Removed profile remains on disk")
        // Detect late directory creation as well as an immediate removal error.
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(!(await identifiers()).contains(identifier), "Cleanup recreated the removed profile")
    }
    static func unusedProfileCleanup(in directory: URL) async throws {
        let bootstrap = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(bootstrap) {} }
        try await BrowserData.removeTestProfile(directory: directory.appendingPathComponent("missing"))
        for index in 0..<10 {
            let root = directory.appendingPathComponent("unused-\(index)")
            // Metadata is created at startup even for terminal-only/private launches.
            _ = try BrowserData(directory: root)
            let id = try identifier(in: root)
            try require(!(await identifiers()).contains(id), "Unused fixture unexpectedly created a profile")
            try await BrowserData.removeTestProfile(directory: root)
            try await requireRemoved(id)
            try await BrowserData.removeTestProfile(directory: root)
            try await requireRemoved(id)
        }
        let guarded = directory.appendingPathComponent("invalid-permissions")
        _ = try BrowserData(directory: guarded)
        let metadata = guarded.appendingPathComponent("browser-profile.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: metadata.path)
        do {
            try await BrowserData.removeTestProfile(directory: guarded)
            throw Failure(message: "Cleanup accepted non-private metadata")
        } catch let error as Failure { throw error }
        catch { /* PrivateJSONStore's failure must propagate, not become success. */ }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        try await BrowserData.removeTestProfile(directory: guarded)
        try await requireRemoved(identifier(in: guarded))
    }
    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var failure: Error?
        var usedProfileID: UUID?
        do {
            try await unusedProfileCleanup(in: directory.appendingPathComponent("cleanup-regressions"))
            do {
                let data = try BrowserData(directory: directory)
                let same = try BrowserData(directory: directory)
                try require(data.persistent.identifier == same.persistent.identifier, "Profile changed when reopened")
                let a = data.store(for: .privateBrowser), b = data.store(for: .privateBrowser)
                try require(a !== b && !a.isPersistent && data.persistent.isPersistent, "Incorrect browser store ownership")
                await data.persistent.httpCookieStore.setCookie(cookie("example.com"))
                usedProfileID = data.persistent.identifier
                guard let usedProfileID else { throw Failure(message: "Named profile has no identifier") }
                try require((await WKWebsiteDataStore.allDataStoreIdentifiers).contains(usedProfileID), "Used profile is missing from cleanup enumeration")
                await data.persistent.httpCookieStore.setCookie(cookie("other.org"))
                try require((await identifiers()).contains(try identifier(in: directory)), "Populated profile is missing on disk")
                await a.httpCookieStore.setCookie(cookie("example.com"))
                try require(await b.httpCookieStore.allCookies().isEmpty, "Private panes shared cookies")
                let site = try BrowserDataRequest(kind: .site, params: ["pane": .string("p1"), "url": .string("https://www.example.com/path")])
                var checks = 0
                do {
                    _ = try await data.clear(site, store: data.persistent) {
                        checks += 1
                        if checks == 2 { throw Failure(message: "retired") }
                    }
                    throw Failure(message: "Stale target was not rechecked after fetching records")
                } catch let error as Failure { try require(error.message == "retired", "Unexpected stale target failure") }
                try require(await data.persistent.httpCookieStore.allCookies().count == 2, "Stale clear removed cookies")
                _ = try await data.clear(site, store: data.persistent) {}
                let remaining = await data.persistent.httpCookieStore.allCookies()
                try require(remaining.count == 1 && remaining[0].domain == "other.org", "Site clear removed an unrelated domain or missed its parent group")
                try require(await a.httpCookieStore.allCookies().count == 1, "Persistent clear touched private store")
                _ = try await data.clear(site, store: a) {}
                try require(await a.httpCookieStore.allCookies().isEmpty, "Private site clear failed")
                _ = try await data.clear(BrowserDataRequest(kind: .all, params: [:]), store: data.persistent) {}
                try require(await data.persistent.httpCookieStore.allCookies().isEmpty, "All-data clear failed")
                // Private suffixes are different sites, not simple suffix matches.
                await data.persistent.httpCookieStore.setCookie(cookie("github.io"))
                await data.persistent.httpCookieStore.setCookie(cookie("alice.github.io"))
                try require(await data.persistent.httpCookieStore.allCookies().count == 2, "PSL fixture cookies were not stored")
                let absent = try BrowserDataRequest(kind: .site, params: ["pane": .string("p1"), "url": .string("https://unused.github.io")])
                _ = try await data.clear(absent, store: data.persistent) {}
                try require(await data.persistent.httpCookieStore.allCookies().count == 2, "Absent tenant cleared its unrelated public-suffix parent")
                let tenant = try BrowserDataRequest(kind: .site, params: ["pane": .string("p1"), "url": .string("https://www.alice.github.io")])
                _ = try await data.clear(tenant, store: data.persistent) {}
                let tenants = await data.persistent.httpCookieStore.allCookies()
                try require(tenants.count == 1 && tenants[0].domain == "github.io", "Tenant clear affected a separate PSL site")
                for url in ["http://[::1]:8080/", "https://bücher.example", "https://www.example.co.uk"] {
                    let request = try BrowserDataRequest(kind: .site, params: ["pane": .string("p1"), "url": .string(url)])
                    await a.httpCookieStore.setCookie(cookie(request.host!))
                    try require(await a.httpCookieStore.allCookies().count == 1, "Host fixture was not stored: \(url)")
                    _ = try await data.clear(request, store: a) {}
                    try require(await a.httpCookieStore.allCookies().isEmpty, "Host group was not removed: \(url)")
                }
            }
        } catch { failure = error }
        // Release all users before cleanup, on failure as well as success.
        do {
            try await BrowserData.removeTestProfile(directory: directory)
            // This profile held real persistent cookies, unlike the unused fixtures.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("browser-profile.json").path) {
                let id = try identifier(in: directory)
                try await requireRemoved(id)
                try await BrowserData.removeTestProfile(directory: directory)
                try await requireRemoved(id)
            }
        }
        catch {
            fputs("FAIL browser profile cleanup (ownership metadata retained at \(directory.path)): \(error)\n", stderr)
            exit(1)
        }
        if let failure {
            fputs("FAIL browser data: \(failure)\n", stderr)
            exit(1)
        }
        print("PASS browser stores: shared profile identity, private isolation, PSL/IDN/IPv6 domain-group removal, private/all-data clearing, post-fetch liveness, unused/populated/repeated profile cleanup and metadata validation")
    }
}
