import AppKit
import Carbon
import Foundation
import GhosttyKit

/// Standalone native runtime gate. No user configuration, persistence, or shell rc files.
@main
struct TerminalLifecycle {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = LifecycleDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class LifecycleDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime?
    private var windows: [NSWindow] = []
    private var terminal: TerminalView?
    private var keyboardMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Test input is delivered directly to the owned view, never from the user's keyboard.
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { _ in nil }
        Task { @MainActor in
            do {
                try await verify()
                print("PASS terminal lifecycle: real PTY, IME commit, clipboard security, context, mouse, retained surface, resize, reparent, native tabs, Ctrl-C, cleanup")
                shutdown()
                exit(0)
            } catch {
                fputs("FAIL terminal lifecycle: \(error)\n", stderr)
                shutdown()
                exit(1)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { runtime?.setFocused(true) }
    func applicationDidResignActive(_ notification: Notification) { runtime?.setFocused(false) }

    private func verify() async throws {
        let configuration = FileManager.default.temporaryDirectory.appendingPathComponent("slate-terminal-\(UUID().uuidString).conf")
        try "command = /bin/sh --noprofile --norc\nwait-after-command = false\nwindow-padding-x = 0\nwindow-padding-y = 0\n".write(to: configuration, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: configuration) }
        let clipboard = NSPasteboard(name: NSPasteboard.Name("slate-terminal-gate-\(UUID().uuidString)"))
        defer { clipboard.releaseGlobally() }
        let runtime = try GhosttyRuntime(configurationURL: configuration, clipboard: clipboard)
        self.runtime = runtime
        let unsafeConfiguration = configuration.deletingLastPathComponent().appendingPathComponent("slate-unsafe-\(UUID().uuidString).conf")
        try "clipboard-read = allow\n".write(to: unsafeConfiguration, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: unsafeConfiguration) }
        do {
            try runtime.reload(from: unsafeConfiguration)
            throw Failure(message: "Unsafe clipboard-read policy was accepted")
        } catch let error as TerminalError {
            try require(error.description.contains("clipboard-read"), "Unexpected configuration rejection: \(error)")
        }
        let terminal = try TerminalView(runtime: runtime, environment: ["HISTFILE": "/dev/null", "ENV": "/dev/null", "BASH_ENV": "/dev/null"])
        self.terminal = terminal
        let originalSurface = terminal.surfaceIdentity
        let first = makeWindow(title: "Slate Terminal — lifecycle gate", origin: NSPoint(x: 100, y: 160))
        first.contentView = terminal
        first.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        first.makeFirstResponder(terminal)
        try terminal.send("stty -echo; printf '%s%s:%s\\n' 'SLATE_' 'BEFORE' \"$$\"\r")
        try await waitFor("initial shell output") { terminal.capture().contains("SLATE_BEFORE:") }
        let before = terminal.capture()
        let pid = try shellPID(before)
        try require(kill(pid, 0) == 0, "Shell PID is not alive")
        print("PASS initial shell PID \(pid), surface \(originalSurface)")

        let split = NSSplitViewController()
        first.contentView = nil
        let sibling = NSViewController()
        sibling.view = NSView()
        let leaf = NSViewController()
        leaf.view = terminal
        split.addSplitViewItem(NSSplitViewItem(viewController: sibling))
        split.addSplitViewItem(NSSplitViewItem(viewController: leaf))
        split.splitView.isVertical = true
        first.contentViewController = split
        first.contentView?.layoutSubtreeIfNeeded()
        first.makeFirstResponder(terminal)
        try terminal.send("printf '%s%s\\n' 'SLATE_' 'SPLIT'\r")
        try await waitFor("output after moving into NSSplitViewController") { terminal.capture().contains("SLATE_SPLIT") }
        try require(terminal.surfaceIdentity == originalSurface, "Split replaced the surface")

        let previousSize = terminal.pixelSize
        first.setContentSize(NSSize(width: 1100, height: 650))
        first.contentView?.layoutSubtreeIfNeeded()
        try await waitFor("resize propagation") {
            let scale = first.backingScaleFactor
            return terminal.pixelSize != previousSize
                && terminal.pixelSize.width == floor(terminal.bounds.width * scale)
                && terminal.pixelSize.height == floor(terminal.bounds.height * scale)
        }
        let second = makeWindow(title: "Slate Terminal — reattached", origin: NSPoint(x: 180, y: 220))
        split.removeSplitViewItem(split.splitViewItems[1])
        terminal.removeFromSuperview()
        second.contentView = terminal
        second.makeKeyAndOrderFront(nil)
        second.makeFirstResponder(terminal)
        first.addTabbedWindow(second, ordered: .above)
        try require(second.tabbedWindows?.count == 2, "Native window tab grouping failed")
        try terminal.send("printf '%s%s:%s\\n' 'SLATE_' 'AFTER' \"$$\"\r")
        try await waitFor("output after native window move") { terminal.capture().contains("SLATE_AFTER:\(pid)") }
        try require(terminal.surfaceIdentity == originalSurface, "Window move replaced the surface")
        try require(second.firstResponder === terminal, "Terminal lost first responder")
        try require(terminal.capture().contains("SLATE_BEFORE:\(pid)"), "Scrollback was lost")
        try await verifyEmbedding(terminal, clipboard: clipboard, window: second)

        second.tabGroup?.removeWindow(second)
        second.makeKeyAndOrderFront(nil)
        try terminal.send("printf '%s%s\\n' 'SLATE_' 'DETACHED'\r")
        try await waitFor("output after native tab detach") { terminal.capture().contains("SLATE_DETACHED") }
        try require(terminal.surfaceIdentity == originalSurface, "Detach replaced the surface")
        // Let the foreground child acknowledge SIGINT itself. A command typed
        // immediately after Ctrl-C can be discarded by the tty's signal flush.
        let sleeper = #"/bin/sh -c 'trap "printf \"SLATE_%s\\n\" INTERRUPTED; exit 0" INT; printf "SLATE_%s\n" SLEEPING; sleep 30'"#
        try terminal.send(sleeper + "\r")
        try await waitFor("foreground sleep") { terminal.capture().contains("SLATE_SLEEPING") }
        let interrupt = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
                                         windowNumber: second.windowNumber, context: nil, characters: "\u{03}",
                                         charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        terminal.keyDown(with: interrupt)
        try await waitFor("native Ctrl-C interrupts the child") { terminal.capture().contains("SLATE_INTERRUPTED") }
        try captureWindow(second)
        var lateApproval: ((Bool) -> Void)?
        terminal.onClipboardConfirmation = { _, complete in lateApproval = complete }
        clipboard.clearContents()
        clipboard.setString("close-snapshot", forType: .string)
        try terminal.send("printf '\\033]52;c;?\\007'\r")
        try await waitFor("pending clipboard confirmation before close") { lateApproval != nil }
        terminal.close()
        lateApproval?(true)
        try require(terminal.surfaceIdentity == 0 && !terminal.hasMarkedText(), "Closed terminal retained native input state")
        try require(clipboard.string(forType: .string) == "close-snapshot", "Late confirmation mutated clipboard after close")
        try await waitFor("PTY child termination") { kill(pid, 0) == -1 && errno == ESRCH }
    }

    private func verifyEmbedding(_ terminal: TerminalView, clipboard: NSPasteboard, window: NSWindow) async throws {
        try require(terminal.context.isAtPrompt == nil, "Invented prompt status without an engine callback")
        var contextChanges = 0
        terminal.onContextChange = { _ in contextChanges += 1 }
        try terminal.send("printf '\\033]0;Slate engine title\\007\\033]7;file://localhost/tmp\\007\\033]133;C\\007'; sleep 0.1; printf '\\033]133;D;7\\007'; printf 'SLATE_%s\\n' CONTEXT\r")
        try await waitFor("engine title/cwd/command callbacks") {
            terminal.context.title == "Slate engine title"
                && terminal.context.workingDirectory == "/tmp"
                && terminal.context.lastCommand?.exitCode == 7
        }
        try await waitFor("context publication") { contextChanges >= 3 }
        try require((terminal.context.lastCommand?.durationNanoseconds ?? 0) > 0, "Engine command duration missing")
        try require(terminal.context.isAtPrompt == nil, "Inferred prompt state from command completion")
        try await waitFor("owned application is active for secure-input checks") { NSApp.isActive }
        var secure = ghostty_action_s()
        secure.tag = GHOSTTY_ACTION_SECURE_INPUT
        // This fixture uses stty -echo; Ghostty may already have requested secure
        // input. Establish an explicit off baseline before exercising ownership.
        secure.action.secure_input = GHOSTTY_SECURE_INPUT_OFF
        _ = terminal.handleAction(secure)
        try require(runtime?.secureInputEnabled == false, "Secure-input baseline did not release our claim")
        secure.action.secure_input = GHOSTTY_SECURE_INPUT_ON
        try require(terminal.handleAction(secure), "Secure-input action was rejected")
        try require(runtime?.secureInputEnabled == true && IsSecureEventInputEnabled(), "Focused terminal did not enable secure event input")
        terminal.setFocused(false)
        // The global query can change when another application releases its own
        // secure-input claim. Assert our successfully balanced Carbon calls instead.
        try require(runtime?.secureInputEnabled == false, "Unfocused terminal retained secure input")
        terminal.setFocused(true)
        secure.action.secure_input = GHOSTTY_SECURE_INPUT_OFF
        _ = terminal.handleAction(secure)
        try require(runtime?.secureInputEnabled == false, "Secure-input disable was not balanced")
        try require((terminal.accessibilityValue() as? String)?.contains("SLATE_CONTEXT") == true, "Terminal text is unavailable to accessibility clients")

        let unknown = NSRange(location: NSNotFound, length: 0)
        terminal.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: unknown)
        try require(terminal.hasMarkedText() && terminal.markedRange().length == 2, "IME preedit not retained in UTF-16")
        try require(terminal.firstRect(forCharacterRange: terminal.markedRange(), actualRange: nil).height > 0, "IME anchor missing")
        terminal.unmarkText()
        try require(!terminal.hasMarkedText(), "IME cancellation did not clear preedit")
        terminal.insertText("printf 'SLATE_%s\\n' '日本語", replacementRange: unknown)
        var lead: unichar = 0xD83D, trail: unichar = 0xDE00
        terminal.insertText(NSString(characters: &lead, length: 1), replacementRange: unknown)
        terminal.insertText(NSString(characters: &trail, length: 1), replacementRange: unknown)
        terminal.insertText("'", replacementRange: unknown)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        terminal.keyDown(with: enter)
        try await waitFor("committed Unicode input executes without paste framing") { terminal.capture().contains("SLATE_日本語😀") }

        terminal.selectAll(nil)
        try require(terminal.hasSelection, "Engine select-all did not select text")
        terminal.copy(nil)
        try require(clipboard.string(forType: .string)?.contains("SLATE_日本語😀") == true, "Copy did not use engine selection")
        clipboard.clearContents()
        clipboard.setString("printf 'SLATE_%s\\n' PASTED", forType: .string)
        terminal.paste(nil)
        terminal.keyDown(with: enter)
        try await waitFor("native paste callback") { terminal.capture().contains("SLATE_PASTED") }

        terminal.selectAll(nil)
        try require(terminal.hasSelection, "Mouse regression requires a prior engine selection")
        // Drive this view directly; never synthesize a global UI event.
        let point = NSPoint(x: terminal.bounds.midX, y: terminal.bounds.midY)
        let location = terminal.convert(point, to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 2,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 3,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        terminal.mouseDown(with: down)
        terminal.mouseUp(with: up)
        try require(!terminal.hasSelection, "Mouse click did not clear engine selection")
        try require(window.firstResponder === terminal, "Mouse click lost terminal focus")
        terminal.onContextChange = nil
        try await verifyProtocolInput(terminal, clipboard: clipboard, window: window)
    }

    private func verifyProtocolInput(_ terminal: TerminalView, clipboard: NSPasteboard, window: NSWindow) async throws {
        // Exact PTY bytes prove release/modifier forwarding, not just that handlers exist.
        let keys = "\u{1b}[9u\u{1b}[9;1:3u\u{1b}[57441;2u\u{1b}[57441;1:3u"
        try await startByteRead(terminal, tag: "KEYS", count: keys.utf8.count, enable: "\\033[>11u", disable: "\\033[<u")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 4,
                                        windowNumber: window.windowNumber, context: nil, characters: "\t",
                                        charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
            if type == .keyDown { terminal.keyDown(with: event) } else { terminal.keyUp(with: event) }
        }
        for flags in [NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | UInt(NX_DEVICELSHIFTKEYMASK)), []] {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 5,
                                        windowNumber: window.windowNumber, context: nil, characters: "",
                                        charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
            terminal.flagsChanged(with: event)
        }
        try await requireBytes(terminal, tag: "KEYS", expected: keys)

        let taps = "\u{1b}[9u\u{1b}[9;1:3u\u{1b}[98;5u\u{1b}[98;5:3u"
        try await startByteRead(terminal, tag: "TAPS", count: taps.utf8.count, enable: "\\033[>11u", disable: "\\033[<u")
        try terminal.sendKey(TerminalKey(parsing: "tab"))
        try terminal.sendKey(TerminalKey(parsing: "ctrl+b"))
        try await requireBytes(terminal, tag: "TAPS", expected: taps)
        let legacy = "\u{1b}OA\u{1b}[Z\u{02}!"
        try await startByteRead(terminal, tag: "LEGACY", count: legacy.utf8.count, enable: "\\033[?1h", disable: "\\033[?1l")
        for key in ["up", "shift+tab", "ctrl+b", "shift+1"] { try terminal.sendKey(TerminalKey(parsing: key)) }
        try await requireBytes(terminal, tag: "LEGACY", expected: legacy)
        print("PASS generic key taps: actual PTY bytes for Kitty press/release, application arrows, Shift-Tab, Ctrl-B and shifted text")

        let mouse = "\u{1b}[<0;1;1M\u{1b}[<0;1;1m\u{1b}[<2;1;1M\u{1b}[<2;1;1m"
        try await startByteRead(terminal, tag: "MOUSE", count: mouse.utf8.count,
                                enable: "\\033[?1000h\\033[?1006h", disable: "\\033[?1000l\\033[?1006l")
        let location = terminal.convert(NSPoint(x: 1, y: terminal.bounds.height - 1), to: nil)
        let controlClick = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: .control, timestamp: 6,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0)!
        try require(terminal.menu(for: controlClick) == nil, "Control-click was stolen from terminal mouse reporting")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 6,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0)!
            switch type {
            case .leftMouseDown: terminal.mouseDown(with: event)
            case .leftMouseUp: terminal.mouseUp(with: event)
            case .rightMouseDown: terminal.rightMouseDown(with: event)
            default: terminal.rightMouseUp(with: event)
            }
        }
        try await requireBytes(terminal, tag: "MOUSE", expected: mouse)

        // OSC 52 requires an empty reply on denial, not silence. Consume the
        // entire response in a raw reader, never in an interactive shell prompt.
        clipboard.clearContents()
        clipboard.setString("secret", forType: .string)
        var denied = false
        terminal.onClipboardConfirmation = { _, complete in denied = true; complete(false) }
        let denial = "\u{1b}]52;c;\u{1b}\\"
        try await startByteRead(terminal, tag: "DENY", count: denial.utf8.count, enable: "\\033]52;c;?\\007", disable: "")
        try await waitFor("denial callback") { denied }
        try await requireBytes(terminal, tag: "DENY", expected: denial)
        try require(clipboard.string(forType: .string) == "secret", "Denied read mutated clipboard")

        // Approval must use the displayed snapshot even if the clipboard changes meanwhile.
        let response = "\u{1b}]52;c;\(Data("secret".utf8).base64EncodedString())\u{1b}\\"
        terminal.onClipboardConfirmation = { request, complete in
            clipboard.clearContents()
            clipboard.setString("replacement", forType: .string)
            complete(request.kind == .read && request.text == "secret")
        }
        try await startByteRead(terminal, tag: "APPROVE", count: response.utf8.count, enable: "\\033]52;c;?\\007", disable: "")
        try await requireBytes(terminal, tag: "APPROVE", expected: response)
        terminal.onClipboardConfirmation = nil

        // Paste framing must come from Ghostty, including multiline Unicode payloads.
        let payload = "a\n日本語"
        clipboard.clearContents()
        clipboard.setString(payload, forType: .string)
        let pasted = "\u{1b}[200~a\n日本語\u{1b}[201~"
        try await startByteRead(terminal, tag: "BRACKET", count: pasted.utf8.count, enable: "\\033[?2004h", disable: "\\033[?2004l")
        terminal.paste(nil)
        try await requireBytes(terminal, tag: "BRACKET", expected: pasted)
    }

    private func startByteRead(_ terminal: TerminalView, tag: String, count: Int, enable: String, disable: String) async throws {
        try terminal.send("stty raw -echo; printf '\(enable)'; printf '\\r\\nSLATE_%s_READY\\r\\n' '\(tag)'; printf 'SLATE_%s_BYTES:' '\(tag)'; /bin/dd bs=1 count=\(count) 2>/dev/null | /usr/bin/od -An -tx1 | /usr/bin/tr -d ' \\n'; printf '\(disable)'; stty sane -echo; printf '\\r\\nSLATE_%s_DONE\\r\\n' '\(tag)'\r")
        try await waitFor("\(tag) reader readiness") { terminal.capture().contains("SLATE_\(tag)_READY") }
    }

    private func requireBytes(_ terminal: TerminalView, tag: String, expected: String) async throws {
        try await waitFor("\(tag) byte capture") { terminal.capture().contains("SLATE_\(tag)_DONE") }
        let hex = expected.utf8.map { String(format: "%02x", $0) }.joined()
        try require(terminal.capture().contains("SLATE_\(tag)_BYTES:\(hex)"), "\(tag) PTY bytes differed: \(terminal.capture())")
    }

    private func makeWindow(title: String, origin: NSPoint) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 900, height: 560)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "slate-term-lifecycle"
        windows.append(window)
        return window
    }

    private func shellPID(_ text: String) throws -> Int32 {
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("SLATE_BEFORE:") }),
              let pid = Int32(line.dropFirst("SLATE_BEFORE:".count).trimmingCharacters(in: .whitespaces)), pid > 1 else {
            throw Failure(message: "No shell PID in captured terminal output: \(text)")
        }
        return pid
    }

    private func waitFor(_ label: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(message: "Timed out: \(label)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private func captureWindow(_ window: NSWindow) throws {
        guard let path = ProcessInfo.processInfo.environment["SLATE_TERM_TEST_SCREENSHOT"] else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), path]
        try process.run()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "Screenshot unavailable; visual gate remains unverified")
    }

    private func shutdown() {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        terminal?.close()
        terminal = nil
        windows.forEach { $0.close() }
        windows = []
        runtime?.close()
        runtime = nil
    }

    private struct Failure: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }
}
