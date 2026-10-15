import AppKit

/// Command queries, pane names and URLs are literal input, not prose. Configure
/// the shared editor before editing starts so resigning focus cannot flush data detectors.
@MainActor
final class LiteralTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { LiteralTextFieldCell.self }
        set { }
    }
}

@MainActor
final class LiteralSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { LiteralSearchFieldCell.self }
        set { }
    }
}

@MainActor
private final class LiteralTextFieldCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        (editor as? NSTextView)?.enabledTextCheckingTypes = 0
        return editor
    }
}

@MainActor
private final class LiteralSearchFieldCell: NSSearchFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        (editor as? NSTextView)?.enabledTextCheckingTypes = 0
        return editor
    }
}
