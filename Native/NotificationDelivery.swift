import AppKit
import CryptoKit
import UserNotifications
import SlateTermCore

/// OS presentation only. Policy, lifetime checks and outstanding state belong to the host.
@MainActor
final class NotificationDelivery: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?
    private let prefix: String
    private var active = Set<String>()
    var testingAuthorization = "authorized"
    var testingAuthorizationDelayMilliseconds = 0
    var testingSubmissionSucceeds = true
    private var authorizationQuery: (id: UUID, task: Task<String, Never>)?
    private(set) var authorizationInspectionCount = 0
    var onOpen: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?
    var mayPresent: ((String) -> Bool)?
    init(epoch: String, stateRoot: String, testing: Bool) {
        // Separate live app instances can share a bundle ID, but not a state-root lock.
        // Scope crash cleanup to this root so a sibling instance keeps its notifications.
        let digest = SHA256.hash(data: Data(stateRoot.utf8)).map { String(format: "%02x", $0) }.joined()
        let namespace = "slate.\(digest.prefix(16))."
        prefix = namespace + epoch + "."
        center = testing ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
        center?.setNotificationCategories([UNNotificationCategory(identifier: "slate.notification", actions: [], intentIdentifiers: [], options: [.customDismissAction])])
        if let center {
            center.getDeliveredNotifications { [weak self, prefix, namespace] delivered in
                let obsolete = delivered.map { $0.request.identifier }.filter { $0.hasPrefix(namespace) && !$0.hasPrefix(prefix) }
                Task { @MainActor [weak self] in self?.center?.removeDeliveredNotifications(withIdentifiers: obsolete) }
            }
        }
    }
    func authorization() async -> String {
        if let query = authorizationQuery { return await query.task.value }
        let id = UUID()
        authorizationInspectionCount += 1
        let task = Task { [weak self] in await self?.inspectAuthorization() ?? "unavailable" }
        authorizationQuery = (id, task)
        let result = await task.value
        if authorizationQuery?.id == id { authorizationQuery = nil }
        return result
    }
    private func inspectAuthorization() async -> String {
        guard let center else {
            if testingAuthorizationDelayMilliseconds > 0 { try? await Task.sleep(for: .milliseconds(testingAuthorizationDelayMilliseconds)) }
            return testingAuthorization
        }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unavailable"
        }
    }
    /// Deliberately native-user initiated, never called by post or an incoming escape sequence.
    func requestAuthorization() async {
        guard let center else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }
    func submit(_ notification: SlateNotification, sound: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        active.insert(notification.id)
        guard let center else { completion(testingSubmissionSucceeds); return }
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "slate.notification"
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.anchor.paneId.map { "pane.\($0)" } ?? "application"
        if sound { content.sound = .default }
        let id = notification.id
        center.add(UNNotificationRequest(identifier: prefix + id, content: content, trigger: nil)) { [weak self] error in
            let success = error == nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Focus/dismissal can race the OS's asynchronous add.
                if !self.active.contains(id) { self.withdraw([id]); return }
                completion(success)
            }
        }
    }
    func withdraw(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        active.subtract(ids)
        let native = ids.map { prefix + $0 }
        center?.removePendingNotificationRequests(withIdentifiers: native)
        center?.removeDeliveredNotifications(withIdentifiers: native)
    }
    func close() {
        authorizationQuery?.task.cancel()
        authorizationQuery = nil
        withdraw(Array(active))
        center?.delegate = nil
        onOpen = nil; onDismiss = nil; mayPresent = nil
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self, identifier.hasPrefix(self.prefix) else { return }
            let id = String(identifier.dropFirst(self.prefix.count))
            if action == UNNotificationDefaultActionIdentifier { self.onOpen?(id) }
            else if action == UNNotificationDismissActionIdentifier { self.onDismiss?(id) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        let hasSound = notification.request.content.sound != nil
        Task { @MainActor [weak self] in
            guard let self, identifier.hasPrefix(self.prefix),
                  self.mayPresent?(String(identifier.dropFirst(self.prefix.count))) == true else {
                completionHandler([]); return
            }
            completionHandler(hasSound ? [.banner, .list, .sound] : [.banner, .list])
        }
    }
}
