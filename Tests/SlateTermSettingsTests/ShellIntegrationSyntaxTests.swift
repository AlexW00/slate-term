import Foundation
import Testing
import SlateTermCore
@testable import SlateTermSettings

/// Every shell parses its hooks without running them, so a syntax slip can never reach users.
/// Uses the system shells and, when present, the test shells from scripts/build-test-shells.sh.
@Test(arguments: ShellKind.allCases) func hooksParseInEveryAvailableShell(_ kind: ShellKind) throws {
    let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/test-shells").path
    let shells: [String]
    switch kind {
    case .zsh: shells = ["/bin/zsh"]
    case .bash: shells = ["/bin/bash", built + "/bash-5.2/bash", built + "/bash-5.3/bash", "/opt/homebrew/bin/bash"]
    case .fish: shells = [built + "/fish-4/fish", "/opt/homebrew/bin/fish"]
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("slate-hooks-\(UUID().uuidString).\(kind.rawValue)")
    try ShellIntegration.hooks(for: kind).write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    for path in shells where FileManager.default.isExecutableFile(atPath: path) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = [kind == .fish ? "--no-execute" : "-n", file.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0 && message.isEmpty, "\(path): \(message)")
    }
}

@Test func zshBootstrapParses() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("slate-zshenv-\(UUID().uuidString)")
    try ShellIntegration.zshBootstrap.write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-n", file.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}
