import Foundation
import Testing
import SlateTermCore
@testable import SlateTermCLI

@Test func cliNamespaceAliasesStayInTheAuthoritativeCatalog() {
    let namespaces: [(String, [String])] = [
        ("api", APICLI.Action.allCases.map(\.rawValue)),
        ("workspace", WorkspaceCLI.Action.allCases.map(\.rawValue)),
        ("context", ContextCommand.Action.allCases.map(\.rawValue)),
        ("command", Commands.Action.allCases.map(\.rawValue)),
        ("terminal", TerminalCommand.Action.allCases.map(\.rawValue)),
        ("browser", BrowserCommand.Action.allCases.map { String($0.method.dropFirst("browser.".count)) }),
        ("web", WebCLI.Action.allCases.map { String($0.method.dropFirst("web.".count)) }),
        ("plugins", Plugins.Action.allCases.filter { ![.validate, .settings, .service].contains($0) }.map(\.rawValue)),
        ("events", Events.Action.allCases.map { $0 == .watch ? "poll" : $0.rawValue }),
        ("config", ConfigCommand.Action.allCases.map { $0 == .set ? "patch" : $0.rawValue })
    ]
    for action in SavedLayoutsCommand.Action.allCases {
        #expect(AutomationMethod(rawValue: action.method)?.isPublic == true)
    }
    for (namespace, aliases) in namespaces {
        for alias in aliases {
            let name = "\(namespace).\(alias)"
            #expect(AutomationMethod(rawValue: name)?.isPublic == true, "CLI alias is missing from the shared API: \(name)")
        }
    }
    for (namespace, family) in [("terminal", AutomationMethod.Family.terminal), ("browser", .browser), ("web", .web)] {
        let aliases = Set(namespaces.first { $0.0 == namespace }!.1.map { "\(namespace).\($0)" })
        #expect(aliases == Set(AutomationMethod.publicMethods.filter { $0.family == family }.map(\.rawValue)))
    }
}

@Test func cliLiteralAliasesStayInTheAuthoritativeCatalog() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("Sources/SlateTermCLI")
    let expression = try NSRegularExpression(pattern: #"\.call\("([a-zA-Z.]+)"(?=[,)])"#)
    var count = 0
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
        let source = try String(contentsOf: file, encoding: .utf8)
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let name = String(source[Range(match.range(at: 1), in: source)!])
            #expect(AutomationMethod(rawValue: name) != nil, "CLI literal is missing from the catalog: \(name)")
            count += 1
        }
    }
    #expect(count > 0)
}

@Test func savedLayoutCLIOnlyOpensNewWindowsAndAcceptsExplicitLaunchers() throws {
    #expect(throws: (any Error).self) { try SavedLayoutsCommand.parse(["open", "--id", "id", "--replace-window", "window"]) }
    #expect(throws: (any Error).self) { try SavedLayoutsCommand.parse(["open", "--id", "id", "--force"]) }
    let launcher = try SavedLayoutsCommand.parse(["launcher", "--id", "id", "--path", "/tmp/Test.app"])
    #expect(launcher.action == .launcher && launcher.path == "/tmp/Test.app")
}

@Test func eventRecipientOptionsMatchTheHostSelectors() throws {
    #expect(try Events.recipient("all") == .string("all"))
    #expect(try Events.recipient("instance:i1") == .object(["instanceId": .string("i1")]))
    let service: JSONValue = .object(["serviceId": .string("acme:svc"), "generation": .string("G1")])
    #expect(try Events.recipient("service:acme:svc:G1") == service)
    #expect(try Events.serviceRecipient("acme:svc:G1") == service)
    for invalid in ["", "instance:", "service:G1", "service::G1", "service:svc:", "everyone"] {
        #expect(throws: (any Error).self) { try Events.recipient(invalid) }
    }
    let poll = try Events.parse(["poll", "--recipient", "service:svc:G1", "--scope", "global"])
    #expect(poll.recipient == "service:svc:G1" && poll.scope == "global")
}
