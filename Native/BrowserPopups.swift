import AppKit
import WebKit
import SlateTermCore

/// One root browser owns its complete popup tree, including private-session children.
@MainActor
final class BrowserPopups {
    private weak var root: BrowserPane?
    private var windows: [String: BrowserPopupWindow] = [:]
    private var order: [String] = []
    private let limit = 8

    init(root: BrowserPane) { self.root = root }

    var info: JSONValue {
        .array(order.compactMap { id in
            guard let popup = windows[id] else { return nil }
            var fields = popup.pane.info.object ?? [:]
            fields["popupId"] = .string(id)
            fields["openerPopupId"] = popup.openerID.map(JSONValue.string) ?? .null
            fields["openerOrigin"] = .string(popup.openerOrigin)
            return .object(fields)
        })
    }

    func pane(id: String) throws -> BrowserPane {
        guard let popup = windows[id] else {
            throw RPCFailure(code: APIError.conflict, message: "Browser popup is closed or unknown; list popups again")
        }
        return popup.pane
    }

    func open(configuration: WKWebViewConfiguration, opener: BrowserPane, openerID: String?,
              sourceFrame: WKFrameInfo, features: WKWindowFeatures) -> WKWebView? {
        guard let root, windows.count < limit else { return nil }
        if let openerID {
            guard windows[openerID]?.pane === opener else { return nil }
        } else if opener !== root { return nil }
        let id = UUID().uuidString
        // The supplied configuration preserves WebKit's opener relationship and data store.
        let pane = BrowserPane(mode: opener.mode, configuration: configuration, popupOwner: self, popupID: id)
        pane.browserConfiguration = opener.browserConfiguration
        let origin = sourceFrame.securityOrigin
        let originText: String
        if origin.host.isEmpty { originText = origin.protocol.isEmpty ? "Opaque origin" : "\(origin.protocol):" }
        else { originText = "\(origin.protocol)://\(origin.host)\(origin.port == 0 ? "" : ":\(origin.port)")" }
        let popup = BrowserPopupWindow(id: id, pane: pane, openerID: openerID,
                                       openerOrigin: originText, owner: self, features: features)
        windows[id] = popup
        order.append(id)
        popup.show()
        return pane.web
    }

    func closeDescendants(of id: String) {
        for child in order.filter({ windows[$0]?.openerID == id }) { close(id: child) }
    }

    func closeAll() {
        for id in order { close(id: id) }
    }

    func close(id: String, closeWindow: Bool = true) {
        guard let popup = windows.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        closeDescendants(of: id)
        popup.window.delegate = nil
        popup.pane.close()
        if closeWindow { popup.window.close() }
        popup.window.contentViewController = nil
    }
}

@MainActor
private final class BrowserPopupWindow: NSObject, NSWindowDelegate {
    let id: String
    let pane: BrowserPane
    let openerID: String?
    let openerOrigin: String
    let window: NSWindow
    private weak var owner: BrowserPopups?

    init(id: String, pane: BrowserPane, openerID: String?, openerOrigin: String,
         owner: BrowserPopups, features: WKWindowFeatures) {
        self.id = id
        self.pane = pane
        self.openerID = openerID
        self.openerOrigin = openerOrigin
        self.owner = owner
        let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 900)
        let width = min(max(CGFloat(features.width?.doubleValue ?? 640), 420), available.width)
        let height = min(max(CGFloat(features.height?.doubleValue ?? 640), 320), available.height)
        let popupWindow = BrowserPopupNativeWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                                   backing: .buffered, defer: false)
        popupWindow.browser = pane
        window = popupWindow
        super.init()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: min(420, available.width), height: min(320, available.height))
        window.identifier = NSUserInterfaceItemIdentifier("browser-popup-\(id)")
        window.delegate = self
        window.contentViewController = pane
        window.center()
        pane.onTitleChange = { [weak self] in self?.updateTitle() }
        pane.onLocationChange = { [weak self] in self?.updateTitle() }
        updateTitle()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(pane.web)
    }

    private func updateTitle() {
        let mode = pane.mode == .privateBrowser ? "Private Browser" : "Browser"
        window.title = "\(pane.paneTitle) — \(mode) · Opened by \(openerOrigin)"
    }

    func windowWillClose(_ notification: Notification) {
        owner?.close(id: id, closeWindow: false)
    }
}

@MainActor
private final class BrowserPopupNativeWindow: NSWindow {
    weak var browser: BrowserPane?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if key == "w" {
            performClose(nil)
            return true
        }
        let commands = ["r": "browser.reload", "l": "browser.focusAddress",
                        "[": "browser.back", "]": "browser.forward"]
        guard let command = commands[key], let browser else { return super.performKeyEquivalent(with: event) }
        do { try browser.performCommand(command) }
        catch { NSSound.beep() }
        return true
    }
}
