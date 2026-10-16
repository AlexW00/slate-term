import ArgumentParser
import Foundation
import SlateTermCore

/// Presentation only: Settings and this wizard use the same host-owned install operation.
enum SkillSetup {
    private struct Listing: Decodable {
        struct Agent: Decodable {
            let id: String
            let name: String
            let detail: String
            let path: String
            let detected: Bool
            let status: String

            var statusLabel: String {
                switch status {
                case "installed": "installed"
                case "notInstalled": detected ? "not installed" : "not installed (not detected)"
                default: "conflict; existing item will not be replaced"
                }
            }
        }
        let agents: [Agent]
    }

    static func run(columns: Int = 80, request: (String, [String: JSONValue]) throws -> JSONValue,
                    readInput: () -> String?, write: (String) -> Void) throws {
        let value = try request("skills.list", [:])
        let listing = try JSONDecoder().decode(Listing.self, from: JSONEncoder().encode(value))
        guard !listing.agents.isEmpty else { throw ValidationError("No agent skill destinations are available") }
        func line(_ text: String, indent: String = "") {
            var current = indent
            for word in text.split(whereSeparator: \.isWhitespace) {
                let separator = current == indent ? "" : " "
                if current != indent, current.count + separator.count + word.count > max(20, columns - 1) {
                    write(current + "\n")
                    current = indent
                }
                current += (current == indent ? "" : " ") + word
            }
            write(current + "\n")
        }
        write("\nSet up the Slate Terminal skill\n\n")
        line("Choose where your coding agent reads skills. The shared folder works with most agents; Claude Code uses its own folder.")
        line("Installing in both the shared folder and an agent's own folder can show the skill twice.")
        write("\n")
        for (index, agent) in listing.agents.enumerated() {
            line("\(index + 1). \(agent.name) [\(agent.id)] — \(agent.statusLabel)", indent: "  ")
            if agent.id == "agents" { line(agent.detail, indent: "     ") }
        }
        while true {
            write("\n")
            line("Choose numbers or agent IDs, separated by spaces or commas.")
            write("Selection (Enter to cancel): ")
            guard let input = readInput(), !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !["q", "quit"].contains(input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                write("Cancelled. No skills were changed.\n")
                return
            }
            let tokens = input.split { $0.isWhitespace || $0 == "," }.map(String.init)
            var selected: [Listing.Agent] = []
            var valid = !tokens.isEmpty
            for token in tokens {
                let agent: Listing.Agent?
                if let number = Int(token), (1...listing.agents.count).contains(number) {
                    agent = listing.agents[number - 1]
                } else { agent = listing.agents.first { $0.id == token } }
                guard let agent, ["installed", "notInstalled"].contains(agent.status) else {
                    line("Cannot select '\(token)'. Choose a listed destination without a conflict.")
                    valid = false
                    break
                }
                if !selected.contains(where: { $0.id == agent.id }) { selected.append(agent) }
            }
            guard valid else { continue }
            write("\nInstall or update the skill in:\n")
            for agent in selected {
                line(agent.name + ":", indent: "  ")
                for pathLine in pathLines(agent.path, columns: columns) { write(pathLine + "\n") }
            }
            write("Install? [y/N]: ")
            guard let answer = readInput()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  ["y", "yes"].contains(answer) else {
                write("Cancelled. No skills were changed.\n")
                return
            }
            _ = try request("skills.install", ["agents": .array(selected.map { .string($0.id) })])
            write("\n")
            line("Skill installed for \(selected.map(\.name).joined(separator: ", ")).")
            line("Start a new agent session to use it.")
            return
        }
    }

    private static func pathLines(_ path: String, columns: Int) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path + "/"
        let display = path.hasPrefix(home) ? "~/" + path.dropFirst(home.count) : path
        let indent = "    "
        var lines: [String] = []
        var current = indent
        for (index, component) in display.split(separator: "/", omittingEmptySubsequences: false).enumerated() {
            let segment = (index == 0 ? "" : "/") + component
            if current != indent, current.count + segment.count > max(20, columns - 1) {
                lines.append(current)
                current = indent
            }
            current += segment
        }
        lines.append(current)
        return lines
    }
}
