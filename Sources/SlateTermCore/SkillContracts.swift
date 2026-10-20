import Foundation

extension AutomationContracts {
    static let skillAgentIDs = ["agents", "claude", "codex", "cursor", "gemini", "copilot", "opencode"]

    public static let skillDefinitions: [String: JSONValue] = {
        typealias S = APISchema
        func complete(_ fields: [String: JSONValue]) -> JSONValue { S.object(fields, required: Array(fields.keys)) }
        return ["AgentSkills": complete([
            "skill": complete(["name": S.constant(.string("slate-terminal")), "path": S.string(), "bundledPath": S.string()]),
            "agents": S.array(complete([
                "id": S.strings(skillAgentIDs), "name": S.string(), "detail": S.string(), "path": S.string(),
                "detected": S.boolean, "status": S.strings(["notInstalled", "installed", "conflict"])
            ]), minimum: skillAgentIDs.count, maximum: skillAgentIDs.count)
        ])]
    }()

    public static let skills: [AutomationMethod: AutomationContract] = {
        typealias S = APISchema
        var methods: [AutomationMethod: AutomationContract] = [
            .skillsList: AutomationContract(parameters: [:], result: S.reference("AgentSkills"), guards: unanchoredGuards,
                semantics: ["changesFiles": .bool(false), "order": .string("targetRegistryOrder")])
        ]
        for method in [AutomationMethod.skillsInstall, .skillsUninstall] {
            methods[method] = AutomationContract(parameters: ["agents": S.array(S.strings(skillAgentIDs), minimum: 1)],
                required: ["agents"], result: S.reference("AgentSkills"), guards: unanchoredGuards,
                conditions: [.object(["requires": .string("standardSlateRuntime")])]
                    + (method == .skillsInstall ? [.object(["requires": .string("bundledSkillAvailable")])] : []),
                errors: [APIError.layoutAppManagementUnavailable] + (method == .skillsInstall ? [APIError.unavailable] : []),
                semantics: ["foreignDestinations": .string("conflictNeverReplaceOrRemove"), "atomicAcrossAgents": .bool(false),
                    "failureMayHaveChangedEarlierTargets": .bool(true), "recovery": .string("readSkillsListBeforeAnyRetry"),
                    "installedLinkTarget": .string("appManagedSkillCopy"), "uninstallRemovesManagedCopy": .bool(false)])
        }
        return methods
    }()
}
