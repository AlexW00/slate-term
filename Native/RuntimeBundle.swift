import Foundation

private final class RuntimeBundleMarker: NSObject {}

/// Versioned implementation assets live with the runtime, independently of the outer app identity.
enum RuntimeBundle {
    nonisolated static let bundle = Bundle(for: RuntimeBundleMarker.self)
    nonisolated static var helpersURL: URL {
        bundle.executableURL!.deletingLastPathComponent().appendingPathComponent("Helpers", isDirectory: true)
    }
}
