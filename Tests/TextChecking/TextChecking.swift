import AppKit

@main
struct TextCheckingGate {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let literal = "https://example.test/日本語?q=copy --literal ‘text’"
        for field in [LiteralTextField(string: ""), LiteralSearchField()] {
            field.frame = NSRect(x: 10, y: 10, width: 380, height: 24)
            window.contentView!.addSubview(field)
            guard let editor = window.fieldEditor(true, for: field) as? NSTextView else {
                throw NSError(domain: "Window did not create a field editor", code: 1)
            }
            // A window reuses its editor, including flags inherited from previous controls or preferences.
            editor.enabledTextCheckingTypes = NSTextCheckingAllTypes
            guard editor.isAutomaticDataDetectionEnabled, editor.isAutomaticLinkDetectionEnabled else {
                throw NSError(domain: "Fixture did not enable the data-detector precondition", code: 1)
            }
            guard window.makeFirstResponder(field), field.currentEditor() === editor,
                  editor.isFieldEditor, editor.enabledTextCheckingTypes == 0,
                  !editor.isAutomaticDataDetectionEnabled, !editor.isAutomaticLinkDetectionEnabled else {
                throw NSError(domain: "Literal input must disable text checking before the shared editor starts", code: 1)
            }
            editor.insertText(literal, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            guard window.makeFirstResponder(nil), field.stringValue == literal else {
                throw NSError(domain: "Literal input must commit unchanged when the editor resigns focus", code: 1)
            }
            field.removeFromSuperview()
        }
        print("PASS literal text/search editing: inherited data detectors disabled before focus, shared editor retained, Unicode input committed unchanged on resignation (no visible windows)")
    }
}
