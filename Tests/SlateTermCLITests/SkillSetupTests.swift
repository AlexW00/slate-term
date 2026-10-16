import Testing
import SlateTermCore
@testable import SlateTermCLI

private let skillListing: JSONValue = .object(["agents": .array([
    .object(["id": .string("agents"), "name": .string("Shared (.agents)"), "detail": .string("Shared skills"),
             "path": .string("/fixture/.agents/skills/slate-terminal"), "detected": .bool(true), "status": .string("notInstalled")]),
    .object(["id": .string("claude"), "name": .string("Claude Code"), "detail": .string("Claude skills"),
             "path": .string("/fixture/.claude/skills/slate-terminal"), "detected": .bool(false), "status": .string("installed")]),
    .object(["id": .string("codex"), "name": .string("Codex"), "detail": .string("Codex skills"),
             "path": .string("/fixture/.codex/skills/slate-terminal"), "detected": .bool(true), "status": .string("conflict")])
])])

@Test func skillSetupValidatesSelectionAndConfirmsOneSharedInstall() throws {
    var input = ["nope", "3", "1, claude, 1", "yes"]
    var output = ""
    var installs = 0
    try SkillSetup.run(request: { method, params in
        if method == "skills.list" {
            #expect(params.isEmpty)
            return skillListing
        }
        #expect(method == "skills.install")
        #expect(params == ["agents": .array([.string("agents"), .string("claude")])])
        #expect(input.isEmpty, "Must not mutate before explicit confirmation")
        installs += 1
        return skillListing
    }, readInput: { input.removeFirst() }, write: { output += $0 })
    #expect(installs == 1)
    #expect(output.contains("Cannot select 'nope'"))
    #expect(output.contains("Cannot select '3'"))
    #expect(output.contains("/fixture/.claude/skills/slate-terminal"))
    #expect(output.contains("conflict; existing item will not be replaced"))
    #expect(output.contains("Skill installed for Shared (.agents), Claude Code"))
}

@Test func skillSetupWrapsSelectionCopyForNarrowTerminals() throws {
    var output = ""
    var input = ["1", "yes"]
    try SkillSetup.run(columns: 40, request: { method, _ in
        #expect(["skills.list", "skills.install"].contains(method))
        return skillListing
    }, readInput: {
        output += "\n" // A terminal echoes Return before readLine completes.
        return input.removeFirst()
    }, write: { output += $0 })
    #expect(output.split(separator: "\n").allSatisfy { $0.count < 40 })
    #expect(output.contains("    /fixture/.agents/skills\n    /slate-terminal"))
    #expect(output.contains("1. Shared (.agents) [agents]"))
    #expect(output.contains("Selection (Enter to cancel): "))
}

@Test func skillSetupCancellationAndEOFNeverInstall() throws {
    for answers: [String] in [[], [""], ["q"], ["1"], ["1", ""], ["1", "no"]] {
        var input = answers
        var output = ""
        try SkillSetup.run(request: { method, _ in
            #expect(method == "skills.list", "Cancellation must never send a mutation")
            return skillListing
        }, readInput: { input.isEmpty ? nil : input.removeFirst() }, write: { output += $0 })
        #expect(output.hasSuffix("Cancelled. No skills were changed.\n"))
    }
}

@Test func skillSetupDoesNotRetryFailedInstallsOrClaimSuccess() throws {
    var input = ["1", "y"]
    var output = ""
    var installs = 0
    #expect(throws: RPCFailure.self) {
        try SkillSetup.run(request: { method, _ in
            if method == "skills.list" { return skillListing }
            installs += 1
            throw RPCFailure(code: -32050, message: "Destination changed")
        }, readInput: { input.removeFirst() }, write: { output += $0 })
    }
    #expect(installs == 1)
    #expect(!output.contains("Skill installed for"))
}

@Test func skillSetupIsAdditiveAndRejectsAutomationFlags() throws {
    let setup = try SkillCLI.parse(["setup"])
    #expect(setup.action == .setup)
    let install = try SkillCLI.parse(["install", "--agent", "agents", "--agent", "claude", "--json"])
    #expect(install.action == .install && install.agents == ["agents", "claude"] && install.connection.json)
    for args in [["setup", "--json"], ["setup", "--agent", "claude"]] {
        let invalid = try SkillCLI.parse(args)
        #expect(throws: (any Error).self) { try invalid.run() }
    }
}
