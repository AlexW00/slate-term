import AppKit
import WebKit
import SlateTermCore

/// WebKit owns the transfer, including cookies, private storage and blob data.
@MainActor
final class BrowserDownloads: NSObject, WKDownloadDelegate, NSOpenSavePanelDelegate {
    private enum State: String {
        case starting, awaitingDestination, downloading, completed, cancelled, failed
        var active: Bool { self == .starting || self == .awaitingDestination || self == .downloading }
    }

    private final class Entry {
        let id = UUID().uuidString
        var download: WKDownload?
        weak var window: NSWindow?
        var state = State.starting
        var filename = "download"
        var mimeType: String?
        var path: String?
        var stagingDirectory: URL?
        var stagingFile: URL?
        var error: JSONValue?
        var receivedBytes = 0
        var totalBytes: Int?
        var completion: (@MainActor @Sendable (URL?) -> Void)?
        let destinationDeadline = ContinuousClock.now.advanced(by: .seconds(300))

        init(download: WKDownload, window: NSWindow?) {
            self.download = download
            self.window = window
        }
    }

    private let window: () -> NSWindow?
    private var entries: [Entry] = []
    private var panel: (id: String, panel: NSSavePanel)?
    private var monitor: Task<Void, Never>?
    private var closed = false
    private var downloadsWindow: NSPanel?
    private var rowsStack: NSStackView?
    private var rows: [String: DownloadRow] = [:]
    @MainActor private final class DownloadRow {
        let container = NSStackView()
        let filename = NSTextField(labelWithString: "")
        let detail = NSTextField(labelWithString: "")
        let progress = NSProgressIndicator()
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    }
    var onChange: (() -> Void)?
    var presentationWindow: NSWindow? { downloadsWindow }
    var activeCount: Int { entries.filter { $0.state.active }.count }
    var statuses: [JSONValue] { entries.map(snapshot) }

    init(window: @escaping () -> NSWindow?) {
        self.window = window
        super.init()
    }

    func receive(_ download: WKDownload, window: NSWindow? = nil) {
        guard !closed, activeCount < 8 else { download.cancel(nil); return }
        guard !entries.contains(where: { $0.download === download }) else { return }
        while entries.count >= 64, let index = entries.firstIndex(where: { !$0.state.active }) {
            entries.remove(at: index)
        }
        entries.append(Entry(download: download, window: window))
        download.delegate = self
        startMonitor()
        onChange?()
    }

    /// API calls return current state immediately; only WebKit waits for a destination.
    func operation(_ request: BrowserDownloadRequest) throws -> JSONValue {
        guard !closed else { throw RPCFailure(code: APIError.unavailable, message: "Browser download owner is closed") }
        if request.kind == .show {
            showDownloads()
            return .object(["shown": .bool(true)])
        }
        if request.kind == .list { return .object(["downloads": .array(statuses)]) }
        guard let entry = entries.first(where: { $0.id == request.downloadID }) else {
            throw RPCFailure(code: APIError.conflict, message: "Unknown or expired downloadId for this browser")
        }
        switch request.kind {
        case .list, .status, .show: break
        case .save:
            guard let path = request.path else { throw RPCFailure(code: -32602, message: "A destination path is required") }
            try save(entry, path: path)
        case .cancel:
            guard entry.state.active else {
                throw RPCFailure(code: APIError.conflict, message: "Download is no longer active")
            }
            cancel(entry)
        }
        return snapshot(entry)
    }

    func close() {
        guard !closed else { return }
        closed = true
        monitor?.cancel()
        monitor = nil
        for entry in entries where entry.state.active { cancel(entry) }
        dismissPanel()
        entries.removeAll()
        downloadsWindow?.close()
        downloadsWindow = nil
        rowsStack = nil
        rows.removeAll()
        onChange = nil
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard !closed, let entry = entries.first(where: { $0.download === download }),
              entry.state == .starting else {
            completionHandler(nil)
            return
        }
        entry.filename = BrowserDownloadRequest.safeSuggestedFilename(suggestedFilename)
        entry.mimeType = response.mimeType.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(128))) }
        entry.totalBytes = response.expectedContentLength >= 0 ? Int(clamping: response.expectedContentLength) : nil
        entry.completion = completionHandler
        entry.state = .awaitingDestination
        onChange?()
        presentNextPanel()
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = entries.first(where: { $0.download === download }), entry.state == .downloading else { return }
        updateProgress(entry)
        do {
            guard let source = entry.stagingFile, let path = entry.path else {
                throw RPCFailure(code: APIError.unavailable, message: "Download destination is unavailable")
            }
            try BrowserDownloadRequest.publish(stagedFile: source, destination: URL(fileURLWithPath: path))
            entry.state = .completed
        } catch {
            entry.state = .failed
            entry.error = .object(["message": .string("The completed download could not be saved; the destination may already exist")])
        }
        removeStaging(entry)
        entry.download = nil
        onChange?()
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let entry = entries.first(where: { $0.download === download }), entry.state.active else { return }
        updateProgress(entry)
        entry.state = .failed
        let failure = error as NSError
        // Error descriptions may contain signed URLs or other request secrets.
        entry.error = .object(["domain": .string(String(String.UnicodeScalarView(failure.domain.unicodeScalars.prefix(128)))),
                               "code": .integer(failure.code), "message": .string("The download failed")])
        finishDestination(entry, url: nil)
        removeStaging(entry)
        entry.download = nil
        onChange?()
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !closed, entries.contains(where: { $0.download === download && $0.state.active }) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        _ = try BrowserDownloadRequest.destinationURL(for: url.path)
    }

    private func save(_ entry: Entry, path: String) throws {
        guard !closed, entry.state == .awaitingDestination, entry.completion != nil else {
            throw RPCFailure(code: APIError.conflict, message: "Download is no longer waiting for a destination")
        }
        let destination = try BrowserDownloadRequest.destinationURL(for: path)
        let directory = destination.deletingLastPathComponent().appendingPathComponent(".slate-download-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw RPCFailure(code: APIError.unavailable, message: "Could not create a temporary download directory")
        }
        let stagingFile = directory.appendingPathComponent("download")
        entry.stagingDirectory = directory
        entry.stagingFile = stagingFile
        entry.path = destination.path
        entry.error = nil
        entry.state = .downloading
        finishDestination(entry, url: stagingFile)
        onChange?()
    }

    private func cancel(_ entry: Entry) {
        updateProgress(entry)
        entry.state = .cancelled
        let download = entry.download
        finishDestination(entry, url: nil)
        entry.download = nil
        let directory = entry.stagingDirectory
        entry.stagingDirectory = nil
        entry.stagingFile = nil
        // WebKit may still hold the partial file until cancellation completes.
        download?.cancel { _ in
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        onChange?()
    }

    private func finishDestination(_ entry: Entry, url: URL?) {
        let completion = entry.completion
        entry.completion = nil
        if panel?.id == entry.id { dismissPanel() }
        completion?(url)
    }

    private func dismissPanel() {
        guard let current = panel else { return }
        panel = nil
        if let parent = current.panel.sheetParent { parent.endSheet(current.panel, returnCode: .cancel) }
        current.panel.orderOut(nil)
    }

    private func presentNextPanel() {
        guard !closed, panel == nil else { return }
        guard let entry = entries.first(where: { $0.state == .awaitingDestination }),
              let parent = entry.window ?? window(), parent.isVisible, parent.attachedSheet == nil else { return }
        let chooser = NSSavePanel()
        chooser.title = "Save Download"
        chooser.nameFieldStringValue = entry.filename
        chooser.canCreateDirectories = true
        chooser.isExtensionHidden = false
        chooser.delegate = self
        chooser.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel = (entry.id, chooser)
        chooser.beginSheetModal(for: parent) { [weak self, weak entry] response in
            guard let self, let entry, self.panel?.id == entry.id, entry.state == .awaitingDestination else { return }
            self.panel = nil
            if response == .OK, let url = chooser.url {
                do { try self.save(entry, path: url.path) }
                catch {
                    entry.error = .object(["message": .string("Choose a new filename in an existing writable directory")])
                    self.onChange?()
                }
            } else { self.cancel(entry) }
        }
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self, !self.closed else { return }
                for entry in self.entries where entry.state == .starting || entry.state == .awaitingDestination {
                    if ContinuousClock.now >= entry.destinationDeadline {
                        entry.error = .object(["message": .string("Download destination selection timed out")])
                        self.cancel(entry)
                    }
                }
                self.presentNextPanel()
                self.refreshDownloadRows()
                if self.activeCount == 0 {
                    self.monitor = nil
                    return
                }
            }
        }
    }

    private func updateProgress(_ entry: Entry) {
        guard let progress = entry.download?.progress else { return }
        entry.receivedBytes = max(0, Int(clamping: progress.completedUnitCount))
        if progress.totalUnitCount >= 0 { entry.totalBytes = Int(clamping: progress.totalUnitCount) }
    }

    private func removeStaging(_ entry: Entry) {
        if let directory = entry.stagingDirectory { try? FileManager.default.removeItem(at: directory) }
        entry.stagingDirectory = nil
        entry.stagingFile = nil
    }

    private func snapshot(_ entry: Entry) -> JSONValue {
        updateProgress(entry)
        return .object([
            "downloadId": .string(entry.id), "state": .string(entry.state.rawValue),
            "suggestedFilename": .string(entry.filename), "mimeType": entry.mimeType.map(JSONValue.string) ?? .null,
            "path": entry.path.map(JSONValue.string) ?? .null,
            "receivedBytes": .integer(entry.receivedBytes), "totalBytes": entry.totalBytes.map(JSONValue.integer) ?? .null,
            "error": entry.error ?? .null,
        ])
    }

    func showDownloads() {
        guard !closed else { return }
        if let downloadsWindow {
            refreshDownloadRows()
            downloadsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Browser Downloads"
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 240)
        let scroll = NSScrollView(frame: panel.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        panel.contentView?.addSubview(scroll)
        downloadsWindow = panel
        rowsStack = stack
        refreshDownloadRows()
        if let parent = window() {
            panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                         y: parent.frame.midY - panel.frame.height / 2))
        } else { panel.center() }
        panel.makeKeyAndOrderFront(nil)
    }

    private func refreshDownloadRows() {
        guard let stack = rowsStack else { return }
        if entries.isEmpty {
            if stack.arrangedSubviews.isEmpty {
                stack.addArrangedSubview(NSTextField(labelWithString: "No downloads yet"))
            }
            return
        }
        for child in stack.arrangedSubviews where child is NSTextField { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        for id in Array(rows.keys) where !entries.contains(where: { $0.id == id }) {
            if let row = rows.removeValue(forKey: id) { stack.removeArrangedSubview(row.container); row.container.removeFromSuperview() }
        }
        for entry in entries {
            let row: DownloadRow
            if let existing = rows[entry.id] { row = existing }
            else {
                row = DownloadRow()
                row.container.orientation = .vertical
                row.container.alignment = .leading
                row.container.spacing = 5
                row.filename.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
                row.filename.lineBreakMode = .byTruncatingMiddle
                row.detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                row.detail.textColor = .secondaryLabelColor
                row.detail.lineBreakMode = .byTruncatingMiddle
                row.progress.style = .bar
                row.progress.minValue = 0
                row.progress.maxValue = 1
                row.cancel.target = self
                row.cancel.identifier = NSUserInterfaceItemIdentifier(entry.id)
                row.cancel.action = #selector(cancelFromList(_:))
                for child in [row.filename, row.detail, row.progress, row.cancel] { row.container.addArrangedSubview(child) }
                stack.addArrangedSubview(row.container)
                row.container.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
                for child in [row.filename, row.detail, row.progress] {
                    child.widthAnchor.constraint(equalTo: row.container.widthAnchor).isActive = true
                }
                rows[entry.id] = row
            }
            updateProgress(entry)
            row.filename.stringValue = entry.filename
            row.filename.toolTip = entry.path ?? entry.filename
            let state: String
            switch entry.state {
            case .starting: state = "Starting"
            case .awaitingDestination: state = "Choose where to save this download"
            case .downloading:
                let received = ByteCountFormatter.string(fromByteCount: Int64(entry.receivedBytes), countStyle: .file)
                state = entry.totalBytes.map { received + " of " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? received
            case .completed: state = "Completed"
            case .cancelled: state = "Cancelled"
            case .failed: state = "Failed"
            }
            row.detail.stringValue = entry.error?.object?["message"]?.string.map { "\(state) · \($0)" } ?? state
            row.progress.isHidden = entry.state != .downloading
            if let total = entry.totalBytes, total > 0 {
                row.progress.isIndeterminate = false
                row.progress.doubleValue = min(1, Double(entry.receivedBytes) / Double(total))
            } else {
                row.progress.isIndeterminate = true
                if entry.state == .downloading { row.progress.startAnimation(nil) }
            }
            row.cancel.isHidden = !entry.state.active
            row.cancel.setAccessibilityLabel("Cancel download \(entry.filename)")
        }
    }

    @objc private func cancelFromList(_ sender: NSButton) {
        guard let entry = entries.first(where: { $0.id == sender.identifier?.rawValue }), entry.state.active else { return }
        cancel(entry)
        refreshDownloadRows()
    }

    func cancelNativelyForTesting(_ id: String) throws {
        guard downloadsWindow?.isVisible == true, let row = rows[id], !row.cancel.isHidden else {
            throw RPCFailure(code: APIError.unavailable, message: "Download cancel button is not visible")
        }
        row.cancel.performClick(nil)
    }
}
