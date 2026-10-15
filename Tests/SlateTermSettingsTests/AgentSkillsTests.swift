import Foundation
import Testing
@testable import SlateTermSettings

private func fixture() throws -> (AgentSkills, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-skills-\(UUID())")
    let bundled = root.appendingPathComponent("bundle/slate-terminal")
    try FileManager.default.createDirectory(at: bundled.appendingPathComponent("references/.claude"), withIntermediateDirectories: true)
    try "---\nname: slate-terminal\n---\n".write(to: bundled.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    try "guide".write(to: bundled.appendingPathComponent("references/guide.md"), atomically: true, encoding: .utf8)
    let skills = AgentSkills(home: root.appendingPathComponent("home"), bundled: bundled,
                             managed: root.appendingPathComponent("state/skills/slate-terminal"))
    return (skills, root)
}

@Test func installLinksToTheManagedCopyAndUninstallRemovesOnlyTheLink() throws {
    let (skills, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(skills.entries().allSatisfy { $0.status == .notInstalled })
    #expect(skills.entries().first { $0.target.id == "agents" }?.detected == true)
    #expect(skills.entries().first { $0.target.id == "claude" }?.detected == false)

    try skills.install(["agents", "claude"])
    let link = root.appendingPathComponent("home/.claude/skills/slate-terminal")
    #expect(try String(contentsOf: link.appendingPathComponent("references/guide.md"), encoding: .utf8) == "guide")
    #expect(!FileManager.default.fileExists(atPath: skills.managed.appendingPathComponent("references/.claude").path), "Hidden files are not copied")
    #expect(Set(skills.entries().filter { $0.status == .installed }.map(\.target.id)) == ["agents", "claude"])
    try skills.install(["claude"]) // no-op

    // An app update refreshes the copy behind existing links.
    try "updated".write(to: skills.bundled.appendingPathComponent("references/guide.md"), atomically: true, encoding: .utf8)
    try skills.refreshIfInstalled()
    #expect(try String(contentsOf: link.appendingPathComponent("references/guide.md"), encoding: .utf8) == "updated")

    try skills.uninstall(["claude", "codex"])
    #expect(!FileManager.default.fileExists(atPath: link.path))
    #expect(FileManager.default.fileExists(atPath: skills.managed.path))
}

@Test func foreignSkillsAreNeverReplacedOrRemoved() throws {
    let (skills, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let foreign = root.appendingPathComponent("home/.codex/skills/slate-terminal")
    try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
    let elsewhere = root.appendingPathComponent("home/.cursor/skills/slate-terminal")
    try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: elsewhere, withDestinationURL: root)

    #expect(skills.entries().first { $0.target.id == "codex" }?.status == .conflict)
    #expect(skills.entries().first { $0.target.id == "cursor" }?.status == .conflict)
    #expect(throws: AgentSkillsError.self) { try skills.install(["codex"]) }
    #expect(throws: AgentSkillsError.self) { try skills.uninstall(["cursor"]) }
    #expect(FileManager.default.fileExists(atPath: foreign.path))
    #expect(throws: AgentSkillsError.self) { try skills.install(["unknown"]) }
    #expect(throws: AgentSkillsError.self) { try skills.install([]) }
}

@Test func installFailsWithoutABundledSkill() throws {
    let (skills, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: skills.bundled)
    #expect(throws: AgentSkillsError.self) { try skills.install(["agents"]) }
    #expect(skills.entries().allSatisfy { $0.status == .notInstalled })
}
