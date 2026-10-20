import AppKit
import WebKit
import SlateTermCore

/// Browser, plugin and popup delegates forward their actual WebKit requests here.
@MainActor
final class WebDialogs {
    private enum Kind: String {
        case alert
        case confirm
        case prompt
    }

    private struct Pending {
        let id = UUID().uuidString
        let kind: Kind
        let message: String
        let origin: String
        let defaultText: String?
        let truncated: Bool
        let alert: NSAlert
        let input: NSTextField?
        let completion: (Bool, String?) -> Void
    }

    private weak var web: WKWebView?
    private var pending: Pending?
    private var closed = false

    init(web: WKWebView) { self.web = web }

    func alert(_ message: String, frame: WKFrameInfo, completion: @escaping () -> Void) {
        present(.alert, message: message, defaultText: nil, frame: frame) { _, _ in completion() }
    }

    func confirm(_ message: String, frame: WKFrameInfo, completion: @escaping (Bool) -> Void) {
        present(.confirm, message: message, defaultText: nil, frame: frame) { accepted, _ in completion(accepted) }
    }

    func prompt(_ message: String, defaultText: String?, frame: WKFrameInfo, completion: @escaping (String?) -> Void) {
        present(.prompt, message: message, defaultText: defaultText, frame: frame) { accepted, text in
            completion(accepted ? text ?? "" : nil)
        }
    }

    func inspect() -> JSONValue {
        let dialog: JSONValue = pending.map {
            .object(["dialogId": .string($0.id), "kind": .string($0.kind.rawValue),
                     "message": .string($0.message), "origin": .string($0.origin),
                     "defaultText": $0.defaultText.map(JSONValue.string) ?? .null,
                     "truncated": .bool($0.truncated)])
        } ?? .null
        return .object(["dialog": dialog])
    }

    func respond(_ request: WebDialogRequest) throws -> JSONValue {
        guard !closed, let dialog = pending, dialog.id == request.dialogID else {
            throw RPCFailure(code: APIError.conflict, message: "Dialog is no longer pending; inspect again")
        }
        guard request.text == nil || dialog.kind == .prompt else {
            throw RPCFailure(code: -32602, message: "Text is only valid for a prompt")
        }
        let accepted = request.action == .accept
        finish(dialog.id, accepted: accepted, text: request.text ?? dialog.input?.stringValue)
        return .object(["dialogId": .string(dialog.id), "accepted": .bool(accepted)])
    }

    /// Integration tests press the actual control and receive its sheet callback.
    func respondNativelyForTesting(action: String, text: String? = nil) throws {
        guard let dialog = pending, ["accept", "dismiss"].contains(action) else {
            throw RPCFailure(code: APIError.unavailable, message: "A pending dialog and native action are required")
        }
        guard text == nil || dialog.kind == .prompt else {
            throw RPCFailure(code: -32602, message: "Text is only valid for a prompt")
        }
        if let text { dialog.input?.stringValue = text }
        let index = action == "accept" || dialog.kind == .alert ? 0 : 1
        dialog.alert.buttons[index].performClick(nil)
    }

    /// Call before navigation, process replacement or removal of the owning view.
    func cancelPending() {
        guard let dialog = pending else { return }
        finish(dialog.id, accepted: false, text: nil)
    }

    func close() {
        closed = true
        cancelPending()
    }

    private func present(_ kind: Kind, message: String, defaultText: String?, frame: WKFrameInfo,
                         completion: @escaping (Bool, String?) -> Void) {
        // Another pane may own the window's sheet. Never turn a conflict into consent.
        guard !closed, pending == nil, let window = web?.window, window.attachedSheet == nil else {
            completion(false, nil)
            return
        }
        let boundedMessage = Self.clipped(message, bytes: 16_384)
        let boundedDefault = defaultText.map { Self.clipped($0, bytes: 65_536) }
        let truncated = boundedMessage != message || boundedDefault != defaultText
        let origin = Self.origin(frame)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(origin) says:"
        alert.addButton(withTitle: "OK")
        if kind != .alert {
            let cancel = alert.addButton(withTitle: "Cancel")
            cancel.keyEquivalent = "\u{1b}"
        }
        var accessories: [NSView] = []
        if boundedMessage.count > 600 {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 160))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            text.string = boundedMessage
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            scroll.widthAnchor.constraint(equalToConstant: 380).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
            accessories.append(scroll)
        } else {
            alert.informativeText = boundedMessage
        }
        if truncated {
            alert.informativeText += "\nThis website sent more text than can be displayed. Dismiss this dialog to cancel."
        }
        var input: NSTextField?
        if kind == .prompt {
            let field = NSTextField(string: boundedDefault ?? "")
            field.setAccessibilityLabel("Response to website prompt")
            field.widthAnchor.constraint(equalToConstant: 380).isActive = true
            accessories.append(field)
            input = field
        }
        if !accessories.isEmpty {
            let stack = NSStackView(views: accessories)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 380, height: (boundedMessage.count > 600 ? 160 : 0) + (input == nil ? 0 : 32))
            alert.accessoryView = stack
        }
        let dialog = Pending(kind: kind, message: boundedMessage, origin: origin, defaultText: boundedDefault,
                             truncated: truncated, alert: alert, input: input, completion: completion)
        pending = dialog
        // Capture only the token; the pending slot owns the WebKit completion.
        let id = dialog.id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let current = self.pending, current.id == id else { return }
            self.finish(id, accepted: response == .alertFirstButtonReturn, text: current.input?.stringValue)
        }
        if let input {
            alert.window.initialFirstResponder = input
            alert.window.makeFirstResponder(input)
        }
    }

    private func finish(_ id: String, accepted: Bool, text: String?) {
        guard let dialog = pending, dialog.id == id else { return }
        // Clear before ending the sheet or invoking WebKit; either may reenter.
        pending = nil
        if let parent = dialog.alert.window.sheetParent {
            parent.endSheet(dialog.alert.window, returnCode: .cancel)
        }
        dialog.alert.window.orderOut(nil)
        dialog.completion(accepted && !closed, accepted && !closed ? text : nil)
    }

    private static func clipped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var end = text.startIndex
        var size = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let count = text[end..<next].utf8.count
            guard size + count <= bytes else { break }
            size += count
            end = next
        }
        return String(text[..<end])
    }

    private static func origin(_ frame: WKFrameInfo) -> String {
        let securityOrigin = frame.securityOrigin
        if !securityOrigin.host.isEmpty {
            let port = securityOrigin.port
            let suffix = port == 0 || (securityOrigin.protocol == "https" && port == 443)
                || (securityOrigin.protocol == "http" && port == 80) ? "" : ":\(port)"
            return "\(securityOrigin.protocol)://\(securityOrigin.host)\(suffix)"
        }
        if frame.request.url?.isFileURL == true { return "Local file" }
        return "Website with an opaque origin"
    }
}
