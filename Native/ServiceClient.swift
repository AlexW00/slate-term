import Foundation
import SlateTermCore

extension WorkspaceHost {
    static var serviceControlMethods: [String] {
        AutomationMethod.publicMethods.filter { $0.family == .services && $0 != .serviceReady }.map(\.rawValue)
    }

    static var serviceDescriptor: JSONValue {
        .object(["version": .integer(1), "mode": .string("manual"), "automaticStartup": .bool(false), "automaticRestart": .bool(false),
                 "maximumReservations": .integer(16), "maximumPeers": .integer(4), "maximumPolls": .integer(1),
                 "logBytesPerStream": .integer(65_536), "capabilities": .string("sharedAutomationAPI"),
                 "states": .array(["stopped", "starting", "ready", "stopping", "failed"].map(JSONValue.string)),
                 "topic": .string("host.service.state.changed")])
    }
}
