import AppKit
import SlateTermCore

/// Production welcome/chrome, with a retained responder in place of Ghostty. Does
/// not activate the app or expose a window; captures only this owned view hierarchy.
@main struct WelcomeGate {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let controller = NSViewController()
        let terminal = TerminalFixture()
        controller.view = terminal
        let pane = PaneContainer(content: controller, type: "Terminal", typeID: "terminal", showWelcome: true)
        pane.setTitle("Terminal")
        pane.onFocus = { window.makeFirstResponder(terminal) }
        var inserted: [String] = []
        pane.onInsertWelcomeCommand = {
            inserted.append(WelcomeContent.readCommand)
            window.makeFirstResponder(terminal)
        }
        window.contentViewController = pane
        window.makeFirstResponder(terminal)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func require(_ ok: @autoclosure () -> Bool, _ message: String) throws {
            if !ok() { throw NSError(domain: message, code: 1) }
        }
        func settle() {
            pane.view.needsLayout = true
            pane.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            pane.view.layoutSubtreeIfNeeded()
        }
        func size(_ width: CGFloat, _ height: CGFloat) {
            window.setContentSize(NSSize(width: width, height: height))
            settle()
        }
        func capture(_ name: String) throws {
            settle()
            guard let bitmap = pane.view.bitmapImageRepForCachingDisplay(in: pane.view.bounds) else {
                throw NSError(domain: "No native bitmap", code: 1)
            }
            pane.view.cacheDisplay(in: pane.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            size(800, 500)
            try require(pane.welcomeVisible, "Welcome missing")
            try require(terminal.bounds.height >= 236, "Welcome consumed over half of terminal area")
            try capture(name)
        }
        try pane.clickWelcomeInsertForTesting()
        try require(inserted == [WelcomeContent.readCommand], "Button must insert the displayed command exactly once")
        try require(!inserted[0].contains("\n") && !inserted[0].contains("\r"), "Insert must not submit the command")
        try require(pane.welcomeVisible && window.firstResponder === terminal, "Insert must retain welcome and focus terminal")
        size(320, 420)
        try require(pane.welcomeVisible && terminal.bounds.width == 320, "Narrow welcome pushed pane width")
        try require(terminal.bounds.height >= 196, "Narrow terminal height lost")
        let narrowWelcome = pane.view.subviews.compactMap { $0 as? WelcomeView }.first!
        try require(narrowWelcome.documentView!.bounds.height <= narrowWelcome.contentSize.height + 0.5,
                    "The command and insert button must fit the 320-point welcome without clipping")
        try capture("narrow")
        // Scrolling is local to native welcome content, independent of terminal input.
        size(200, 260)
        let welcome = pane.view.subviews.compactMap { $0 as? WelcomeView }.first!
        try require(!welcome.acceptsFirstResponder, "Welcome must not accept keyboard focus")
        let insertButton = welcome.documentView!.subviews.compactMap { $0 as? NSButton }.first!
        try require(insertButton.isEnabled && insertButton.frame.maxX <= welcome.documentView!.bounds.width,
                    "Insert button must remain enabled and inside narrow content")
        try require(welcome.documentView!.bounds.height > welcome.contentSize.height, "Overflow fixture did not need scrolling")
        try require(welcome.scrollerStyle == .legacy && welcome.verticalScroller?.isHidden == false,
                    "Overflow must retain a visible scrolling affordance")
        try require(welcome.verticalScroller?.isEnabled == true && welcome.verticalScroller?.knobStyle == .light,
                    "Dark overflow needs an enabled contrasting scroller")
        try capture("overflow")
        window.appearance = NSAppearance(named: .aqua)
        settle()
        try require(welcome.verticalScroller?.knobStyle == .dark, "Light overflow needs a contrasting scroller")
        try capture("overflow-light")
        window.appearance = NSAppearance(named: .darkAqua)
        settle()
        welcome.documentView?.scroll(NSPoint(x: 0, y: 1000))
        settle()
        try require(welcome.contentView.bounds.minY > 0, "Native welcome did not scroll")
        try capture("narrow-scrolled")
        size(80, 80)
        try require(!pane.welcomeVisible && terminal.bounds.height >= 52, "Tiny pane must favor the terminal")
        size(800, 500)
        let withHeader = terminal.bounds.height
        pane.setHeaderVisible(false)
        settle()
        try require(pane.welcomeVisible, "Hiding pane header hid welcome")
        try require(terminal.bounds.height >= withHeader, "Hiding header reduced terminal")
        try capture("header-hidden")
        let height = terminal.bounds.height
        pane.dismissWelcome()
        settle()
        try require(!pane.welcomeVisible && terminal.bounds.height > height, "Dismissal did not recover terminal space")
        insertButton.performClick(nil)
        try require(!insertButton.isEnabled && inserted.count == 1, "Dismissed button must not insert again")
        try require(pane.content === controller && pane.content.view === terminal, "Terminal identity replaced")
        try require(window.firstResponder === terminal, "Dismissal stole keyboard focus")
        try require(terminal.bounds.height == pane.view.bounds.height, "Dismissed welcome left blank space")
        try capture("dismissed")
        pane.dismissWelcome()
        settle()
        try require(terminal.bounds.height == pane.view.bounds.height, "Repeated dismissal changed geometry")
        let browserContent = NSViewController()
        browserContent.view = NSView()
        let browser = PaneContainer(content: browserContent, type: "Browser", typeID: "browser", showWelcome: true)
        browser.view.layoutSubtreeIfNeeded()
        try require(!browser.welcomeVisible, "Welcome appeared in non-terminal pane")
        print("PASS native welcome: retained responder/identity, narrow/tiny geometry, local scrolling, hidden header, dismissal and light/dark captures")
    }
}

@MainActor private final class TerminalFixture: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        ("~ ❯ " as NSString).draw(at: NSPoint(x: 12, y: bounds.height - 28), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.textColor
        ])
    }
}
