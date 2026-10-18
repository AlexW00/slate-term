import Foundation
import Testing
@testable import SlateTermCore
import SlateTermTestSupport

/// Host-side audit of responses collected by owned VM fixtures. No native app is
/// launched here. Opt in with a retrieved run's gates/ directory, never host UI.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SLATE_TEST_CONTRACT_OBSERVATIONS"] != nil))
func capturedNativeResponsesConformToTheCurrentSharedCatalog() throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SLATE_TEST_CONTRACT_OBSERVATIONS"]))
    let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        .compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix("-contracts.jsonl") }.sorted { $0.path < $1.path }
    #expect(!files.isEmpty, "No native evidence under the supplied directory")
    let normalizedCatalog = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(AutomationCatalog.document))
    var responses = 0, methods = Set<String>(), commands = Set<String>(), clients = Set<String>()
    for file in files {
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        let firstLine = try #require(lines.first)
        let descriptionRecord = try JSONDecoder().decode(JSONValue.self, from: Data(firstLine.utf8))
        let description = try #require(descriptionRecord.object?["value"])
        let catalog = try #require(description.object?["contracts"]?.object)
        #expect(JSONValue.object(catalog) == normalizedCatalog, "Native catalog differs from current source: \(file.path)")
        let definitions = try #require(catalog["$defs"]?.object)
        let methodContracts = try #require(catalog["methods"]?.object)
        let commandContracts = try #require(catalog["commands"]?.object)
        let descriptionSchema = try #require(methodContracts["api.describe"]?.object?["result"])
        #expect(schemaAccepts(descriptionSchema, description, definitions: definitions),
                "Native discovery does not match its result schema: \(file.path)")
        for (index, line) in lines.dropFirst().enumerated() {
            let record = try #require(JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)).object)
            let method = try #require(record["method"]?.string)
            var contract = try #require(methodContracts[method]?.object)
            if let command = record["command"]?.string {
                commands.insert(command)
                if let selected = commandContracts[command]?.object { contract = selected }
                else if PluginCommand.isNamespacedID(command) { contract = try #require(commandContracts["plugin.*"]?.object) }
            }
            let label = "\(file.lastPathComponent):\(index + 2) \(record["client"]?.string ?? "unknown") \(method) \(record["command"]?.string ?? "")"
            if let code = record["errorCode"] {
                guard case .array(let errors) = contract["errors"] else { throw ObservationError.missingErrorContract }
                #expect(errors.contains(code), "Undocumented native error \(code): \(label)")
            } else {
                let result = try #require(record["result"])
                if method == "api.describe" {
                    #expect(result.object?["contracts"] == normalizedCatalog, "Client catalog differs from current source: \(label)")
                }
                let resultSchema = try #require(contract["result"])
                #expect(schemaAccepts(resultSchema, result, definitions: definitions), "Native result schema mismatch: \(label)")
            }
            responses += 1
            methods.insert(method)
            clients.insert(try #require(record["client"]?.string))
        }
    }
    #expect(responses > 0)
    print("Native contract evidence: \(files.count) files, \(responses) responses, \(methods.count) methods, \(commands.count) command IDs, clients \(clients.sorted())")
    print("Observed methods: \(methods.sorted().joined(separator: ", "))")
    print("Observed commands: \(commands.sorted().joined(separator: ", "))")
}

private enum ObservationError: Error { case missingErrorContract }
