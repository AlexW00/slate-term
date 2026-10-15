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
        ("browser", BrowserCommand.Action.allCases.map(\.rawValue)),
        ("web", WebCLI.Action.allCases.map(\.rawValue)),
        ("plugins", Plugins.Action.allCases.filter { ![.validate, .settings, .service].contains($0) }.map(\.rawValue)),
        ("events", Events.Action.allCases.map { $0 == .watch ? "poll" : $0.rawValue }),
        ("config", ConfigCommand.Action.allCases.map { $0 == .set ? "patch" : $0.rawValue })
    ]
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
