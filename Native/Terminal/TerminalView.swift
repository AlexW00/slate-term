import AppKit
import Carbon
import GhosttyKit
import SlateTermSettings

/// The NSView and C surface travel together between containers.
@MainActor
final class TerminalView: NSView, @MainActor NSTextInputClient, NSUserInterfaceValidations {
    struct Context: Equatable {
        struct Command: Equatable {
            let exitCode: Int?
            let durationNanoseconds: UInt64
        }
        var title: String?
        var workingDirectory: String?
        // This engine exposes command completion, but no prompt/start action to embedders.
        var isAtPrompt: Bool? = nil
        var lastCommand: Command?
        var secureInput: Bool?
    }
    private(set) var context = Context()
    enum ContextChange { case title, workingDirectory, commandFinished }

    struct FindState {
        var active = false
        var query = ""
        var total: Int?
        var selected: Int?
    }
    private(set) var findState = FindState()
    private var submittedFindQuery: String?
    var onFindChanged: ((_ focusSearch: Bool) -> Void)?
    private var findNotificationPending = false
    private var focusFindPending = false
    var onContextChange: ((Context, ContextChange) -> Void)?
    var onDesktopNotification: ((String, String) -> Void)?
    struct ClipboardConfirmation {
        enum Kind { case read, write, paste }
        let kind: Kind
        let text: String
        let requester: String?
    }
    /// Optional host UI. Complete exactly once; approval is per request, never remembered.
    var onClipboardConfirmation: ((ClipboardConfirmation, @escaping (Bool) -> Void) -> Void)?
    private var pendingConfirmation: (id: UUID, alert: NSAlert?, complete: (Bool) -> Void)?
    private var markedText = NSAttributedString(string: "")
    private var markedSelection = NSRange(location: NSNotFound, length: 0)
    private var keyTextAccumulator: [String]?
    private var tracking: NSTrackingArea?
    private var keyUpMonitor: Any?
    private var pressedModifiers = Set<UInt16>()
    private var leadSurrogate: UInt16?
    private var isClosed = false
    private(set) var isShuttingDown = false
    private(set) var previousOutput: SavedTerminalOutput?
    private var completedOutput: SavedTerminalOutput?
    private var capturedOutput: SavedTerminalOutput?
    private let sessionStartedAt = Date()
    private var shutdownCompletions: [@MainActor () -> Void] = []
    var onPreviousOutputChanged: (() -> Void)?
    var hasSelection: Bool { surface.map { ghostty_surface_has_selection($0) } ?? false }
    private let runtime: GhosttyRuntime
    let startingDirectory: String?
    private var surface: ghostty_surface_t?
    private var colorScheme: ghostty_color_scheme_e?
    // The pinned engine creates surfaces focused; track every forwarded focus update.
    private(set) var hasTerminalFocus = true
    var surfaceIdentity: UInt { surface.map { UInt(bitPattern: $0) } ?? 0 }
    var pixelSize: NSSize {
        guard let surface else { return .zero }
        let size = ghostty_surface_size(surface)
        return NSSize(width: Int(size.width_px), height: Int(size.height_px))
    }
    var cellHeight: Int { surface.map { Int(ghostty_surface_size($0).cell_height_px) } ?? 0 }
    override var acceptsFirstResponder: Bool { true }
    var onFocus: (() -> Void)?
    var onInputFocus: (() -> Void)?
    var onCloseRequest: ((Bool) -> Void)?
    var needsConfirmClose: Bool { surface.map { ghostty_surface_needs_confirm_quit($0) } ?? false }

    init(runtime: GhosttyRuntime, environment: [String: String] = [:], directory: String? = nil) throws {
        self.runtime = runtime
        self.startingDirectory = directory
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
        guard let app = runtime.app else { throw TerminalError.initialization("Runtime is closed") }
        var configuration = ghostty_surface_config_new()
        configuration.platform_tag = GHOSTTY_PLATFORM_MACOS
        configuration.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        configuration.userdata = Unmanaged.passUnretained(self).toOpaque()
        configuration.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 1)
        let startingDirectory = directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        context.workingDirectory = startingDirectory
        let workingDirectory = strdup(startingDirectory)
        defer { if let workingDirectory { free(workingDirectory) } }
        configuration.working_directory = workingDirectory.map { UnsafePointer($0) }
        let strings = environment.sorted { $0.key < $1.key }.map { (strdup($0.key)!, strdup($0.value)!) }
        defer { for (key, value) in strings { free(key); free(value) } }
        let variables = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: max(1, strings.count))
        defer { variables.deallocate() }
        for (index, pair) in strings.enumerated() {
            variables[index] = ghostty_env_var_s(key: UnsafePointer(pair.0), value: UnsafePointer(pair.1))
        }
        configuration.env_vars = variables
        configuration.env_var_count = strings.count
        surface = ghostty_surface_new(app, &configuration)
        guard surface != nil else { throw TerminalError.initialization("ghostty_surface_new failed") }
        setFocused(false)
        synchronizeGeometry()
        // AppKit omits Command-key releases from the responder chain.
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window,
                      window.firstResponder === self, event.modifierFlags.contains(.command) else { return false }
                self.keyUp(with: event)
                return true
            }
            return handled ? nil : event
        }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit { close() }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        runtime.requestSecureInput(false, for: self)
        hasTerminalFocus = false
        onCloseRequest = nil
        onContextChange = nil
        onDesktopNotification = nil
        onFindChanged = nil
        onInputFocus = nil
        onClipboardConfirmation = nil
        if let pending = pendingConfirmation { finishConfirmation(pending.id, approved: false) }
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor); self.keyUpMonitor = nil }
        markedText = NSAttributedString(string: "")
        pressedModifiers.removeAll()
        if let surface {
            self.surface = nil
            ghostty_surface_free(surface)
        }
    }

    func restoreOutput(_ output: SavedTerminalOutput?, lineLimit: Int) {
        previousOutput = output.map {
            SavedTerminalOutput(text: SavedTerminalOutput.boundedText($0.text, lineLimit: lineLimit),
                                capturedAt: $0.capturedAt, ended: $0.ended)
        }.flatMap { $0.text.isEmpty ? nil : $0 }
        onPreviousOutputChanged?()
    }

    func updateOutputLimit(_ lineLimit: Int) {
        capturedOutput = nil
        restoreOutput(previousOutput, lineLimit: lineLimit)
        if var output = completedOutput {
            output.text = SavedTerminalOutput.boundedText(output.text, lineLimit: lineLimit)
            completedOutput = output.text.isEmpty ? nil : output
        }
    }

    func clearPreviousOutput() {
        capturedOutput = nil
        previousOutput = nil
        onPreviousOutputChanged?()
    }

    func savedOutput(lineLimit: Int) -> SavedTerminalOutput? {
        guard lineLimit > 0 else { return nil }
        if let completedOutput { return completedOutput }
        return outputRecord(current: retainedText(maximumBytes: SavedTerminalOutput.maximumBytes).text,
                            lineLimit: lineLimit, ended: false)
    }

    private func outputRecord(current: String, lineLimit: Int, ended: Bool) -> SavedTerminalOutput? {
        let current = current.trimmingCharacters(in: .newlines)
        let text: String
        if let previousOutput, !previousOutput.text.isEmpty, !current.isEmpty {
            let boundary = ISO8601DateFormatter().string(from: sessionStartedAt)
            text = previousOutput.text + "\n\n── New terminal session · " + boundary + " ──\n" + current
        } else { text = current.isEmpty ? (previousOutput?.text ?? "") : current }
        let bounded = SavedTerminalOutput.boundedText(text, lineLimit: lineLimit)
        guard !bounded.isEmpty else { capturedOutput = nil; return nil }
        if let capturedOutput, capturedOutput.text == bounded, capturedOutput.ended == ended { return capturedOutput }
        let output = SavedTerminalOutput(text: bounded, capturedAt: Date(), ended: ended)
        capturedOutput = output
        return output
    }

    /// Keep the reader and terminal state alive until the process stop attempt finishes.
    func beginShutdown(lineLimit: Int, completion: @escaping @MainActor () -> Void) {
        guard !isClosed else {
            RunLoop.main.perform(inModes: [.common, .modalPanel]) { MainActor.assumeIsolated { completion() } }
            CFRunLoopWakeUp(CFRunLoopGetMain())
            return
        }
        shutdownCompletions.append(completion)
        guard !isShuttingDown else { return }
        isShuttingDown = true
        onCloseRequest = nil
        onDesktopNotification = nil
        if let pending = pendingConfirmation { finishConfirmation(pending.id, approved: false) }
        let before = lineLimit > 0 ? retainedText(maximumBytes: SavedTerminalOutput.maximumBytes).text : ""
        var ttyPath: String?
        var foreground: pid_t?
        if let surface {
            let tty = ghostty_surface_tty_name(surface)
            if let pointer = tty.ptr { ttyPath = String(bytes: UnsafeRawBufferPointer(start: pointer, count: Int(tty.len)), encoding: .utf8) }
            ghostty_string_free(tty)
            foreground = pid_t(exactly: ghostty_surface_foreground_pid(surface))
        }
        TerminalProcessShutdown.stop(ttyPath: ttyPath, foregroundPID: foreground) { [self] outcome in
            let after = lineLimit > 0 ? retainedText(maximumBytes: SavedTerminalOutput.maximumBytes).text : ""
            // Normal append-only output needs no duplicate snapshot. A TUI may replace
            // its screen on exit; retain that earlier screen as historical context too.
            let earlier = before.trimmingCharacters(in: .newlines)
            let final = after.trimmingCharacters(in: .newlines)
            let combined: String
            if earlier.isEmpty || final.hasPrefix(earlier) { combined = final }
            else if final.isEmpty || earlier == final { combined = earlier }
            else { combined = earlier + "\n\n── Output received while closing ──\n" + final }
            completedOutput = lineLimit > 0 ? outputRecord(current: combined, lineLimit: lineLimit,
                ended: outcome.status == .stopped) : nil
            if outcome.status != .stopped {
                NSLog("Terminal shutdown finished with %@ (%ld remaining attached processes)",
                      String(describing: outcome.status), outcome.remainingProcessCount)
            }
            let callbacks = shutdownCompletions
            shutdownCompletions.removeAll()
            callbacks.forEach { $0() }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        synchronizeGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronizeGeometry()
    }

    private func synchronizeGeometry() {
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(max(1, bounds.width * scale)), UInt32(max(1, bounds.height * scale)))
        if let screenID = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, screenID)
        }
        ghostty_surface_set_occlusion(surface, window != nil)
        ghostty_surface_refresh(surface)
    }

    @discardableResult
    func setColorScheme(_ scheme: ghostty_color_scheme_e) -> Bool {
        guard let surface, colorScheme != scheme else { return false }
        colorScheme = scheme
        ghostty_surface_set_color_scheme(surface, scheme)
        return true
    }

    func setFocused(_ focused: Bool) {
        runtime.requestSecureInput(focused && context.secureInput == true, for: self)
        hasTerminalFocus = focused
        if let surface { ghostty_surface_set_focus(surface, focused) }
    }

    override func becomeFirstResponder() -> Bool {
        guard surface != nil else { return false }
        setFocused(true)
        onInputFocus?()
        onFocus?()
        return true
    }

    override func resignFirstResponder() -> Bool {
        // A modifier released after a focus transfer will go to another responder.
        for code in pressedModifiers {
            var key = ghostty_input_key_s()
            key.action = GHOSTTY_ACTION_RELEASE
            key.keycode = UInt32(code)
            forwardKey(key)
        }
        pressedModifiers.removeAll()
        leadSurrogate = nil
        inputContext?.discardMarkedText()
        unmarkText()
        setFocused(false)
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = mouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }
    override func mouseUp(with event: NSEvent) {
        _ = mouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        if !isShuttingDown, let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }
    override func rightMouseDown(with event: NSEvent) {
        if !mouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT) { super.rightMouseDown(with: event) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if !mouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) { super.rightMouseUp(with: event) }
    }
    override func otherMouseDown(with event: NSEvent) { _ = mouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: otherButton(event)) }
    override func otherMouseUp(with event: NSEvent) { _ = mouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: otherButton(event)) }
    private func otherButton(_ event: NSEvent) -> ghostty_input_mouse_button_e {
        // AppKit: left=0, right=1, middle=2. Ghostty reserves zero for unknown.
        guard (2...10).contains(event.buttonNumber) else { return GHOSTTY_MOUSE_UNKNOWN }
        return ghostty_input_mouse_button_e(UInt32(event.buttonNumber + 1))
    }
    private func mouseButton(_ event: NSEvent, state: ghostty_input_mouse_state_e, button: ghostty_input_mouse_button_e) -> Bool {
        guard !isShuttingDown, let surface else { return false }
        mouseMoved(with: event)
        return ghostty_surface_mouse_button(surface, state, button, modifiers(event.modifierFlags))
    }
    override func mouseMoved(with event: NSEvent) {
        guard !isShuttingDown, let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modifiers(event.modifierFlags))
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        if !isShuttingDown, let surface, NSEvent.pressedMouseButtons == 0 { ghostty_surface_mouse_pos(surface, -1, -1, modifiers(event.modifierFlags)) }
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func scrollWheel(with event: NSEvent) {
        guard !isShuttingDown, let surface else { return }
        mouseMoved(with: event)
        let momentum: ghostty_input_mouse_momentum_e
        switch event.momentumPhase {
        case .began: momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        let mods = Int32((event.hasPreciseScrollingDeltas ? 1 : 0) | (Int(momentum.rawValue) << 1))
        let multiplier = event.hasPreciseScrollingDeltas ? 2.0 : 1.0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX * multiplier, event.scrollingDeltaY * multiplier, mods)
    }
    override func pressureChange(with event: NSEvent) {
        if !isShuttingDown, let surface { ghostty_surface_mouse_pressure(surface, UInt32(max(0, event.stage)), Double(event.pressure)) }
    }

    private func modifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var bits: UInt32 = 0
        for (flag, mod) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL),
                            (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER), (.capsLock, GHOSTTY_MODS_CAPS)] {
            if flags.contains(flag) { bits |= mod.rawValue }
        }
        // Device-side bits preserve left/right modifier identity for key protocols.
        for (mask, mod) in [(NX_DEVICERSHIFTKEYMASK, GHOSTTY_MODS_SHIFT_RIGHT), (NX_DEVICERCTLKEYMASK, GHOSTTY_MODS_CTRL_RIGHT),
                            (NX_DEVICERALTKEYMASK, GHOSTTY_MODS_ALT_RIGHT), (NX_DEVICERCMDKEYMASK, GHOSTTY_MODS_SUPER_RIGHT)] {
            if flags.rawValue & UInt(mask) != 0 { bits |= mod.rawValue }
        }
        return ghostty_input_mods_e(bits)
    }

    private func keyEvent(_ event: NSEvent, action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = modifiers(event.modifierFlags)
        key.consumed_mods = modifiers((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        if event.type == .keyDown || event.type == .keyUp {
            key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        }
        return key
    }

    @discardableResult
    private func forwardKey(_ key: ghostty_input_key_s, text: String? = nil) -> Bool {
        guard !isShuttingDown, let surface else { return false }
        var key = key
        if let text, let scalar = text.unicodeScalars.first,
           scalar.value >= 0x20, scalar.value != 0x7F, !(0xF700...0xF8FF).contains(scalar.value) {
            return text.withCString { key.text = $0; return ghostty_surface_key(surface, key) }
        }
        return ghostty_surface_key(surface, key)
    }

    override func keyDown(with event: NSEvent) {
        guard !isShuttingDown else { return }
        guard let surface else { return }
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let translated = ghostty_surface_key_translation_mods(surface, modifiers(event.modifierFlags))
        var flags = event.modifierFlags
        for (flag, mod) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL),
                            (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER)] {
            if translated.rawValue & mod.rawValue != 0 { flags.insert(flag) } else { flags.remove(flag) }
        }
        // Reuse the original event when possible; Korean IMEs depend on its identity.
        let translationEvent = flags == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: flags, timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: event.characters(byApplyingModifiers: flags) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "", isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
        let wasComposing = hasMarkedText()
        let inputSourceBefore = wasComposing ? nil : keyboardInputSourceID()
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([translationEvent])
        if !wasComposing, inputSourceBefore != keyboardInputSourceID() { return }
        syncPreedit()
        let composing = wasComposing || hasMarkedText()
        let committed = keyTextAccumulator ?? []
        if !committed.isEmpty {
            for text in committed {
                if composing, text.unicodeScalars.count == 1, (text.unicodeScalars.first?.value ?? 0) < 0x20 { continue }
                if wasComposing { commitText(text) }
                else { forwardKey(keyEvent(event, action: action, translationMods: flags), text: text) }
            }
            // Navigation may commit preedit and still need to reach the terminal.
            if wasComposing, [UInt16(126), 124, 125].contains(event.keyCode)
                || (wasComposing && event.keyCode == 123 && !flags.isDisjoint(with: [.shift, .control, .option, .command])) {
                forwardKey(keyEvent(event, action: action, translationMods: flags))
            }
            return
        }
        var text = translationEvent.characters
        if composing, text?.unicodeScalars.count == 1, (text?.unicodeScalars.first?.value ?? 0x20) < 0x20 { return }
        // Control encoding belongs to Ghostty, not AppKit's transformed ETX.
        if text?.unicodeScalars.count == 1, (text?.unicodeScalars.first?.value ?? 0x20) < 0x20 {
            text = translationEvent.characters(byApplyingModifiers: flags.subtracting(.control))
        }
        var key = keyEvent(event, action: action, translationMods: flags)
        key.composing = composing
        forwardKey(key, text: text)
    }

    private func keyboardInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    override func keyUp(with event: NSEvent) { forwardKey(keyEvent(event, action: GHOSTTY_ACTION_RELEASE)) }
    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags
        let sideMask: UInt
        switch event.keyCode {
        case 57: flag = .capsLock; sideMask = 0
        case 56: flag = .shift; sideMask = UInt(NX_DEVICELSHIFTKEYMASK)
        case 60: flag = .shift; sideMask = UInt(NX_DEVICERSHIFTKEYMASK)
        case 59: flag = .control; sideMask = UInt(NX_DEVICELCTLKEYMASK)
        case 62: flag = .control; sideMask = UInt(NX_DEVICERCTLKEYMASK)
        case 58: flag = .option; sideMask = UInt(NX_DEVICELALTKEYMASK)
        case 61: flag = .option; sideMask = UInt(NX_DEVICERALTKEYMASK)
        case 55: flag = .command; sideMask = UInt(NX_DEVICELCMDKEYMASK)
        case 54: flag = .command; sideMask = UInt(NX_DEVICERCMDKEYMASK)
        default: return
        }
        guard !hasMarkedText() else { return }
        let down = event.modifierFlags.contains(flag) && (sideMask == 0 || event.modifierFlags.rawValue & sideMask != 0)
        if down { pressedModifiers.insert(event.keyCode) } else { pressedModifiers.remove(event.keyCode) }
        forwardKey(keyEvent(event, action: down ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let surface, event.type == .keyDown else { return false }
        var key = keyEvent(event, action: GHOSTTY_ACTION_PRESS)
        let binding = (event.characters ?? "").withCString { pointer in
            key.text = pointer
            return ghostty_surface_key_is_binding(surface, key, nil)
        }
        guard binding else { return false } // Host menu shortcuts retain priority when not bound.
        keyDown(with: event)
        return true
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard surface != nil else { return }
        guard let text = inputString(value) else { return }
        markedText = NSAttributedString(string: text)
        markedSelection = selectedRange.location == NSNotFound ? NSRange(location: NSNotFound, length: 0)
            : NSIntersectionRange(selectedRange, NSRange(location: 0, length: markedText.length))
        if keyTextAccumulator == nil { syncPreedit() }
    }
    func unmarkText() {
        markedText = NSAttributedString(string: "")
        markedSelection = NSRange(location: NSNotFound, length: 0)
        syncPreedit()
    }
    private func syncPreedit() {
        guard let surface else { return }
        if hasMarkedText() { markedText.string.withCString { ghostty_surface_preedit(surface, $0, UInt(markedText.string.utf8.count)) } }
        else { ghostty_surface_preedit(surface, nil, 0) }
    }
    private func inputString(_ value: Any) -> String? {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String
    }
    func insertText(_ value: Any, replacementRange: NSRange) {
        guard !isShuttingDown, surface != nil else { return }
        let text: String
        // The emoji picker can deliver a supplementary character as two NSStrings.
        if let string = value as? NSString, string.length == 1 {
            let unit = string.character(at: 0)
            if (0xD800...0xDBFF).contains(unit) { leadSurrogate = unit; return }
            if (0xDC00...0xDFFF).contains(unit) {
                guard let lead = leadSurrogate else { return }
                leadSurrogate = nil
                let scalar = 0x10000 + (UInt32(lead - 0xD800) << 10) + UInt32(unit - 0xDC00)
                guard let unicode = UnicodeScalar(scalar) else { return }
                text = String(unicode)
            } else { leadSurrogate = nil; text = string as String }
        } else {
            leadSurrogate = nil
            guard let string = inputString(value) else { return }
            text = string
        }
        guard !text.isEmpty else { return }
        unmarkText()
        if keyTextAccumulator != nil { keyTextAccumulator?.append(text) }
        else { commitText(text) }
    }
    private func commitText(_ text: String) {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        forwardKey(key, text: text)
    }
    override func doCommand(by selector: Selector) {
        // Inside interpretation, the physical event is encoded by keyDown afterwards.
        // AppKit may dispatch Command-period here before ever sending keyDown.
        if keyTextAccumulator == nil, window?.firstResponder === self,
           let event = NSApp.currentEvent, event.type == .keyDown,
           !event.modifierFlags.isDisjoint(with: [.command, .control]) {
            keyDown(with: event)
        }
    }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard hasMarkedText(), range.location != NSNotFound else { return nil }
        let intersection = NSIntersectionRange(range, markedRange())
        guard intersection.length > 0 else { return nil }
        actualRange?.pointee = intersection
        return markedText.attributedSubstring(from: intersection)
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        actualRange?.pointee = hasMarkedText() ? markedRange() : NSRange(location: NSNotFound, length: 0)
        let rect = convert(NSRect(x: x, y: bounds.height - y, width: width, height: height), to: nil)
        return window?.convertToScreen(rect) ?? rect
    }

    @objc func copy(_ sender: Any?) { _ = bindingAction("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { _ = bindingAction("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { _ = bindingAction("select_all") }
    func bindingAction(_ action: String) -> Bool {
        guard !isShuttingDown, let surface else { return false }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }
    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return hasSelection
        case #selector(paste(_:)): return surface != nil && runtime.clipboard.availableType(from: [.string]) != nil
        case #selector(selectAll(_:)): return surface != nil
        default: return false
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if event.type == .leftMouseDown {
            guard event.modifierFlags.contains(.control), let surface, !ghostty_surface_mouse_captured(surface) else { return nil }
            _ = mouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
        } else if event.type != .rightMouseDown { return nil }
        let menu = NSMenu()
        for (title, action) in [("Copy", #selector(copy(_:))), ("Paste", #selector(paste(_:))), ("Select All", #selector(selectAll(_:)))] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    func handleAction(_ action: ghostty_action_s) -> Bool {
        // Initial metadata may arrive from inside surface_new, before it returns.
        guard !isClosed else { return false }
        let previous = context
        let change: ContextChange
        switch action.tag {
        case GHOSTTY_ACTION_START_SEARCH:
            findState.active = true
            if let needle = action.action.start_search.needle, needle.pointee != 0 { findState.query = String(cString: needle) }
            notifyFind(focus: true)
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            submittedFindQuery = nil
            findState.active = false
            findState.total = nil
            findState.selected = nil
            notifyFind()
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            findState.total = action.action.search_total.total < 0 ? nil : Int(action.action.search_total.total)
            notifyFind()
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            findState.selected = action.action.search_selected.selected < 0 ? nil : Int(action.action.search_selected.selected)
            notifyFind()
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            change = .title
            context.title = action.action.set_title.title.map { String(cString: $0) }
        case GHOSTTY_ACTION_PWD:
            change = .workingDirectory
            context.workingDirectory = action.action.pwd.pwd.map { String(cString: $0) }
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            change = .commandFinished
            let command = action.action.command_finished
            context.lastCommand = Context.Command(exitCode: command.exit_code < 0 ? nil : Int(command.exit_code), durationNanoseconds: command.duration)
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            // The callback owns borrowed C strings only until it returns.
            let title = action.action.desktop_notification.title.map { String(cString: $0) } ?? ""
            let body = action.action.desktop_notification.body.map { String(cString: $0) } ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self, self.surface != nil else { return }
                self.onDesktopNotification?(title, body)
            }
            return true
        case GHOSTTY_ACTION_SECURE_INPUT:
            switch action.action.secure_input {
            case GHOSTTY_SECURE_INPUT_ON: context.secureInput = true
            case GHOSTTY_SECURE_INPUT_OFF: context.secureInput = false
            default: context.secureInput = !(context.secureInput ?? false)
            }
            runtime.requestSecureInput(hasTerminalFocus && context.secureInput == true, for: self)
            return true // Secure-input ownership is not exposed by context.get.
        case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
            guard let title = context.title else { return false }
            runtime.clipboard.clearContents()
            return runtime.clipboard.setString(title, forType: .string)
        default: return false
        }
        // Completion is a lifecycle fact even when two commands have identical results.
        guard context != previous || action.tag == GHOSTTY_ACTION_COMMAND_FINISHED else { return true }
        // Never let a host close/free the C surface from inside an engine callback.
        let snapshot = context
        DispatchQueue.main.async { [weak self] in
            guard let self, self.surface != nil else { return }
            self.onContextChange?(snapshot, change)
        }
        return true
    }

    func requestClipboardConfirmation(_ request: ClipboardConfirmation, completion: @escaping (Bool) -> Void) {
        guard !isShuttingDown, surface != nil, pendingConfirmation == nil else { completion(false); return }
        let id = UUID()
        pendingConfirmation = (id, nil, completion)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingConfirmation?.id == id else { return }
            let finish: (Bool) -> Void = { [weak self] approved in self?.finishConfirmation(id, approved: approved) }
            if let handler = self.onClipboardConfirmation { handler(request, finish); return }
            guard let window = self.window, window.attachedSheet == nil else { finish(false); return }
            let alert = NSAlert()
            switch request.kind {
            case .read: alert.messageText = "Allow terminal to read the clipboard?"
            case .write: alert.messageText = "Allow terminal to replace the clipboard?"
            case .paste: alert.messageText = "Paste this text into the terminal?"
            }
            let preview = String(request.text.prefix(2000)) + (request.text.count > 2000 ? "\n\nPreview truncated." : "")
            alert.informativeText = "\(request.requester.map { "Requested by \($0).\n\n" } ?? "")\(preview)"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Allow Once")
            self.pendingConfirmation?.alert = alert
            alert.beginSheetModal(for: window) { response in finish(response == .alertSecondButtonReturn) }
        }
    }
    private func finishConfirmation(_ id: UUID, approved: Bool) {
        guard let pending = pendingConfirmation, pending.id == id else { return }
        pendingConfirmation = nil
        if let alert = pending.alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window) }
        pending.complete(approved)
    }

    func readClipboard(location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?, mimes: UnsafePointer<UnsafePointer<CChar>?>?, count: Int, list: Bool) -> ghostty_clipboard_read_result_e {
        guard !isShuttingDown, surface != nil, location == GHOSTTY_CLIPBOARD_STANDARD else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        var contents: [GhosttyRuntime.ClipboardContent] = []
        var seen = Set<String>()
        if let mimes {
            for index in 0..<count {
                guard let pointer = mimes[index] else { continue }
                let mime = String(cString: pointer)
                guard seen.insert(mime).inserted, let type = GhosttyRuntime.pasteboardType(mime),
                      let data = runtime.clipboard.data(forType: type) else { continue }
                contents.append(.init(mime: mime, data: data))
            }
        }
        let available = list ? (runtime.clipboard.types ?? []).compactMap { GhosttyRuntime.mimeType($0) } : []
        guard list || !contents.isEmpty else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        completeClipboard(contents: contents, available: available, state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }
    func denyClipboard(state: UnsafeMutableRawPointer?) {
        if let surface { ghostty_surface_deny_clipboard_request(surface, state) }
    }
    func confirmClipboard(_ payload: ghostty_clipboard_confirm_s, state: UnsafeMutableRawPointer?, request: ghostty_clipboard_request_e) {
        guard let surface else { return }
        let contents = GhosttyRuntime.copyClipboardContents(payload.contents, count: payload.contents_len)
        let available = payload.available.map { pointers in (0..<payload.available_len).compactMap { pointers[$0].map { String(cString: $0) } } } ?? []
        let kind: ClipboardConfirmation.Kind
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE: kind = .paste
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE, GHOSTTY_CLIPBOARD_REQUEST_KITTY_WRITE: kind = .write
        default: kind = .read
        }
        let preview = contents.isEmpty ? available.joined(separator: "\n") : clipboardPreview(contents)
        let prompt = ClipboardConfirmation(kind: kind, text: preview, requester: payload.name.map { String(cString: $0) })
        requestClipboardConfirmation(prompt) { [weak self] approved in
            guard let self, self.surface == surface else { return }
            if approved { self.completeClipboard(contents: contents, available: available, state: state, confirmed: true) }
            else { ghostty_surface_deny_clipboard_request(surface, state) }
        }
    }
    private func clipboardPreview(_ contents: [GhosttyRuntime.ClipboardContent]) -> String {
        contents.map { entry in
            entry.mime == "text/plain" ? String(decoding: entry.data, as: UTF8.self) : "\(entry.mime) (\(entry.data.count) bytes)"
        }.joined(separator: "\n")
    }
    private func completeClipboard(contents: [GhosttyRuntime.ClipboardContent], available: [String], state: UnsafeMutableRawPointer?, confirmed: Bool) {
        guard let surface else { return }
        GhosttyRuntime.withClipboardPayload(contents: contents, available: available, confirmed: confirmed) { payload in
            ghostty_surface_complete_clipboard_request(surface, payload, state)
        }
    }
    func writeClipboard(location: ghostty_clipboard_e, contents: [GhosttyRuntime.ClipboardContent], confirm: Bool) {
        guard !isShuttingDown else { return }
        guard !isShuttingDown, surface != nil, location == GHOSTTY_CLIPBOARD_STANDARD, !contents.isEmpty else { return }
        let write: (Bool) -> Void = { [weak self] approved in
            guard let self, self.surface != nil, approved else { return }
            let supported = contents.compactMap { entry -> (NSPasteboard.PasteboardType, Data)? in
                GhosttyRuntime.pasteboardType(entry.mime).map { ($0, entry.data) }
            }
            guard !supported.isEmpty else { return }
            self.runtime.clipboard.declareTypes(supported.map { $0.0 }, owner: nil)
            for (type, data) in supported { self.runtime.clipboard.setData(data, forType: type) }
        }
        if confirm { requestClipboardConfirmation(.init(kind: .write, text: clipboardPreview(contents), requester: nil), completion: write) }
        else { write(true) }
    }

    /// Send a complete logical key tap; encoding and negotiated protocols belong to Ghostty.
    func sendKey(_ key: TerminalKey) throws {
        guard !isClosed, !isShuttingDown, surface != nil else { throw TerminalKeyError.closed }
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = key.keyCode
        event.unshifted_codepoint = key.unshiftedCodepoint
        var mods: UInt32 = 0
        var consumed: UInt32 = 0
        for (modifier, bit) in [(TerminalKey.Modifier.ctrl, GHOSTTY_MODS_CTRL),
                                (.alt, GHOSTTY_MODS_ALT), (.shift, GHOSTTY_MODS_SHIFT)] {
            if key.modifiers.contains(modifier) { mods |= bit.rawValue }
            if key.consumedModifiers.contains(modifier) { consumed |= bit.rawValue }
        }
        event.mods = ghostty_input_mods_e(mods)
        event.consumed_mods = ghostty_input_mods_e(consumed)
        let accepted = forwardKey(event, text: key.text)
        event.action = GHOSTTY_ACTION_RELEASE
        // Always balance the press, even when rejected. The pinned API returns false
        // for ignored legacy releases; this is not a failed tap. Retain printable
        // text for protocols that use it to identify/report the released key.
        forwardKey(event, text: key.text)
        guard accepted else { throw TerminalKeyError.rejected }
    }

    func send(_ text: String) throws {
        guard !isShuttingDown else { throw TerminalError.initialization("Terminal is shutting down") }
        guard let surface else { throw TerminalError.inputRejected }
        guard !text.isEmpty else { return }
        // surface_text is a paste API: zsh's bracketed-paste mode deliberately
        // prevents a pasted Return from executing. Privileged CLI input is raw
        // UTF-8, so use the engine's literal text action with byte-safe escaping.
        let hex = Array("0123456789abcdef".utf8)
        var action = Array("text:".utf8)
        action.reserveCapacity(5 + text.utf8.count * 4)
        for byte in text.utf8 {
            action.append(contentsOf: [92, 120, hex[Int(byte >> 4)], hex[Int(byte & 15)]])
        }
        let encoded = String(decoding: action, as: UTF8.self)
        guard encoded.withCString({ ghostty_surface_binding_action(surface, $0, UInt(action.count)) }) else {
            throw TerminalError.inputRejected
        }
    }

    override func accessibilityValue() -> Any? { capture() }

    func showFind() { _ = bindingAction("start_search") }

    func search(_ query: String) throws {
        guard query.utf8.count <= 4_096, !query.utf8.contains(0), surface != nil else { throw TerminalError.inputRejected }
        // The pinned search thread ignores ASCII-case-equivalent needles and
        // emits no new counts. Preserve settled results when merely refocusing
        // or resubmitting the same search instead of showing a permanent spinner.
        func folded(_ value: String) -> [UInt8] { value.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 } }
        let changed = submittedFindQuery.map { folded($0) != folded(query) } ?? true
        let accepted = bindingAction("search:" + query)
        guard accepted || query.isEmpty else { throw TerminalError.inputRejected }
        submittedFindQuery = query.isEmpty ? nil : query
        findState.active = true
        findState.query = query
        if changed {
            findState.total = nil
            findState.selected = nil
        }
        notifyFind()
    }

    func navigateSearch(previous: Bool) {
        guard findState.active, !findState.query.isEmpty else { return }
        _ = bindingAction(previous ? "navigate_search:previous" : "navigate_search:next")
    }

    func endSearch() {
        submittedFindQuery = nil
        _ = bindingAction("end_search")
        findState.active = false
        findState.total = nil
        findState.selected = nil
        notifyFind()
    }

    private func notifyFind(focus: Bool = false) {
        focusFindPending = focusFindPending || focus
        guard !findNotificationPending else { return }
        findNotificationPending = true
        // Engine callbacks borrow their surface. Layout/focus changes wait until
        // the callback unwinds; the UI reads the newest coalesced search state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.findNotificationPending = false
            let focus = self.focusFindPending
            self.focusFindPending = false
            guard !self.isClosed else { return }
            self.onFindChanged?(focus)
        }
    }

    func capture() -> String { readText(history: false, maximumBytes: Int.max).text }

    func retainedText(maximumBytes: Int) -> (text: String, truncated: Bool) {
        readText(history: true, maximumBytes: maximumBytes)
    }

    private func readText(history: Bool, maximumBytes: Int) -> (text: String, truncated: Bool) {
        guard let surface else { return ("", false) }
        var text = ghostty_text_s()
        // In the pinned engine SCREEN means all retained rows; ACTIVE means the
        // live screen independently of the user's current scroll position.
        let tag = history ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_ACTIVE
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return ("", false) }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return ("", false) }
        let buffer = UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len))
        var start = max(0, buffer.count - max(0, maximumBytes))
        while start < buffer.count, buffer[start] & 0xC0 == 0x80 { start += 1 }
        return (String(decoding: buffer[start...], as: UTF8.self), start > 0)
    }
}
