import Testing
@testable import SlateTermCore

private let commands = [
    CommandSearchItem(id: "tab.new", title: "New Tab", detail: "Workspace", keywords: "create"),
    CommandSearchItem(id: "split.left", title: "Split Left", detail: "Layout", keywords: "pane panel"),
    CommandSearchItem(id: "plugin.notes.open", title: "Open Résumé", detail: "Notes · Plugin"),
    CommandSearchItem(id: "pane.close", title: "Close Pane", detail: "Workspace", keywords: "remove panel"),
]

@Test func commandSearchIsStableAndFindsTitlesMetadataAndAbbreviations() {
    #expect(CommandSearch.results(commands, query: "  ") == commands)
    #expect(CommandSearch.results(commands, query: "splt").map(\.id) == ["split.left"])
    #expect(CommandSearch.results(commands, query: "LEFT panel").map(\.id) == ["split.left"])
    #expect(CommandSearch.results(commands, query: "resume").map(\.id) == ["plugin.notes.open"])
    #expect(CommandSearch.results(commands, query: "notes open").map(\.id) == ["plugin.notes.open"])
    #expect(CommandSearch.results(commands, query: "tab.new").map(\.id) == ["tab.new"])
    #expect(CommandSearch.results(commands, query: "panel").map(\.id) == ["split.left", "pane.close"])
    #expect(CommandSearch.results(commands, query: "create").map(\.id) == ["tab.new"])
    #expect(CommandSearch.results(commands, query: "does not exist").isEmpty)
}

@Test func commandSearchRanksTitleMatchesAheadOfMetadata() {
    let values = [CommandSearchItem(id: "other", title: "Other", detail: "split"),
                  CommandSearchItem(id: "split", title: "Split Right", detail: "Layout")]
    #expect(CommandSearch.results(values, query: "split").map(\.id) == ["split", "other"])
    #expect(CommandSearch.results([], query: "anything").isEmpty)
}
