import Foundation
import SlateTermCore

public typealias SchemaFormatChecks = [String: @Sendable (String) -> Bool]

/// Test-only evaluator for the emitted subset, not a production JSON Schema validator.
public func schemaAccepts(_ schema: JSONValue, _ value: JSONValue, definitions: [String: JSONValue] = [:], formats: SchemaFormatChecks = [:]) -> Bool {
    SchemaEvaluator(definitions: definitions, formats: formats).accepts(schema, value)
}

// Keep recursive frames small: a TOML value can legitimately be 32 levels deep,
// with reference/combinator frames at every level on a test worker's small stack.
private struct SchemaEvaluator {
    let definitions: [String: JSONValue]
    let formats: SchemaFormatChecks

    func accepts(_ schema: JSONValue, _ value: JSONValue) -> Bool {
        if case .bool(let accepted) = schema { return accepted }
        guard let rules = schema.object else { return false }
        if let type = rules["type"]?.string, !matchesType(type, value) { return false }
        if !matchesBounds(rules, value) { return false }
        if let reference = rules["$ref"]?.string {
            guard reference.hasPrefix("#/$defs/"), let target = definitions[String(reference.dropFirst(8))], accepts(target, value) else { return false }
        }
        if let constant = rules["const"], value != constant { return false }
        if case .array(let options) = rules["enum"], !options.contains(value) { return false }
        if !matchesCombinations(rules, value) { return false }
        switch value {
        case .string(let text): return matchesString(rules, text)
        case .array(let values): return matchesArray(rules, values)
        case .object(let fields): return matchesObject(rules, fields)
        default: return true
        }
    }

    private func matchesType(_ type: String, _ value: JSONValue) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("object", .object), ("array", .array), ("integer", .integer), ("number", .integer), ("number", .number): return true
        case ("integer", .number(let n)): return n.isFinite && n.rounded() == n
        default: return false
        }
    }

    private func matchesCombinations(_ rules: [String: JSONValue], _ value: JSONValue) -> Bool {
        for keyword in ["allOf", "anyOf", "oneOf"] {
            if case .array(let options) = rules[keyword] {
                var count = 0
                for option in options where accepts(option, value) { count += 1 }
                if keyword == "allOf" && count != options.count { return false }
                if keyword == "anyOf" && count == 0 { return false }
                if keyword == "oneOf" && count != 1 { return false }
            }
        }
        if let excluded = rules["not"], accepts(excluded, value) { return false }
        if let condition = rules["if"] {
            let branch = accepts(condition, value) ? rules["then"] : rules["else"]
            if let branch, !accepts(branch, value) { return false }
        }
        return true
    }

    private func matchesBounds(_ rules: [String: JSONValue], _ value: JSONValue) -> Bool {
        if rules["x-signed64BitInteger"] == .bool(true) {
            switch value {
            case .integer: break
            case .number(let number): if Int64(exactly: number) == nil { return false }
            default: return false
            }
        }
        if case .integer(let maximum) = rules["x-maxEncodedJSONBytes"],
           (try? JSONEncoder().encode(value).count).map({ $0 <= maximum }) != true { return false }
        if case .integer(let maximum) = rules["x-maxValueDepth"], !withinDepth(value, startingAt: 0, maximum: maximum) { return false }
        if let number = numeric(value) {
            if let minimum = numeric(rules["minimum"]), number < minimum { return false }
            if let maximum = numeric(rules["maximum"]), number > maximum { return false }
            if let minimum = numeric(rules["exclusiveMinimum"]), number <= minimum { return false }
            if let maximum = numeric(rules["exclusiveMaximum"]), number >= maximum { return false }
        }
        return true
    }

    private func matchesString(_ rules: [String: JSONValue], _ text: String) -> Bool {
        if let minimum = numeric(rules["minLength"]), Double(text.unicodeScalars.count) < minimum { return false }
        if let maximum = numeric(rules["maxLength"]), Double(text.unicodeScalars.count) > maximum { return false }
        if let maximum = numeric(rules["x-maxUTF16CodeUnits"]), Double(text.utf16.count) > maximum { return false }
        if let maximum = numeric(rules["x-maxUTF8Bytes"]), Double(text.utf8.count) > maximum { return false }
        if let maximum = numeric(rules["x-maxGraphemeCount"]), Double(text.count) > maximum { return false }
        if let pattern = rules["pattern"]?.string, text.range(of: pattern, options: .regularExpression) == nil { return false }
        if rules["format"] == .string("uuid"), UUID(uuidString: text) == nil { return false }
        if rules["format"] == .string("slate-pane-id"), (try? PaneID(parsing: text)) == nil { return false }
        if rules["format"] == .string("slate-tab-id"), (try? TabID(parsing: text)) == nil { return false }
        if rules["format"] == .string("slate-group-id"), (try? GroupID(parsing: text)) == nil { return false }
        if rules["format"] == .string("slate-event-cursor") {
            do { _ = try EventJournal().batch(after: text) }
            catch EventJournalError.invalidCursor { return false }
            catch is EventJournalError { /* Well-formed cursors can belong to another epoch. */ }
            catch { return false }
        }
        if let format = rules["format"]?.string, let check = formats[format], !check(text) { return false }
        if rules["x-noControls"] == .bool(true), text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) { return false }
        if rules["x-noWhitespaceOrControls"] == .bool(true), text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }) { return false }
        if rules["x-nonemptyAfterNotificationSanitization"] == .bool(true), NotificationStore.text(text, title: true).isEmpty { return false }
        if rules["x-nonemptyAfterTrimmingWhitespaceAndNewlines"] == .bool(true), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if rules["x-trimmed"] == .bool(true), text.trimmingCharacters(in: .whitespacesAndNewlines) != text { return false }
        if rules["format"] == .string("slate-manual-pane-title"), text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > 4096 { return false }
        if rules["format"] == .string("slate-manual-tab-title") {
            do { _ = try TabTitle.normalized(text) } catch { return false }
        }
        if rules["format"] == .string("slate-browser-url"), (try? BrowserURL.parse(text)) == nil { return false }
        if rules["format"] == .string("slate-browser-navigation-url"), (try? BrowserURL.parse(text, assumingHTTPS: true)) == nil { return false }
        if rules["format"] == .string("slate-browser-data-site-url"), (try? BrowserDataRequest.siteHost(text)) == nil { return false }
        if rules["format"] == .string("slate-package-relative-path"), (try? PluginManifest.relativePath(text)) == nil { return false }
        if rules["format"] == .string("slate-package-root-relative-path"), (try? PluginManifest.relativePath(text, allowRoot: true)) == nil { return false }
        if rules["format"] == .string("slate-package-argument"), text != "{pluginRoot}" {
            if text.hasPrefix("{pluginRoot}/") {
                if (try? PluginManifest.relativePath(String(text.dropFirst(13)))) == nil { return false }
            } else if text.contains("{pluginRoot}") { return false }
        }
        if rules["format"] == .string("slate-presence-note"), (try? PresenceActor(name: "test", note: text)) == nil { return false }
        if rules["format"] == .string("slate-web-key"), (try? BrowserAction(kind: "key", params: ["ref": .string("target"), "key": .string(text)])) == nil { return false }
        if rules["format"] == .string("slate-web-element-ref"), (try? WebAction(kind: "click", params: ["ref": .string(text)])) == nil { return false }
        if rules["format"] == .string("slate-layout-launcher-path"), URL(fileURLWithPath: text).pathExtension != "app" { return false }
        if rules["format"] == .string("slate-plugin-relative-entry"),
           text.isEmpty || text.hasPrefix("/") || text.contains("\0") || text.split(separator: "/").contains("..") { return false }
        if rules["format"] == .string("slate-plugin-url") {
            guard let url = URL(string: text), let origin = try? PluginOrigin(url: url),
                  origin.scheme == "https" || origin.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(origin.host) else { return false }
        }
        return true
    }

    private func matchesArray(_ rules: [String: JSONValue], _ values: [JSONValue]) -> Bool {
        if let minimum = numeric(rules["minItems"]), Double(values.count) < minimum { return false }
        if let maximum = numeric(rules["maxItems"]), Double(values.count) > maximum { return false }
        if let item = rules["items"] {
            for value in values where !accepts(item, value) { return false }
        }
        if rules["uniqueItems"] == .bool(true) {
            for (index, value) in values.enumerated() where values[..<index].contains(value) { return false }
        }
        if let property = rules["x-uniqueProperty"]?.string {
            var seen: [JSONValue] = []
            for value in values {
                guard let key = value.object?[property], !seen.contains(key) else { return false }
                seen.append(key)
            }
        }
        if rules["x-disjointLiteralPaths"] == .bool(true) {
            var paths: [[String]] = []
            for value in values {
                guard case .array(let components) = value.object?["path"] else { return false }
                let path = components.compactMap(\.string)
                guard path.count == components.count,
                      !paths.contains(where: { path.starts(with: $0) || $0.starts(with: path) }) else { return false }
                paths.append(path)
            }
        }
        if case .integer(let maximum) = rules["x-maxSetValueDepthIncludingPath"] {
            for operation in values where operation.object?["op"] == .string("set") {
                guard case .array(let path) = operation.object?["path"], let value = operation.object?["value"],
                      withinDepth(value, startingAt: path.count - 1, maximum: maximum) else { return false }
            }
        }
        return true
    }

    private func matchesObject(_ rules: [String: JSONValue], _ fields: [String: JSONValue]) -> Bool {
        if let maximum = numeric(rules["maxProperties"]), Double(fields.count) > maximum { return false }
        if case .array(let required) = rules["required"] {
            for key in required { guard let key = key.string, fields[key] != nil else { return false } }
        }
        let properties = rules["properties"]?.object ?? [:]
        let patterns = rules["patternProperties"]?.object ?? [:]
        for (key, field) in fields {
            if let names = rules["propertyNames"], !accepts(names, .string(key)) { return false }
            var matched = false
            if let schema = properties[key] {
                matched = true
                if !accepts(schema, field) { return false }
            }
            for (pattern, schema) in patterns where key.range(of: pattern, options: .regularExpression) != nil {
                matched = true
                if !accepts(schema, field) { return false }
            }
            if !matched, !accepts(rules["additionalProperties"] ?? .bool(true), field) { return false }
        }
        return matchesObjectRelationships(rules, fields)
    }

    private func matchesObjectRelationships(_ rules: [String: JSONValue], _ fields: [String: JSONValue]) -> Bool {
        if rules["x-packageManifestResolution"] == .bool(true) {
            guard let data = try? JSONEncoder().encode(JSONValue.object(fields)), (try? PluginManifest(data: data)) != nil else { return false }
        }
        if rules["x-refIdentityMatchesExpected"] == .bool(true), let ref = fields["ref"]?.string, let view = fields["expectedViewId"]?.string {
            let parts = ref.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, String(parts[0]) == view, .string(String(parts[1])) == fields["expectedDocumentId"] else { return false }
        }
        if let topology = rules["x-savedLayoutTopology"]?.object, !matchesSavedLayoutTopology(topology, fields) { return false }
        if case .integer(let maximum) = rules["x-maxNormalizedSavedLayoutBytes"] {
            guard let bytes = try? JSONEncoder().encode(JSONValue.object(fields)),
                  let normalized = try? JSONDecoder().decode(SavedLayoutDefinition.self, from: bytes),
                  let size = try? JSONEncoder().encode(normalized).count, size <= maximum else { return false }
        }
        if case .array(let pair) = rules["x-orderedIntegerFields"], pair.count == 2 {
            let properties = rules["properties"]?.object ?? [:]
            guard let lower = pair[0].string, let upper = pair[1].string,
                  let low = numeric(fields[lower] ?? properties[lower]?.object?["default"]),
                  let high = numeric(fields[upper] ?? properties[upper]?.object?["default"]), low <= high else { return false }
        }
        if rules["x-layoutFieldValueRules"] == .bool(true) {
            guard let data = try? JSONEncoder().encode(JSONValue.object(fields)),
                  (try? JSONDecoder().decode(SavedLayoutField.self, from: data)) != nil else { return false }
        }
        let source = fields["source"]?.object
        let process = fields["process"] != nil && fields["process"] != .null
        if rules["x-pluginContributions"] == .bool(true) {
            func array(_ name: String) -> [JSONValue] { if case .array(let values) = fields[name] { values } else { [] } }
            let commands = array("commands")
            let service = fields["service"] != nil && fields["service"] != .null
            if source == nil && (commands.isEmpty && !service || process || !array("layoutFields").isEmpty) { return false }
            for button in array("headerButtons") {
                guard let command = button.object?["command"], commands.contains(where: { $0.object?["id"] == command }) else { return false }
            }
        }
        if rules["x-pluginSourceProcessRelationship"] == .bool(true), let source {
            if source["kind"] == .string("directory"), process { return false }
            if source["kind"] == .string("url") {
                guard let text = source["url"]?.string, let url = URL(string: text), let origin = try? PluginOrigin(url: url),
                      origin.port > 0 || process,
                      !process || origin.scheme == "http" && origin.host == "127.0.0.1" else { return false }
            }
        }
        return true
    }

    private func matchesSavedLayoutTopology(_ rules: [String: JSONValue], _ fields: [String: JSONValue]) -> Bool {
        guard case .array(let tabs) = fields["tabs"], case .integer(let maximumDepth) = rules["maximumTreeDepth"] else { return false }
        var allIDs = Set<String>()
        for tab in tabs {
            guard let fields = tab.object, case .array(let panes) = fields["panes"], let layout = fields["layout"] else { return false }
            let recipes = panes.compactMap { $0.object?["id"]?.string }
            if rules["globallyUniquePaneIDs"] == .bool(true) {
                for id in recipes where !allIDs.insert(id).inserted { return false }
            }
            var pending = [(layout, 0)]
            var leaves: [String] = []
            while let (node, depth) = pending.popLast() {
                guard depth <= maximumDepth, let tree = node.object else { return false }
                if tree["kind"] == .string("pane"), let id = tree["pane"]?.string { leaves.append(id) }
                else if tree["kind"] == .string("split"), let first = tree["first"], let second = tree["second"] {
                    pending.append((first, depth + 1)); pending.append((second, depth + 1))
                } else { return false }
            }
            if rules["exactRecipeLeafMatch"] == .bool(true),
               leaves.count != recipes.count || Set(leaves).count != leaves.count || Set(leaves) != Set(recipes) { return false }
        }
        return true
    }

    private func withinDepth(_ value: JSONValue, startingAt depth: Int, maximum: Int) -> Bool {
        var pending = [(value, depth)]
        while let (value, depth) = pending.popLast() {
            if depth > maximum { return false }
            switch value {
            case .array(let values): for value in values { pending.append((value, depth + 1)) }
            case .object(let fields): for value in fields.values { pending.append((value, depth + 1)) }
            default: break
            }
        }
        return true
    }

    private func numeric(_ value: JSONValue?) -> Double? {
        switch value { case .integer(let n): Double(n); case .number(let n): n; default: nil }
    }
}
