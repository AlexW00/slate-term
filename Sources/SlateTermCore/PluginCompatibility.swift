import Foundation

/// Compatibility is a declaration about host contracts, not a permission grant.
/// An API version is a breaking-contract generation; additive features are named
/// by their authoritative method/command IDs rather than a second feature list.
public struct PluginCompatibility: Equatable, Codable, Sendable {
    public static let currentAPIVersion = 1
    public static let currentManifestVersion = 1
    public static let publicMethods = Set(AutomationMethod.publicMethods.map(\.rawValue))
    public static let builtInCommands = Set(CommandRegistry.commands.map(\.id))

    public let minimumAPIVersion: Int
    public let maximumAPIVersion: Int
    public let requiredMethods: [String]
    public let requiredCommands: [String]

    public static let baseline = Self(minimumAPIVersion: 1, maximumAPIVersion: 1,
                                     requiredMethods: [], requiredCommands: [])
    private init(minimumAPIVersion: Int, maximumAPIVersion: Int, requiredMethods: [String], requiredCommands: [String]) {
        self.minimumAPIVersion = minimumAPIVersion
        self.maximumAPIVersion = maximumAPIVersion
        self.requiredMethods = requiredMethods
        self.requiredCommands = requiredCommands
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case minimumAPIVersion, maximumAPIVersion, requiredMethods, requiredCommands }
    public init(from decoder: any Decoder) throws {
        try requirePluginKeys(decoder, allowed: ["minimumAPIVersion", "maximumAPIVersion", "requiredMethods", "requiredCommands"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        minimumAPIVersion = try values.decodeIfPresent(Int.self, forKey: .minimumAPIVersion) ?? 1
        maximumAPIVersion = try values.decodeIfPresent(Int.self, forKey: .maximumAPIVersion) ?? 1
        requiredMethods = try values.decodeIfPresent([String].self, forKey: .requiredMethods) ?? []
        requiredCommands = try values.decodeIfPresent([String].self, forKey: .requiredCommands) ?? []
        guard (1...65_535).contains(minimumAPIVersion), (minimumAPIVersion...65_535).contains(maximumAPIVersion),
              Self.validIDs(requiredMethods), Self.validIDs(requiredCommands) else {
            throw RPCFailure(code: -32602, message: "Invalid plugin compatibility range or required method/command IDs")
        }
        // Null is not an opt-out from declaring a requirement.
        for key in CodingKeys.allCases {
            if values.contains(key), try values.decodeNil(forKey: key) {
                throw RPCFailure(code: -32602, message: "Plugin compatibility fields must not be null")
            }
        }
    }
    private static func validIDs(_ values: [String]) -> Bool {
        values.count <= 256 && Set(values).count == values.count && values.allSatisfy { value in
            !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 || $0 == 95
            }
        }
    }
}

public struct PluginCompatibilityReport: Equatable, Encodable, Sendable {
    public let compatible: Bool
    public let hostAPIVersion: Int
    public let hostManifestVersion: Int
    public let reasons: [String]
}

extension PluginRegistration {
    public func compatibilityReport(apiVersion: Int = PluginCompatibility.currentAPIVersion,
                                    methods: Set<String> = PluginCompatibility.publicMethods,
                                    commands: Set<String> = PluginCompatibility.builtInCommands) -> PluginCompatibilityReport {
        var reasons: [String] = []
        if manifestVersion != PluginCompatibility.currentManifestVersion {
            reasons.append("Manifest version \(manifestVersion) is unsupported (host supports \(PluginCompatibility.currentManifestVersion))")
        }
        if !(compatibility.minimumAPIVersion...compatibility.maximumAPIVersion).contains(apiVersion) {
            reasons.append("Requires API \(compatibility.minimumAPIVersion)...\(compatibility.maximumAPIVersion); host provides \(apiVersion)")
        }
        let missingMethods = Set(compatibility.requiredMethods).subtracting(methods).sorted()
        let missingCommands = Set(compatibility.requiredCommands).subtracting(commands).sorted()
        func summary(_ values: [String]) -> String {
            values.prefix(8).joined(separator: ", ") + (values.count > 8 ? " (and \(values.count - 8) more)" : "")
        }
        if !missingMethods.isEmpty { reasons.append("Missing public methods: " + summary(missingMethods)) }
        if !missingCommands.isEmpty { reasons.append("Missing built-in commands: " + summary(missingCommands)) }
        return .init(compatible: reasons.isEmpty, hostAPIVersion: apiVersion,
                     hostManifestVersion: PluginCompatibility.currentManifestVersion, reasons: reasons)
    }

    public func requireCompatibility() throws {
        let report = compatibilityReport()
        guard report.compatible else {
            throw RPCFailure(code: APIError.incompatible, message: "Plugin \(id) is incompatible: " + report.reasons.joined(separator: "; "),
                             data: try .encoding(report))
        }
    }
}
