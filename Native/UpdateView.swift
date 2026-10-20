import AppKit
import SlateTermCore
import SwiftUI

@MainActor
struct UpdateView: View {
    @ObservedObject var controller: UpdateController

    private var snapshot: UpdateSnapshot { controller.snapshot }
    private var phase: UpdatePhase { snapshot.phase }
    private var showsNotes: Bool {
        !controller.isLayoutApp && snapshot.release != nil && ![.idle, .unavailable, .checking, .current].contains(phase)
    }
    private var isError: Bool { [.downloadError, .verificationError, .checkError].contains(phase) }
    private var isBusy: Bool { [.checking, .downloading, .verifying, .installing].contains(phase) }

    var body: some View {
        VStack(spacing: 0) {
            heading
            if showsNotes, let release = snapshot.release {
                notesCard(release)
            } else {
                explanatoryPanel
            }
            status
            Spacer(minLength: 0)
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { controller.hideWindow() }
    }

    private var heading: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 60, height: 60)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.4)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 7) {
                    Text("\(controller.displayName) \(showsNotes ? snapshot.release?.version ?? snapshot.currentVersion : snapshot.currentVersion)")
                        .fontWeight(.medium)
                    if showsNotes {
                        Text("←").foregroundStyle(.tertiary)
                        Text("You have \(snapshot.currentVersion)").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }

    private func notesCard(_ release: UpdateRelease) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("What’s new")
                    .font(.system(size: 12, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("Version \(release.version)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            Divider()
            UpdateReleaseNotes(notes: release.notes, releaseID: snapshot.updateID ?? release.id,
                               version: release.version, close: { controller.hideWindow() })
                .frame(height: 334)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .padding(.horizontal, 24)
    }

    private var explanatoryPanel: some View {
        VStack(spacing: 15) {
            Image(systemName: phase == .current ? "checkmark" : phase == .unavailable ? "arrow.down.circle" : "arrow.triangle.2.circlepath")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(explanation)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 310)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 379)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .padding(.horizontal, 24)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Group {
                    if isBusy {
                        ProgressView().controlSize(.small).scaleEffect(0.75)
                    } else {
                        Image(systemName: isError ? "exclamationmark.triangle" : [.ready, .current].contains(phase) ? "checkmark" : "arrow.down.to.line")
                            .font(.system(size: 14))
                            .foregroundStyle(isError ? Color.red : [.ready, .current].contains(phase) ? Color.green : Color.secondary)
                    }
                }
                .frame(width: 16, height: 18)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isError ? Color.red : Color.primary)
                    Text(snapshot.detail ?? defaultDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if phase == .downloading {
                VStack(spacing: 5) {
                    if snapshot.expectedBytes > 0 {
                        ProgressView(value: min(Double(snapshot.receivedBytes) / Double(snapshot.expectedBytes), 1))
                            .accessibilityLabel("Update download progress")
                    } else {
                        ProgressView().progressViewStyle(.linear)
                            .accessibilityLabel("Downloading update")
                    }
                    HStack {
                        Text(downloadAmount)
                        Spacer()
                        if snapshot.expectedBytes > 0 {
                            Text("\(Int(min(Double(snapshot.receivedBytes) / Double(snapshot.expectedBytes), 1) * 100))%")
                        }
                    }
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }
                .padding(.leading, 25)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isError ? 14 : 4)
        .padding(.vertical, 12)
        .background(isError ? Color.red.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isError ? Color.red.opacity(0.2) : Color.clear, lineWidth: 1))
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
        .frame(minHeight: 110)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("updates.status")
    }

    private var actions: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                Text(footerNote)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 220, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if controller.isLayoutApp {
                        Button("Open Slate Terminal") { controller.invoke(.openParent) }
                            .accessibilityIdentifier("updates.openParent")
                    }
                    if let secondaryTitle {
                        Button(secondaryTitle) {
                            if [.checking, .downloading, .verifying].contains(phase) { controller.invoke(.cancel) }
                            else { controller.hideWindow() }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("updates.secondary")
                        .background { if controller.usesFixture { UpdateControlAnchor(name: "updates.secondary") } }
                    }
                    Button(action: primaryAction) {
                        Text(primaryTitle).frame(minWidth: 115)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(primaryDisabled)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("updates.primary")
                    .background { if controller.usesFixture { UpdateControlAnchor(name: "updates.primary") } }
                }
                .controlSize(.regular)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 24)
            .padding(.top, 15)
            .padding(.bottom, 19)
        }
    }

    private var title: String {
        switch phase {
        case .idle: "Software updates."
        case .unavailable: "Updates aren’t available."
        case .checking: "Checking for updates…"
        case .available: "An update is available."
        case .downloading: "Downloading the update."
        case .verifying: "Checking the download."
        case .ready: "Ready when you are."
        case .installing: "Installing the update."
        case .downloadError: "The download didn’t finish."
        case .verificationError: "This update can’t be installed."
        case .checkError: "Couldn’t check for updates."
        case .current: "You’re up to date."
        }
    }

    private var statusTitle: String {
        switch phase {
        case .idle: "Check for a newer version"
        case .unavailable: "Updates are unavailable in this build"
        case .checking: "Looking for a newer version"
        case .available: "Ready to download"
        case .downloading: "Downloading Slate Terminal \(snapshot.release?.version ?? "")…"
        case .verifying: "Verifying the update…"
        case .ready: "Ready to install"
        case .installing: controller.canRetryInstallation ? "Waiting to relaunch" : "Preparing installation…"
        case .downloadError: "Couldn’t download the update"
        case .verificationError: "The update couldn’t be verified"
        case .checkError: "The update check didn’t finish"
        case .current: "\(controller.displayName) \(snapshot.currentVersion) is current"
        }
    }

    private var explanation: String {
        if controller.isLayoutApp {
            return phase == .ready ? "Runtime \(snapshot.release?.version ?? "") is ready in Slate Terminal. Restart \(controller.displayName) when you’re ready to apply it." : "Runtime updates come from your installed copy of Slate Terminal. Update Slate Terminal first, then restart this app."
        }
        return switch phase {
        case .unavailable: "This build hasn’t been configured with a trusted update feed and signing key."
        case .current: "You’re running the latest version of Slate Terminal."
        case .checking: "Checking for an update. Release notes appear here before you choose to download."
        default: "Read what’s new before downloading. Installation waits for your confirmation."
        }
    }

    private var defaultDetail: String {
        switch phase {
        case .idle, .checking: "Your installed version is \(snapshot.currentVersion)."
        case .unavailable: "You can continue using your installed version."
        case .available: snapshot.release.map { formatBytes($0.contentLength) } ?? ""
        case .downloading: "You can keep working while it downloads."
        case .verifying: "Checking authenticity before anything is installed."
        case .ready: "Slate will quit and reopen to finish installing."
        case .installing: "Keep Slate open while the update is prepared."
        case .downloadError: "Check your connection and try again. Your current version hasn’t changed."
        case .verificationError: "The downloaded file was rejected. Check again for a trusted update."
        case .checkError: "Check your connection and try again."
        case .current: "You can check again from the app menu at any time."
        }
    }

    private var footerNote: String {
        if controller.isLayoutApp { return "Updates keep this app’s identity and private data." }
        return switch phase {
        case .available, .idle: "Read what’s new. Install when you’re ready."
        case .downloading: "Installation will wait for your confirmation."
        case .verifying: "Nothing has changed in your installed app."
        case .ready: "Finish any running commands before relaunching."
        case .installing: "Slate will use its normal quit checks."
        case .downloadError, .verificationError, .checkError: "Your current app is still available."
        case .current: "No update is needed."
        case .unavailable, .checking: "You can keep using Slate Terminal."
        }
    }

    private var primaryTitle: String {
        if controller.isLayoutApp && phase == .ready { return "Restart to Update" }
        return switch phase {
        case .idle: "Check for Updates"
        case .available: "Download Update"
        case .downloading: "Downloading…"
        case .verifying: "Verifying…"
        case .ready: "Install and Relaunch"
        case .installing: controller.canRetryInstallation ? "Install and Relaunch" : "Installing…"
        case .downloadError: "Try Again"
        case .verificationError, .checkError: "Check Again"
        case .checking: "Checking…"
        case .unavailable, .current: "Done"
        }
    }

    private var secondaryTitle: String? {
        switch phase {
        case .unavailable, .current: nil
        case .downloading: "Cancel Download"
        case .verifying, .checking: "Cancel"
        case .ready: "Later"
        case .verificationError, .checkError, .installing: "Close"
        default: "Not Now"
        }
    }

    private var primaryDisabled: Bool {
        switch phase {
        case .available, .downloadError: !controller.canDownload
        case .checking, .downloading, .verifying: true
        case .installing: !controller.canRetryInstallation
        default: false
        }
    }

    private func primaryAction() {
        switch phase {
        case .available, .downloadError: controller.invoke(.download)
        case .ready, .installing: controller.invoke(.install)
        case .idle, .verificationError, .checkError: controller.invoke(.check)
        case .unavailable, .current: controller.hideWindow()
        case .checking, .downloading, .verifying: break
        }
    }

    private var downloadAmount: String {
        let received = formatBytes(snapshot.receivedBytes)
        return snapshot.expectedBytes > 0 ? "\(received) of \(formatBytes(snapshot.expectedBytes))" : "\(received) downloaded"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

@MainActor
private struct UpdateReleaseNotes: NSViewRepresentable {
    let notes: String
    let releaseID: String
    let version: String
    let close: () -> Void

    func makeNSView(context: Context) -> UpdateNotesContainer { UpdateNotesContainer() }
    func updateNSView(_ view: UpdateNotesContainer, context: Context) {
        view.textView.close = close
        view.textView.setAccessibilityLabel("Release notes for version \(version)")
        view.setNotes(notes, releaseID: releaseID)
    }
}

@MainActor
private final class UpdateNotesContainer: NSView, NSTextViewDelegate {
    let textView = UpdateNotesTextView(frame: .zero)
    private let scrollView = NSScrollView()
    private let continuation = NSButton()
    private let separator = NSBox()
    private var notes = ""
    private var releaseID: String?
    private var overflowing = false
    private var atEnd = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 18, height: 20)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        textView.setAccessibilityIdentifier("updates.notes")
        textView.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        scrollView.documentView = textView
        addSubview(scrollView)
        continuation.isBordered = false
        continuation.setButtonType(.momentaryPushIn)
        continuation.font = .systemFont(ofSize: 11)
        continuation.contentTintColor = .secondaryLabelColor
        continuation.target = self
        continuation.action = #selector(continueReading)
        continuation.setAccessibilityIdentifier("updates.more")
        continuation.setAccessibilityHelp("Scrolls the release notes without changing the update.")
        addSubview(continuation)
        separator.boxType = .separator
        separator.setAccessibilityElement(false)
        addSubview(separator)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    func setNotes(_ value: String, releaseID: String) {
        guard self.releaseID != releaseID || notes != value else { return }
        let newRelease = self.releaseID != releaseID
        self.releaseID = releaseID
        notes = value
        replaceText()
        needsLayout = true
        if newRelease {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        replaceText()
    }

    private func replaceText() {
        let selection = textView.selectedRange()
        let origin = scrollView.contentView.bounds.origin
        textView.textStorage?.setAttributedString(Self.render(notes))
        let length = (textView.string as NSString).length
        if NSMaxRange(selection) <= length { textView.setSelectedRange(selection) }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let origin = scrollView.contentView.bounds.origin
        scrollView.frame = bounds
        let width = max(1, scrollView.contentSize.width)
        textView.setFrameSize(NSSize(width: width, height: max(1, bounds.height)))
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return }
        manager.ensureLayout(for: container)
        let contentHeight = ceil(manager.usedRect(for: container).height + textView.textContainerInset.height * 2)
        overflowing = contentHeight > bounds.height + 1
        let footerHeight: CGFloat = overflowing ? 30 : 0
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - footerHeight))
        textView.setFrameSize(NSSize(width: width, height: max(scrollView.contentSize.height, contentHeight)))
        continuation.isHidden = !overflowing
        separator.isHidden = !overflowing
        continuation.frame = NSRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight)
        separator.frame = NSRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: 1)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, max(0, contentHeight - scrollView.contentSize.height))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateContinuation()
    }

    @objc private func scrolled(_ notification: Notification) { updateContinuation() }

    private func updateContinuation() {
        atEnd = scrollView.contentView.bounds.maxY >= textView.bounds.height - 1
        continuation.title = atEnd ? "Back to top ↑" : "More release notes ↓"
    }

    @objc private func continueReading() {
        let visible = scrollView.contentView.bounds
        let y = atEnd ? 0 : min(visible.minY + visible.height * 0.8, max(0, textView.bounds.height - visible.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        window?.makeFirstResponder(textView)
        updateContinuation()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, Self.allowedLink(url) { NSWorkspace.shared.open(url) }
        return true
    }

    private static func allowedLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    private static func render(_ source: String) -> NSAttributedString {
        let limit = 65_536
        let bounded = String(source.prefix(limit))
        let text = bounded.isEmpty ? "No release notes were provided for this update." : bounded
        let result = NSMutableAttributedString()
        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            var line = rawLine
            let hashes = line.prefix(while: { $0 == "#" }).count
            let heading = (1...6).contains(hashes) && line.dropFirst(hashes).first == " "
            if heading { line = String(line.dropFirst(hashes + 1)) }
            let bullet = line.hasPrefix("- ") || line.hasPrefix("* ")
            if bullet { line = "• " + line.dropFirst(2) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = heading ? 7 : 4
            paragraph.paragraphSpacingBefore = heading && index > 0 ? 14 : 0
            if bullet { paragraph.headIndent = 13 }
            let baseFont = NSFont.systemFont(ofSize: heading && hashes <= 3 ? 17 : 12, weight: heading ? .semibold : .regular)
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: baseFont, .foregroundColor: heading || bullet ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
            if let parsed = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                for run in parsed.runs {
                    var attributes = baseAttributes
                    var font = baseFont
                    if run.inlinePresentationIntent?.contains(.code) == true {
                        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                    }
                    if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    }
                    if run.inlinePresentationIntent?.contains(.emphasized) == true {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    }
                    attributes[.font] = font
                    if let link = run.link, allowedLink(link) { attributes[.link] = link }
                    result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
                }
            } else {
                result.append(NSAttributedString(string: line, attributes: baseAttributes))
            }
        }
        if source.count > limit {
            result.append(NSAttributedString(string: "\n\nRelease notes shortened for display.", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        return result
    }
}

@MainActor
private final class UpdateNotesTextView: NSTextView {
    var close: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { close?() }
}

// Integration fixtures measure the real button bounds, then deliver native mouse events.
@MainActor
private struct UpdateControlAnchor: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> UpdateControlAnchorView { UpdateControlAnchorView() }
    func updateNSView(_ view: UpdateControlAnchorView, context: Context) { view.identifier = .init(name) }
}

@MainActor
private final class UpdateControlAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
