import Foundation
import SlateTermCore
import SlateTermSettings

extension WorkspaceHost {
    private func boundedNotificationText(_ value: String, limit: Int, title: Bool) -> String {
        let cleaned = NotificationStore.text(value, title: title)
        var result = ""
        var bytes = 0
        for scalar in cleaned.unicodeScalars {
            let count = scalar.utf8.count
            if bytes + count > limit { break }
            result.unicodeScalars.append(scalar); bytes += count
        }
        return result
    }

    func queueTerminalNotification(pane: PaneID, title: String, body: String) {
        guard let anchor = try? notificationAnchor(["pane": .string(pane.description)]) else { return }
        let heading = boundedNotificationText(title, limit: NotificationStore.titleBytes, title: true)
        let message = boundedNotificationText(body, limit: NotificationStore.bodyBytes, title: false)
        Task { [weak self] in
            _ = try? await self?.postNotification(title: heading.isEmpty ? "Terminal notification" : heading, body: message, key: nil,
                anchor: anchor, source: .object(["kind": .string("terminal"), "protocol": .string("OSC")]))
        }
    }

    func queueCommandNotification(pane: PaneID, command: TerminalView.Context.Command) {
        let details = notificationCommandText.removeValue(forKey: pane)
        // Conventional shell SIGINT cancellation is not a useful completion alert.
        guard command.exitCode != 130,
              let anchor = try? notificationAnchor(["pane": .string(pane.description)]) else { return }
        let failed = command.exitCode.map { $0 != 0 } ?? false
        let title = failed ? "Command failed (exit \(command.exitCode!))" : "Command finished"
        let body = "Finished after \(command.durationNanoseconds / 1_000_000_000)s."
        let commandText = details.map { boundedNotificationText($0, limit: 3000, title: false) }
        Task { [weak self] in
            _ = try? await self?.postNotification(title: title, body: body, key: "command-completion", anchor: anchor,
                source: .object(["kind": .string("terminal"), "protocol": .string("commandFinished")]),
                automatic: true, duration: command.durationNanoseconds, commandText: commandText)
        }
    }
}
