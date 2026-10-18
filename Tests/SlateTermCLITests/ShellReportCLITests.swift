import Testing
@testable import SlateTermCLI

@Test func shellReportsPreserveEmptyAndLeadingDashCommandText() throws {
    let empty = try ShellCommand.parse(["update", "--command", ""])
    #expect(empty.command == "")
    for text in ["-leading-dash", "echo 日本語"] {
        let report = try ShellCommand.parse(["update", "--command=\(text)"])
        #expect(report.command == text)
    }
}
