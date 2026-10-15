import AppKit
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    var agentSkills: AgentSkills {
        AgentSkills(home: settings.agentHome,
                    bundled: Bundle.main.resourceURL!.appendingPathComponent("skills/\(AgentSkills.skillName)"),
                    managed: settings.base.appendingPathComponent("skills/\(AgentSkills.skillName)"))
    }

    func agentSkillsInfo() -> JSONValue {
        let skills = agentSkills
        return .object([
            "skill": .object(["name": .string(AgentSkills.skillName), "path": .string(skills.managed.path), "bundledPath": .string(skills.bundled.path)]),
            "agents": .array(skills.entries().map { entry in
                .object(["id": .string(entry.target.id), "name": .string(entry.target.name), "detail": .string(entry.target.detail),
                         "path": .string(entry.path.path), "detected": .bool(entry.detected), "status": .string(entry.status.rawValue)])
            }),
        ])
    }

    func listAgentSkills(_ params: [String: JSONValue]) throws -> JSONValue {
        guard withoutAPIGuards(params).isEmpty else { throw RPCFailure(code: -32602, message: "skills.list takes no payload parameters") }
        return agentSkillsInfo()
    }

    /// Shared by skills.install, skills.uninstall and the Settings buttons.
    func changeAgentSkills(_ params: [String: JSONValue], install: Bool) throws -> JSONValue {
        let input = withoutAPIGuards(params)
        guard input.keys.allSatisfy({ $0 == "agents" }), case .array(let values) = input["agents"],
              let ids = Optional(values.compactMap(\.string)), ids.count == values.count else {
            throw RPCFailure(code: -32602, message: "agents must be an array of agent IDs, such as [\"agents\", \"claude\"]")
        }
        do {
            if install { try agentSkills.install(ids) } else { try agentSkills.uninstall(ids) }
        } catch let error as AgentSkillsError {
            refreshAgentSkillsSettings()
            switch error {
            case .invalid: throw RPCFailure(code: -32602, message: error.description)
            case .conflict: throw RPCFailure(code: APIError.conflict, message: error.description)
            case .missingBundle: throw RPCFailure(code: APIError.unavailable, message: error.description)
            }
        }
        refreshAgentSkillsSettings()
        return agentSkillsInfo()
    }

    /// Shows the skill in Finder, creating the managed copy first when no agent uses it yet.
    func revealAgentSkill() throws -> JSONValue {
        let skills = agentSkills
        if !FileManager.default.fileExists(atPath: skills.managed.path) {
            do { try skills.refreshManagedCopy() }
            catch { throw RPCFailure(code: APIError.unavailable, message: String(describing: error)) }
        }
        NSWorkspace.shared.activateFileViewerSelecting([skills.managed])
        return .object(["path": .string(skills.managed.path)])
    }

    func refreshAgentSkillsSettings() {
        let entries = agentSkills.entries()
        if settingsModel?.agentSkills != entries { settingsModel?.agentSkills = entries }
    }
}
