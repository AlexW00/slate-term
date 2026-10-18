import AppKit
import Combine
import SwiftUI
import Sparkle
import SlateTermCore

/// One app-wide update session serves native controls and every trusted API client.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUserDriver, SPUUpdaterDelegate, NSWindowDelegate {
    @Published private(set) var snapshot: UpdateSnapshot
    var onChange: ((UpdateSnapshot, UpdateSnapshot) -> Void)?
    var nativeAction: ((UpdateAction, String?) -> Void)?
    var confirmInstallation: (() -> Bool)?
    private let configuration: UpdateConfiguration?
    private var updater: SPUUpdater?
    private var updateWindow: NSWindow?
    private var offerReply: ((SPUUserUpdateChoice) -> Void)?
    private var sparkleCancellation: (() -> Void)?
    private var acknowledgement: (() -> Void)?
    private var retryTermination: (() -> Void)?
    private var installConsentID: String?
    private var download: UpdateArchiveDownload?
    private var verification: Task<Void, Never>?
    private var downloadGeneration = UUID()
    private var pendingCheck = false
    private var stopping = false
    private var notesPending = false
    private(set) var fixtureInstallReplies = 0
    private(set) var fixtureReadyChoices: [String] = []
    private var fixture = false

    init(bundle: Bundle = .main) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        var initial = UpdateSnapshot(currentVersion: version)
        do {
            configuration = try UpdateConfiguration(
                feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                requiresSignedFeed: bundle.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
                verifiesBeforeExtraction: bundle.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true,
                signatureFailuresExpire: (bundle.object(forInfoDictionaryKey: "SUSignedFeedFailureExpirationInterval") as? NSNumber)?.doubleValue != 0)
        } catch {
            configuration = nil
            initial.phase = .unavailable
            initial.detail = "This build does not have a configured, signed update channel."
        }
        snapshot = initial
        super.init()
    }

    private func change(_ mutate: (inout UpdateSnapshot) -> Void) {
        let before = snapshot
        var next = before
        mutate(&next)
        guard next != before else { return }
        next.revision = UUID().uuidString
        snapshot = next
        onChange?(before, next)
    }

    func perform(_ request: UpdateRequest, validateCaller: @escaping () throws -> Void = {}) throws -> UpdateSnapshot {
        try validateCaller()
        if let requested = request.updateID, requested != snapshot.updateID {
            throw RPCFailure(code: APIError.conflict, message: "The update session changed; read updates.get before acting.")
        }
        switch request.action {
        case .get: break
        case .show: showWindow()
        case .check: try check()
        case .download: try beginDownload()
        case .cancel: try cancel()
        case .install: try install(validateCaller: validateCaller)
        }
        return snapshot
    }

    func invoke(_ action: UpdateAction) { nativeAction?(action, snapshot.updateID) }

    func showWindow() {
        if updateWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 624, height: 690),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Software Update"
            window.identifier = NSUserInterfaceItemIdentifier("slate-updates")
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: UpdateView(controller: self).frame(width: 624, height: 690))
            window.setContentSize(NSSize(width: 624, height: 690))
            window.center()
            updateWindow = window
        }
        change { $0.windowVisible = true }
        updateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideWindow() { updateWindow?.orderOut(nil); change { $0.windowVisible = false } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hideWindow(); return false }

    private func check() throws {
        showWindow()
        if [.checking, .available, .downloading, .verifying, .ready, .installing].contains(snapshot.phase) { return }
        guard configuration != nil || fixture else { return }
        if fixture { beginCheck(); return }
        if updater == nil {
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
            // Override old preferences; unattended downloads and installs are never enabled.
            updater.automaticallyChecksForUpdates = false
            updater.automaticallyDownloadsUpdates = false
            updater.sendsSystemProfile = false
            updater.clearFeedURLFromUserDefaults()
            try updater.start()
            self.updater = updater
        }
        if updater?.sessionInProgress == true {
            pendingCheck = true
            let reply = offerReply; offerReply = nil; reply?(.dismiss)
            let acknowledge = acknowledgement; acknowledgement = nil; acknowledge?()
            let cancel = sparkleCancellation; sparkleCancellation = nil; cancel?()
        } else { beginCheck(); updater?.checkForUpdates() }
    }

    private func beginCheck() {
        stopDownload()
        installConsentID = nil
        notesPending = false
        change {
            $0.updateID = UUID().uuidString; $0.phase = .checking; $0.release = nil
            $0.receivedBytes = 0; $0.expectedBytes = 0; $0.detail = nil
        }
    }

    private func beginDownload() throws {
        guard [.available, .downloadError].contains(snapshot.phase), let release = snapshot.release,
              let id = snapshot.updateID, offerReply != nil, !notesPending else {
            throw RPCFailure(code: APIError.unavailable, message: "Wait for the signed release notes and an available update before downloading.")
        }
        stopDownload()
        let generation = downloadGeneration
        change { $0.phase = .downloading; $0.receivedBytes = 0; $0.expectedBytes = release.contentLength; $0.detail = nil }
        if fixture { return }
        guard let url = URL(string: release.downloadURL), let configuration else {
            throw RPCFailure(code: APIError.unavailable, message: "The update channel is unavailable.")
        }
        do {
            let transfer = try UpdateArchiveDownload(expectedLength: release.contentLength, progress: { [weak self] received in
                Task { @MainActor in
                    guard let self, self.downloadGeneration == generation, self.snapshot.updateID == id,
                          self.snapshot.phase == .downloading else { return }
                    self.change { $0.receivedBytes = received }
                }
            }, completion: { [weak self] result in
                Task { @MainActor in
                    guard let self, self.downloadGeneration == generation, self.snapshot.updateID == id,
                          self.snapshot.phase == .downloading else { return }
                    switch result {
                    case .failure:
                        self.stopDownload()
                        self.change { $0.phase = .downloadError; $0.detail = "The download didn’t finish. Check your connection and try again." }
                    case .success(let file): self.verify(file, release: release, publicKey: configuration.publicKey, generation: generation)
                    }
                }
            })
            download = transfer
            transfer.start(url)
        } catch {
            stopDownload()
            change { $0.phase = .downloadError; $0.detail = "Slate could not prepare a private download. Try again." }
        }
    }

    private func verify(_ file: URL, release: UpdateRelease, publicKey: Data, generation: UUID) {
        change { $0.phase = .verifying; $0.receivedBytes = release.contentLength }
        verification = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try UpdateArchiveVerifier.verify(data: Data(contentsOf: file, options: .mappedIfSafe),
                    expectedLength: release.contentLength, signature: release.signature, publicKey: publicKey) }
            }.value
            guard let self, !Task.isCancelled, self.downloadGeneration == generation,
                  self.snapshot.phase == .verifying else { return }
            self.download?.cleanup(); self.download = nil; self.verification = nil
            switch result {
            case .success: self.change { $0.phase = .ready; $0.detail = nil }
            case .failure: self.change { $0.phase = .verificationError; $0.detail = "The downloaded file failed signature verification. Nothing was installed." }
            }
        }
    }

    private func stopDownload() {
        downloadGeneration = UUID()
        verification?.cancel(); verification = nil
        download?.cleanup(); download = nil
    }

    private func cancel() throws {
        guard snapshot.phase != .installing else {
            throw RPCFailure(code: APIError.unavailable, message: "Installation was explicitly started; complete the normal quit confirmation.")
        }
        pendingCheck = false
        stopDownload()
        if snapshot.release != nil && offerReply != nil {
            change { $0.phase = .available; $0.receivedBytes = 0; $0.detail = nil }
        } else {
            let cancellation = sparkleCancellation; sparkleCancellation = nil; cancellation?()
            let acknowledge = acknowledgement; acknowledgement = nil; acknowledge?()
            change { $0.phase = .idle; $0.detail = nil }
        }
    }

    private func install(validateCaller: () throws -> Void) throws {
        if snapshot.phase == .installing, let retryTermination, installConsentID == snapshot.updateID {
            try validateCaller(); retryTermination(); return
        }
        guard snapshot.phase == .ready, let id = snapshot.updateID, let reply = offerReply else {
            throw RPCFailure(code: APIError.unavailable, message: "Only the verified, ready update can be installed.")
        }
        // Confirmation can reenter the app; revalidate both the caller and captured update afterwards.
        guard confirmInstallation?() ?? true else { return }
        try validateCaller()
        guard snapshot.updateID == id, snapshot.phase == .ready, offerReply != nil else {
            throw RPCFailure(code: APIError.conflict, message: "The update changed during quit confirmation.")
        }
        installConsentID = id
        offerReply = nil
        change { $0.phase = .installing; $0.detail = "Downloading and validating the update for installation."; $0.receivedBytes = 0 }
        reply(.install)
    }

    func shutdown() {
        stopping = true; pendingCheck = false
        stopDownload()
        let reply = offerReply; offerReply = nil; reply?(.dismiss)
        let cancel = sparkleCancellation; sparkleCancellation = nil; cancel?()
        let acknowledge = acknowledgement; acknowledgement = nil; acknowledge?()
        updateWindow?.orderOut(nil)
    }

    // MARK: Sparkle public user driver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        guard !stopping, snapshot.phase == .checking else { cancellation(); return }
        sparkleCancellation = cancellation
    }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !stopping, snapshot.phase == .checking else { reply(state.stage == .installing ? .skip : .dismiss); return }
        sparkleCancellation = nil
        guard item.signingValidationStatus == .succeeded, validNotesMetadata(item),
              state.stage == .notDownloaded, !item.isInformationOnlyUpdate,
              let url = item.fileURL, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              item.contentLength > 0, item.contentLength <= UpdateArchiveVerifier.maxArchiveBytes,
              let enclosure = item.propertiesDictionary["enclosure"] as? [String: Any],
              let signature = enclosure["sparkle:edSignature"] as? String,
              Data(base64Encoded: signature)?.count == 64 else {
            reply(state.stage == .installing ? .skip : .dismiss)
            change { $0.phase = .verificationError; $0.detail = "This update does not meet Slate’s signed-update requirements." }
            return
        }
        offerReply = reply
        notesPending = item.releaseNotesURL != nil
        let notes = notesPending ? "Loading signed release notes…" : (item.itemDescription ?? "No release notes were provided.")
        let release = UpdateRelease(id: snapshot.updateID!, version: item.displayVersionString, build: item.versionString,
            notes: String(notes.prefix(65_536)), downloadURL: url.absoluteString, contentLength: item.contentLength, signature: signature)
        change {
            $0.phase = .available; $0.release = release; $0.expectedBytes = release.contentLength
            $0.detail = notesPending ? "Loading signed release notes…" : nil
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        guard offerReply != nil, snapshot.release != nil, notesPending else { return }
        guard downloadData.data.count <= 256 * 1_024, let notes = String(data: downloadData.data, encoding: .utf8) else {
            notesFailed(); return
        }
        notesPending = false
        change { $0.release?.notes = notes; $0.detail = nil }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { notesFailed() }
    private func notesFailed() {
        guard offerReply != nil else { return }
        notesPending = false
        let reply = offerReply; offerReply = nil
        change { $0.phase = .verificationError; $0.detail = "Signed release notes could not be loaded. Check again before installing." }
        reply?(.dismiss)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard !stopping, snapshot.phase == .checking else { acknowledgement(); return }
        sparkleCancellation = nil
        self.acknowledgement = acknowledgement
        change { $0.phase = .current; $0.release = nil; $0.detail = error.localizedDescription }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard !stopping, [.checking, .available, .downloading, .verifying, .ready, .installing].contains(snapshot.phase) else { acknowledgement(); return }
        stopDownload()
        offerReply = nil; sparkleCancellation = nil; retryTermination = nil; installConsentID = nil
        self.acknowledgement = acknowledgement
        change { $0.phase = $0.phase == .checking ? .checkError : .verificationError; $0.detail = error.localizedDescription }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard installConsentID == snapshot.updateID, snapshot.phase == .installing else { cancellation(); return }
        // This is Sparkle's second download, after explicit installation consent.
        sparkleCancellation = cancellation
        change { $0.receivedBytes = 0 }
    }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {
        guard snapshot.phase == .installing else { return }
        guard length == 0 || length == snapshot.release?.contentLength else { rejectInstallationDownload(); return }
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard snapshot.phase == .installing, let expected = snapshot.release?.contentLength else { return }
        let (received, overflow) = snapshot.receivedBytes.addingReportingOverflow(length)
        guard !overflow, received <= expected, received <= UpdateArchiveVerifier.maxArchiveBytes else { rejectInstallationDownload(); return }
        change { $0.receivedBytes = received }
    }
    private func rejectInstallationDownload() {
        let cancel = sparkleCancellation; sparkleCancellation = nil; installConsentID = nil
        change { $0.phase = .verificationError; $0.detail = "The installation download exceeded its signed size. Nothing was installed." }
        cancel?()
    }
    func showDownloadDidStartExtractingUpdate() {
        guard snapshot.phase == .installing, installConsentID == snapshot.updateID else { return }
        sparkleCancellation = nil
        change { $0.detail = "Verifying and preparing the signed update." }
    }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !stopping, installConsentID == snapshot.updateID, snapshot.phase == .installing else { reply(.skip); return }
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        guard !stopping, snapshot.phase == .installing, installConsentID == snapshot.updateID else { return }
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        change { $0.detail = applicationTerminated ? "Finishing installation…" : "Waiting for Slate to quit. If you canceled quitting, choose Install and Relaunch to try again." }
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {
        sparkleCancellation = nil
        acknowledgement = nil
        // Preserve terminal states and release notes until the user closes or checks again.
    }
    func showUpdateInFocus() { showWindow() }

    // MARK: Sparkle policy

    func feedURLString(for updater: SPUUpdater) -> String? { configuration?.feedURL.absoluteString }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard item.signingValidationStatus == .succeeded, validNotesMetadata(item) else {
            throw RPCFailure(code: APIError.unavailable, message: "The update feed could not be authenticated.")
        }
    }
    private func validNotesMetadata(_ item: SUAppcastItem) -> Bool {
        guard let url = item.releaseNotesURL, url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()),
              let metadata = item.propertiesDictionary["sparkle:releaseNotesLink"] as? [String: Any],
              let signature = metadata["sparkle:edSignature"] as? String, Data(base64Encoded: signature)?.count == 64,
              let lengthText = metadata["sparkle:length"] as? String, let length = UInt64(lengthText),
              length > 0, length <= 256 * 1_024 else { return false }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if pendingCheck, !stopping {
            pendingCheck = false
            beginCheck()
            let id = snapshot.updateID
            Task { @MainActor [weak self] in
                guard let self, !self.stopping, self.snapshot.updateID == id, self.snapshot.phase == .checking else { return }
                self.updater?.checkForUpdates()
            }
        }
    }

    // The VM fixture supplies transport outcomes, then exercises production actions and views.
    func fixtureState(_ phase: UpdatePhase) {
        fixture = true
        stopDownload()
        installConsentID = nil; retryTermination = nil; notesPending = false
        let id = UUID().uuidString
        let notes = "# A clearer view of your agents.\n\nSee who is working in a pane, and get back to their terminal with a click.\n\n## Agent activity\n\n- Detached Liquid Glass pills keep agent activity in the bottom-right corner of each pane.\n- Click an indicator to bring the agent’s window and terminal into focus.\n- Live operations show elapsed time, then a clear completion or failure state.\n\n## Fixes & refinements\n\n- Old activity can no longer focus a replacement terminal.\n- Browser indicators stay clear of the status bar.\n- Improved keyboard focus when returning from the command picker.\n\nIllustrative release notes for native verification."
        offerReply = { [weak self] choice in if choice == .install { self?.fixtureInstallReplies += 1 } }
        change {
            $0.updateID = id; $0.phase = phase; $0.detail = nil; $0.currentVersion = "0.1.0"
            $0.release = [.checking, .current, .idle, .unavailable].contains(phase) ? nil : UpdateRelease(id: id,
                version: "0.2.0", build: "2", notes: notes, downloadURL: "https://example.invalid/Slate.zip",
                contentLength: 24_600_000, signature: "fixture")
            $0.receivedBytes = phase == .downloading ? 10_600_000 : 0; $0.expectedBytes = 24_600_000
        }
    }

    func fixtureOperation(_ name: String, receivedBytes: UInt64 = 0, nextPhase: UpdatePhase? = nil) {
        guard fixture else { return }
        switch name {
        case "notesFailure": notesFailed()
        case "progress":
            change {
                $0.receivedBytes = receivedBytes
                if let nextPhase, [.verifying, .ready].contains(nextPhase) { $0.phase = nextPhase }
            }
        case "lateCheck":
            showUpdateNotFoundWithError(NSError(domain: "fixture", code: 1), acknowledgement: {})
        case "oversizedInstall": showDownloadDidReceiveData(ofLength: UpdateArchiveVerifier.maxArchiveBytes + 1)
        case "readyCallback":
            showReady { [weak self] choice in self?.fixtureReadyChoices.append(choice == .install ? "install" : "skip") }
        case "installationCallback":
            showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
        default: break
        }
    }

    var canDownload: Bool { [.available, .downloadError].contains(snapshot.phase) && !notesPending && offerReply != nil }
    var canRetryInstallation: Bool { snapshot.phase == .installing && retryTermination != nil }
    var usesFixture: Bool { fixture }
    var windowForTesting: NSWindow? { updateWindow }
}
