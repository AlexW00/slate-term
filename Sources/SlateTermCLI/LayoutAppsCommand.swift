import ArgumentParser
import Foundation
import SlateTermCore

struct LayoutAppsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "layout-apps", abstract: "List or refresh independent layout apps from Slate Terminal.")
    enum Action: String, CaseIterable, ExpressibleByArgument {
        case list, refresh
        var method: String { "layoutApps." + rawValue }
    }
    @Argument var action: Action
    @OptionGroup var connection: Connection
    @Option(help: "Persistent layout-app UUID from layout-apps list; required for refresh.") var layoutAppId: String?
    @Option(help: "Bundle revision from layout-apps list; required for refresh.") var expectedBundleRevision: String?

    func parameters() throws -> [String: JSONValue] {
        switch action {
        case .list:
            guard layoutAppId == nil, expectedBundleRevision == nil else {
                throw ValidationError("list does not accept --layout-app-id or --expected-bundle-revision")
            }
            return [:]
        case .refresh:
            guard let layoutAppId, UUID(uuidString: layoutAppId) != nil else {
                throw ValidationError("refresh requires a UUID --layout-app-id")
            }
            guard let expectedBundleRevision, !expectedBundleRevision.isEmpty else {
                throw ValidationError("refresh requires --expected-bundle-revision from layout-apps list")
            }
            return ["layoutAppID": .string(layoutAppId), "expectedBundleRevision": .string(expectedBundleRevision)]
        }
    }

    func run() throws {
        // Management targets persistent app identity and never inherits pane routing.
        try connection.call(action.method, params: parameters())
    }
}
