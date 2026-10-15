import Foundation
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    /// Observe external source changes under their own native operation, including reads
    /// that notice a change before the watcher. The source cache is also the revision ledger.
    func observeConfigurationSource(_ source: String) throws {
        guard let previous = configurationRevisionSource else {
            configurationRevisionSource = source
            return
        }
        guard previous != source else { return }
        let next = UUID().uuidString
        let operation = WorkspaceOperationContext(origin: .native)
        let parsed = try? AppConfiguration.parse(source)
        let fields: [String: JSONValue] = [
            "operationId": .string(operation.lineage.operationID.uuidString),
            "beforeSourceRevision": .string(configurationSourceRevision), "sourceRevision": .string(next),
            "beforeAppliedRevision": .string(appliedConfigurationRevision), "appliedRevision": .string(appliedConfigurationRevision),
            "sourceValid": .bool(parsed != nil), "appliedMatchesSource": .bool(parsed?.changedKeys(from: settings.current).isEmpty == true)
        ]
        try events.commitWorkspace([EventPublication(topic: "host.settings.source.changed", payload: .object(fields),
                                                     source: .host, lineage: operation.lineage)]) {
            configurationRevisionSource = source
            configurationSourceRevision = next
        }
    }

    /// Filesystem and runtime effects are not rollbackable model transactions. Preflight
    /// all bounded possible facts, perform the existing synchronous effects, then publish
    /// only observed outcomes against the current journal (callbacks may publish meanwhile).
    func performSettingsOperation(operation: WorkspaceOperationContext, candidate: AppConfiguration?,
                                  intendedSource: String? = nil, body: () throws -> JSONValue) throws -> JSONValue {
        try operation.validateCaller()
        // A reload must still run its normal error/status path when the source is
        // unreadable. Do not suppress publication errors for readable observations.
        let source = try? configurationSource()
        if let source { try observeConfigurationSource(source) }
        let before = (source: source, revision: configurationSourceRevision)
        let previous = settings.current
        let beforeApplied = appliedConfigurationRevision
        let nextSource = UUID().uuidString, nextApplied = UUID().uuidString
        let recipients = pluginSettingsRecipients.map { (plugin: $0.plugin, instance: Optional($0.id), service: Optional<ServiceEventRecipient>.none) }
            + serviceSettingsRecipients.map { (plugin: $0.plugin, instance: Optional<String>.none, service: Optional($0.target)) }

        func publications(after: AppConfiguration, sourceRevision: String?, appliedRevision: String,
                          source: String?, failed: Bool, allOutcomes: Bool = false) throws -> [EventPublication] {
            var fields: [String: JSONValue] = [
                "operationId": .string(operation.lineage.operationID.uuidString),
                "beforeSourceRevision": .string(before.revision), "sourceRevision": sourceRevision.map(JSONValue.string) ?? .null,
                "beforeAppliedRevision": .string(beforeApplied), "appliedRevision": .string(appliedRevision)
            ]
            let parsed = source.flatMap { try? AppConfiguration.parse($0) }
            fields["sourceValid"] = .bool(parsed != nil)
            fields["appliedMatchesSource"] = .bool(parsed?.changedKeys(from: after).isEmpty == true)
            var records: [EventPublication] = []
            func add(_ topic: String, _ payload: [String: JSONValue], recipient: String? = nil, service: ServiceEventRecipient? = nil) {
                // Deliberately not operation.publication: no private caller, parent, intent,
                // pane/tab, namespace or path metadata on a global settings envelope.
                records.append(EventPublication(topic: topic, payload: .object(payload), source: .host,
                                                targetInstanceId: recipient, targetService: service, lineage: operation.lineage))
            }
            if (sourceRevision != nil && sourceRevision != before.revision) || allOutcomes { add("host.settings.source.changed", fields) }
            if !after.changedKeys(from: previous).isEmpty || allOutcomes { add("host.settings.changed", fields) }
            for recipient in recipients where allOutcomes || previous.plugins[recipient.plugin] != after.plugins[recipient.plugin] {
                var detail = fields
                detail["pluginId"] = .string(recipient.plugin)
                let old = previous.plugins[recipient.plugin] ?? [:], new = after.plugins[recipient.plugin] ?? [:]
                let keys = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
                var paths: [JSONValue] = [], bytes = 0
                for key in keys {
                    let path = JSONValue.array([.string(key)])
                    let count = try JSONEncoder().encode(path).count
                    guard paths.count < 32, bytes + count <= 4096 else { break }
                    paths.append(path); bytes += count
                }
                // External writers may replace the file between preview and reload.
                // Reserve every live recipient's maximum bounded projection, not only
                // the namespaces changed in the candidate we happened to read.
                detail["changedPaths"] = allOutcomes ? .array([.array([.string(String(repeating: "x", count: 4096))])]) : .array(paths)
                detail["changeCount"] = .integer(allOutcomes ? Int.max : keys.count)
                detail["truncated"] = .bool(allOutcomes || paths.count < keys.count)
                add("host.plugin.settings.changed", detail, recipient: recipient.instance, service: recipient.service)
            }
            if failed || allOutcomes {
                fields["outcome"] = .string("unknown")
                fields["persisted"] = intendedSource.flatMap { intended in source.map { .bool($0 == intended) } } ?? .null
                add("host.settings.failed", fields)
            }
            return records
        }

        try events.preflight(publications(after: candidate ?? previous, sourceRevision: nextSource, appliedRevision: nextApplied,
                                          source: intendedSource ?? before.source, failed: true, allOutcomes: true))
        let outcome: Result<JSONValue, Error>
        do { outcome = .success(try body()) }
        catch { outcome = .failure(error) }
        let actualSource = try? configurationSource()
        let sourceRevision = actualSource.map { $0 == before.source ? before.revision : nextSource }
        let appliedRevision = settings.current.changedKeys(from: previous).isEmpty ? beforeApplied : nextApplied
        let failed: Bool
        if case .failure = outcome { failed = true } else { failed = false }
        let records = try publications(after: settings.current, sourceRevision: sourceRevision, appliedRevision: appliedRevision,
                                       source: actualSource, failed: failed)
        try events.commitWorkspace(records) {
            if let actualSource, let sourceRevision { configurationRevisionSource = actualSource; configurationSourceRevision = sourceRevision }
            appliedConfigurationRevision = appliedRevision
        }
        switch outcome {
        case .success(let value):
            var result = value.object ?? [:]
            result["operationId"] = .string(operation.lineage.operationID.uuidString)
            return .object(result)
        case .failure(let error):
            let failure = error as? RPCFailure
            let state = records.last(where: { $0.topic == "host.settings.failed" })?.payload
            throw RPCFailure(code: failure?.code ?? -32602, message: failure?.message ?? String(describing: error), data: state)
        }
    }
}
