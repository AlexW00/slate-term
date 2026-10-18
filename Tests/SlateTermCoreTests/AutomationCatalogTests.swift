import Foundation
import Testing
@testable import SlateTermCore
import SlateTermTestSupport

@Test func completeAutomationCatalogClosesEveryReferenceAndDocumentsItsVocabulary() {
    #expect(Set(AutomationCatalog.methods.keys) == Set(AutomationMethod.publicMethods))
    #expect(Set(AutomationCatalog.commands.keys) == Set(CommandRegistry.commands.map(\.id) + [AutomationCatalog.contributedCommandKey]))
    #expect(AutomationCatalog.methods[.shellUpdate] == nil)
    #expect(AutomationCatalog.methods[.shellRunInput] == nil)
    var references = Set<String>(), extensions = Set<String>(), formats = Set<String>()
    func inspect(_ value: JSONValue) {
        switch value {
        case .array(let values): values.forEach(inspect)
        case .object(let fields):
            if let reference = fields["$ref"]?.string { references.insert(reference) }
            if let format = fields["format"]?.string { formats.insert(format) }
            for (key, child) in fields {
                if key.hasPrefix("x-") { extensions.insert(key) }
                // Literal values and descriptive prose are not nested schemas.
                if !["const", "default", "enum", "semantics"].contains(key) { inspect(child) }
            }
        default: break
        }
    }
    AutomationCatalog.definitions.values.forEach(inspect)
    AutomationCatalog.methods.values.forEach { inspect($0.input); inspect($0.result) }
    AutomationCatalog.commands.values.forEach { inspect($0.input); inspect($0.result) }
    for reference in references {
        #expect(reference.hasPrefix("#/$defs/"))
        #expect(AutomationCatalog.definitions[String(reference.dropFirst(8))] != nil)
    }
    #expect(extensions.isSubset(of: Set(AutomationSchemaVocabulary.extensions.keys)))
    #expect(formats.subtracting(["uuid"]).isSubset(of: Set(AutomationSchemaVocabulary.formats.keys)))
}

@Test func completeDiscoveryProducerPreservesLegacyCommandRowsAndMatchesItsOwnSchema() throws {
    let plugin = try PluginRegistration.parse(Data(#"{"id":"catalog.example","title":"Example","commands":[{"id":"run","title":"Run Example","executable":"/usr/bin/true"}]}"#.utf8))
    let commands = CommandRegistry.commands + plugin.workspaceCommands
    let instanceID = UUID().uuidString
    let description = try AutomationCatalog.describe(instanceID: instanceID, commands: commands)
    #expect(schemaAccepts(AutomationCatalog.methods[.describe]!.result, description, definitions: AutomationCatalog.definitions))
    let rows = description.object!["commands"]!
    #expect(schemaAccepts(AutomationCatalog.methods[.commandList]!.result, rows, definitions: AutomationCatalog.definitions))
    guard case .array(let values) = rows else { preconditionFailure() }
    for (command, value) in zip(commands, values) {
        var fields = value.object!
        let reference = fields.removeValue(forKey: "contractRef")!.string!
        #expect(JSONValue.object(fields) == (try JSONValue.encoding(command)))
        #expect(reference == "#/commands/" + (PluginCommand.isNamespacedID(command.id) ? AutomationCatalog.contributedCommandKey : command.id))
        let decoded = try JSONDecoder().decode(WorkspaceCommand.self, from: JSONEncoder().encode(value))
        #expect(decoded.id == command.id) // Additive fields remain compatible with existing consumers.
    }
    for (name, value) in AutomationCapabilities.fields { #expect(description.object?[name] == value) }
    let bytes = try JSONEncoder().encode(description).count
    print("Complete automation discovery: \(AutomationCatalog.methods.count) methods, \(CommandRegistry.commands.count) built-ins, \(AutomationCatalog.definitions.count) definitions, \(bytes) encoded bytes with one contribution")
    // Leave room for the RPC wrapper and ordinary plugin contributions. Discovery
    // remains unpaginated; a sufficiently large active catalog can hit transport limits.
    #expect(bytes < 900_000)
    if let path = ProcessInfo.processInfo.environment["SLATE_TEST_AUTOMATION_CATALOG_EXPORT"] {
        // Explicit opt-in for independent host validation, never a normal test side effect.
        try JSONEncoder().encode(description).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

@Test func commandRunDiscoverySelectsBuiltinOrContributedValidationWithoutRelaxingGuards() {
    let schema = AutomationCatalog.methods[.commandRun]!.input
    let samples: [(JSONValue, Bool)] = [
        (.object(["id": .string("pane.focus")]), true),
        (.object(["id": .string("pane.split"), "direction": .string("right")]), false),
        (.object(["id": .string("pane.split"), "direction": .string("right"), "expectedLayoutRevision": .string("revision")]), true),
        (.object(["id": .string("appearance.light"), "expectedSourceRevision": .string("source")]), true),
        (.object(["id": .string("terminal.find"), "expectedSourceRevision": .string("source")]), false),
        (.object(["id": .string("plugin.notes.run"), "expectedUserSelection": .null]), true),
        (.object(["id": .string("plugin.notes.run"), "expectedSourceRevision": .string("source")]), false),
        (.object(["id": .string("pane.focus"), "expectedUserSelection": .null]), false),
        (.object(["id": .string("unregistered.builtin")]), false),
        (.object(["id": .string("window.focus"), "windowId": .string("native"), "pane": .string("p1")]), false)
    ]
    for (value, accepted) in samples {
        #expect(schemaAccepts(schema, value, definitions: AutomationCatalog.definitions) == accepted)
    }
    for method in [AutomationMethod.describe, .commandList] {
        #expect(schemaAccepts(AutomationCatalog.methods[method]!.input, .object(["ignoredLegacyParameter": .null])))
        #expect(!schemaAccepts(AutomationCatalog.methods[method]!.input, .object(["expectedFutureGuard": .string("invalid")])))
    }
}

@Test func discoveryNumbersSurviveJavaScriptWithoutWeakeningHostIndexLimits() throws {
    func inspect(_ value: JSONValue) {
        switch value {
        case .integer(let integer): #expect((-9_007_199_254_740_991...9_007_199_254_740_991).contains(integer))
        case .number(let number): #expect(number.isFinite && abs(number) <= 9_007_199_254_740_991)
        case .array(let values): values.forEach(inspect)
        case .object(let fields): fields.values.forEach(inspect)
        default: break
        }
    }
    inspect(AutomationCatalog.document)
    for id in ["tab.reorder", "tab.move"] {
        let input = try #require(AutomationCatalog.commands[id]?.input.object)
        let index = try #require(input["properties"]?.object?["index"])
        #expect(schemaAccepts(index, .integer(0)))
        #expect(schemaAccepts(index, .integer(Int.max)))
        #expect(!schemaAccepts(index, .integer(-1)))
        #expect(!schemaAccepts(index, .number(Double(Int.max)))) // Rounded up to 2^63, outside Int64.
        #expect(!schemaAccepts(index, .number(0.5)))
    }
}

@Test func identitySchemasRejectCanonicalLookingSignedIntegerOverflow() {
    for number in ["1", String(Int.max), "9223372036854775808", "18446744073709551615", "01", "0", "-1", "1\n"] {
        #expect(schemaAccepts(APISchema.paneID, .string("p" + number)) == ((try? PaneID(parsing: "p" + number)) != nil))
        #expect(schemaAccepts(APISchema.tabID, .string("t" + number)) == ((try? TabID(parsing: "t" + number)) != nil))
        #expect(schemaAccepts(APISchema.groupID, .string("w" + number)) == ((try? GroupID(parsing: "w" + number)) != nil))
    }
}
