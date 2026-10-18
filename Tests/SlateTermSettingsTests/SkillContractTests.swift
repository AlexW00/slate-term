import Foundation
import Testing
import SlateTermCore
import SlateTermSettings
import SlateTermTestSupport

@Test func skillContractsMatchTargetsAndPartialMultiAgentOutcomes() throws {
    let contract = AutomationContracts.skills[.skillsInstall]!
    let agentSchema = contract.input.object!["properties"]!.object!["agents"]!.object!["items"]!
    #expect(agentSchema.object?["enum"] == .array(AgentSkills.targets.map { .string($0.id) }))
    #expect(!schemaAccepts(contract.input, .object(["agents": .array([])])))
    #expect(!schemaAccepts(contract.input, .object(["agents": .array([.string("unknown")]) ])))
    #expect(schemaAccepts(contract.input, .object(["agents": .array([.string("agents"), .string("agents")]) ])))
    #expect(!schemaAccepts(contract.input, .object(["agents": .array([.string("agents")]), "pane": .string("p1")])))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-skill-contract-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appendingPathComponent("bundle")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try "# Fixture skill\n".write(to: bundle.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    let skills = AgentSkills(home: root.appendingPathComponent("home"), bundled: bundle, managed: root.appendingPathComponent("managed/skill"))
    let foreign = skills.home.appendingPathComponent(".claude/skills/slate-terminal")
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
    let sentinel = foreign.appendingPathComponent("keep.txt")
    try "untouched".write(to: sentinel, atomically: true, encoding: .utf8)
    #expect(throws: AgentSkillsError.self) { try skills.install(["agents", "claude"]) }
    #expect(skills.entries().first { $0.target.id == "agents" }?.status == .installed)
    #expect(skills.entries().first { $0.target.id == "claude" }?.status == .conflict)
    #expect(contract.semantics["atomicAcrossAgents"] == .bool(false))

    // Mirrors the host projection over real filesystem observations; this does
    // not replace the still-required native wire-encoding checks in the VM.
    let response: JSONValue = .object([
        "skill": .object(["name": .string(AgentSkills.skillName), "path": .string(skills.managed.path), "bundledPath": .string(skills.bundled.path)]),
        "agents": .array(skills.entries().map { entry in
            .object(["id": .string(entry.target.id), "name": .string(entry.target.name), "detail": .string(entry.target.detail),
                     "path": .string(entry.path.path), "detected": .bool(entry.detected), "status": .string(entry.status.rawValue)])
        })
    ])
    #expect(schemaAccepts(contract.result, response, definitions: AutomationContracts.skillDefinitions))
    #expect(throws: AgentSkillsError.self) { try skills.uninstall(["agents", "claude"]) }
    #expect(skills.entries().first { $0.target.id == "agents" }?.status == .notInstalled)
    #expect(try String(contentsOf: sentinel, encoding: .utf8) == "untouched")
    #expect(FileManager.default.fileExists(atPath: skills.managed.path))
}
