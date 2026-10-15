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
    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var failure: Error?
        do {
            do {
                let data = try BrowserData(directory: directory)
                let same = try BrowserData(directory: directory)
                try require(data.persistent.identifier == same.persistent.identifier, "Profile changed when reopened")
                let a = data.store(for: .privateBrowser), b = data.store(for: .privateBrowser)
                try require(a !== b && !a.isPersistent && data.persistent.isPersistent, "Incorrect browser store ownership")
                await data.persistent.httpCookieStore.setCookie(cookie("example.com"))
                await data.persistent.httpCookieStore.setCookie(cookie("other.org"))
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
        do { try await BrowserData.removeTestProfile(directory: directory) }
        catch {
            fputs("FAIL browser profile cleanup (ownership metadata retained at \(directory.path)): \(error)\n", stderr)
            exit(1)
        }
        if let failure {
            fputs("FAIL browser data: \(failure)\n", stderr)
            exit(1)
        }
        print("PASS browser stores: shared profile identity, private isolation, PSL/IDN/IPv6 domain-group removal, private/all-data clearing, post-fetch liveness and profile cleanup")
    }
}
