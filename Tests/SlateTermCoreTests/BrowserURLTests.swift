import Foundation
import Testing
@testable import SlateTermCore

struct BrowserURLTests {
    @Test func localPathsPreserveLiteralCharactersAndFileURLFragments() throws {
        let path = "/tmp/日本語 space # ? %.html"
        let url = try BrowserURL.parse(path)
        #expect(url.isFileURL)
        #expect(url.path == path)
        #expect(try BrowserURL.parse(url.absoluteString) == url)
        #expect(try BrowserURL.parse("~/Movies/clip.mp4").path == ("~/Movies/clip.mp4" as NSString).expandingTildeInPath)
        let anchor = try BrowserURL.parse("file:///tmp/a%20b.html?preview=1#section")
        #expect(anchor.path == "/tmp/a b.html")
        #expect(anchor.query == "preview=1")
        #expect(anchor.fragment == "section")
        #expect(try BrowserURL.parse("file://localhost/tmp/photo.png").isFileURL)
    }

    @Test func networkNavigationAndStartingLocationsKeepDistinctInputRules() throws {
        #expect(try BrowserURL.parse("example.com/path", assumingHTTPS: true).absoluteString == "https://example.com/path")
        #expect(throws: RPCFailure.self) { try BrowserURL.parse("example.com/path") }
        #expect(try BrowserURL.parse("http://localhost:3000/a").host == "localhost")
        #expect(try BrowserURL.parse("https://example.com/日本語 a", assumingHTTPS: true).path == "/日本語 a")
        #expect(try BrowserURL.parse("about:blank").absoluteString == "about:blank")
    }

    @Test(arguments: ["", "file://remote/tmp/page.html", "file://user@localhost/tmp/page.html", "file://localhost:123/tmp/page.html",
                      "file:relative.html", "file:///tmp/a%00.html", "/tmp/a\u{0}.html", "https://user:pass@example.com/",
                      "https://", "https://example.com:99999/", "javascript:alert(1)", "data:text/html,hello", "about:config", "ftp://example.com/"])
    func unsupportedOrCredentialedLocationsAreRejected(_ input: String) {
        #expect(throws: RPCFailure.self) { try BrowserURL.parse(input) }
    }
}
