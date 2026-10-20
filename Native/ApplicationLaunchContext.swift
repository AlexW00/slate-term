import AppKit
import SlateTermCore

struct LayoutAppDescriptor {
    let layoutAppID: UUID
    let layoutID: UUID
    let name: String
    let parentBase: URL
    let parentConfigURL: URL
    var base: URL { parentBase.appendingPathComponent("LayoutApps/\(layoutAppID.uuidString.lowercased())") }
    var recipeDirectory: URL { parentConfigURL.deletingLastPathComponent().appendingPathComponent("layouts") }
}

enum ApplicationLaunchContext {
    case standard
    case layoutApp(LayoutAppDescriptor)

    @MainActor static var current: ApplicationLaunchContext = .standard
    var descriptor: LayoutAppDescriptor? { if case .layoutApp(let value) = self { return value }; return nil }
    var displayName: String { descriptor?.name ?? "Slate Terminal" }
    var isLayoutApp: Bool { descriptor != nil }

    static func resolve(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ApplicationLaunchContext {
        guard let raw = bundle.object(forInfoDictionaryKey: "SlateLayoutAppID") else { return .standard }
        guard let raw = raw as? String, let id = UUID(uuidString: raw),
              bundle.bundleIdentifier == "com.slateterm.layoutapp.\(id.uuidString.lowercased())",
              let layout = bundle.object(forInfoDictionaryKey: "SlateLayoutID") as? String, let layoutID = UUID(uuidString: layout),
              let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty else {
            throw RPCFailure(code: -32000, message: "Invalid layout app identity")
        }
        let integration = environment["SLATE_TERM_INTEGRATION"] == "1"
        if integration && environment["SLATE_TERM_STATE_DIR"] == nil {
            throw RPCFailure(code: -32000, message: "Integration mode requires an isolated parent state directory")
        }
        let parent = integration ? URL(fileURLWithPath: environment["SLATE_TERM_STATE_DIR"]!)
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SlateTerm")
        let config = integration ? URL(fileURLWithPath: environment["SLATE_TERM_CONFIG_FILE"] ?? parent.appendingPathComponent("config/config.toml").path)
            : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/slate-term/config.toml")
        return .layoutApp(.init(layoutAppID: id, layoutID: layoutID, name: name, parentBase: parent, parentConfigURL: config))
    }

    func requireParent() throws {
        if isLayoutApp { throw RPCFailure(code: -32060, message: "Manage layout apps from Slate Terminal") }
    }
}

struct LayoutAppRestorationFailure: Error, CustomStringConvertible {
    let message: String
    let file: URL
    var description: String { message }
}
