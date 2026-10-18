import Foundation
import SlateTermCore

extension WorkspaceHost {
    static var serviceControlMethods: [String] {
        AutomationMethod.publicMethods.filter { $0.family == .services && $0 != .serviceReady }.map(\.rawValue)
    }

    static var serviceDescriptor: JSONValue { AutomationCapabilities.backgroundServices }
}
