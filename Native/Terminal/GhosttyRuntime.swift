import AppKit
import Carbon
import GhosttyKit

@MainActor
final class GhosttyRuntime {
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var colorScheme: ghostty_color_scheme_e?
    private var keyboardObserver: (any NSObjectProtocol)?
    private static weak var current: GhosttyRuntime?
    private static var initialized = false
    let clipboard: NSPasteboard
    private weak var secureInputOwner: TerminalView?
    private(set) var secureInputEnabled = false

    init(configurationURL: URL? = nil, clipboard: NSPasteboard = .general) throws {
        self.clipboard = clipboard
        guard Self.current == nil else { throw TerminalError.initialization("Only one Ghostty runtime is allowed") }
        if !Self.initialized {
            guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
                throw TerminalError.initialization("ghostty_init failed")
            }
            Self.initialized = true
        }
        guard let config = ghostty_config_new() else { throw TerminalError.initialization("No Ghostty configuration") }
        self.config = config
        // Do not read the user's Ghostty config. Slate Terminal owns its configuration.
        if let configurationURL { configurationURL.path.withCString { ghostty_config_load_file(config, $0) } }
        ghostty_config_finalize(config)
        guard ghostty_config_diagnostics_count(config) == 0, Self.hasSafeClipboardPolicy(config) else {
            ghostty_config_free(config)
            self.config = nil
            throw TerminalError.initialization("Invalid terminal configuration (clipboard-read must be ask or deny)")
        }
        var callbacks = ghostty_runtime_config_s()
        callbacks.wakeup_cb = { _ in
            // Wakeups originate on Ghostty worker threads. Never carry an unretained
            // native pointer across this hop; shutdown can run before the callback.
            DispatchQueue.main.async { GhosttyRuntime.current?.tick() }
        }
        // The pinned embedder invokes these from main-thread key handling/app_tick.
        // Resolve borrowed userdata synchronously; asynchronous work retains only Swift data.
        callbacks.action_cb = { _, target, action in
            MainActor.assumeIsolated {
                guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
                      let userdata = ghostty_surface_userdata(surface) else { return false }
                return Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue().handleAction(action)
            }
        }
        callbacks.read_clipboard_cb = { userdata, location, state, mimes, count, list in
            MainActor.assumeIsolated {
                guard let userdata else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
                return Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue().readClipboard(
                    location: location, state: state, mimes: mimes, count: count, list: list)
            }
        }
        callbacks.confirm_read_clipboard_cb = { userdata, confirm, state, request in
            MainActor.assumeIsolated {
                guard let userdata else { return }
                let view = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                guard let confirm else { view.denyClipboard(state: state); return }
                view.confirmClipboard(confirm.pointee, state: state, request: request)
            }
        }
        callbacks.write_clipboard_cb = { userdata, location, contents, count, confirm in
            MainActor.assumeIsolated {
                guard let userdata else { return }
                Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue().writeClipboard(
                    location: location, contents: GhosttyRuntime.copyClipboardContents(contents, count: count), confirm: confirm)
            }
        }
        callbacks.close_surface_cb = { userdata, processAlive in
            guard let userdata else { return }
            // The pinned embedding API delivers close from key handling/app_tick on
            // the main thread. Resolve userdata while valid, but never free the C
            // surface until the callback has unwound.
            MainActor.assumeIsolated {
                let view = Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async { [weak view] in view?.onCloseRequest?(processAlive) }
            }
        }
        guard let app = ghostty_app_new(&callbacks, config) else {
            ghostty_config_free(config)
            self.config = nil
            throw TerminalError.initialization("ghostty_app_new failed")
        }
        self.app = app
        Self.current = self
        ghostty_app_set_focus(app, NSApp.isActive)
        keyboardObserver = NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let app = self?.app { ghostty_app_keyboard_changed(app) }
            }
        }
    }

    isolated deinit { close() }

    func setFocused(_ focused: Bool) {
        if let app { ghostty_app_set_focus(app, focused) }
        applySecureInput(focused && secureInputOwner != nil)
    }

    func requestSecureInput(_ enabled: Bool, for terminal: TerminalView) {
        if enabled { secureInputOwner = terminal }
        else if secureInputOwner === terminal { secureInputOwner = nil }
        applySecureInput(NSApp.isActive && secureInputOwner != nil)
    }

    private func applySecureInput(_ enabled: Bool) {
        guard enabled != secureInputEnabled else { return }
        let status = enabled ? EnableSecureEventInput() : DisableSecureEventInput()
        if status == noErr { secureInputEnabled = enabled }
    }

    func tick() {
        if let app { ghostty_app_tick(app) }
    }

    func reload(from url: URL) throws {
        guard let app, let next = ghostty_config_new() else { throw TerminalError.initialization("Runtime is closed") }
        url.path.withCString { ghostty_config_load_file(next, $0) }
        ghostty_config_finalize(next)
        guard ghostty_config_diagnostics_count(next) == 0, Self.hasSafeClipboardPolicy(next) else {
            ghostty_config_free(next)
            throw TerminalError.initialization("Invalid terminal configuration (clipboard-read must be ask or deny)")
        }
        // The pinned app update API propagates to existing surfaces and clones
        // its configuration; it does not recreate their PTYs.
        ghostty_app_update_config(app, next)
        if let config { ghostty_config_free(config) }
        config = next
    }

    func setColorScheme(dark: Bool, terminals: [TerminalView]) {
        guard let app, let config else { return }
        let scheme = dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        var changed = colorScheme != scheme
        if changed {
            colorScheme = scheme
            ghostty_app_set_color_scheme(app, scheme)
        }
        for terminal in terminals {
            if terminal.setColorScheme(scheme) { changed = true }
        }
        guard changed else { return }
        // Color-scheme setters request a soft reload from the embedder. Apply
        // our retained configuration after updating every conditional state.
        ghostty_app_update_config(app, config)
    }

    private static func hasSafeClipboardPolicy(_ config: ghostty_config_t) -> Bool {
        // config/c_get.zig exports enums as borrowed C strings. Never let config
        // silently turn an escape-sequence clipboard read into ambient permission.
        var policy: UnsafePointer<CChar>?
        let key = "clipboard-read"
        guard key.withCString({ ghostty_config_get(config, &policy, $0, UInt(key.utf8.count)) }), let policy else { return false }
        return ["ask", "deny"].contains(String(cString: policy))
    }

    struct ClipboardContent {
        let mime: String
        let data: Data
    }
    static func pasteboardType(_ mime: String) -> NSPasteboard.PasteboardType? {
        switch mime {
        case "text/plain", "text/plain;charset=utf-8": .string
        case "text/html": .html
        case "text/rtf", "application/rtf": .rtf
        case "image/png": .png
        case "image/tiff": .tiff
        default: nil
        }
    }
    static func mimeType(_ type: NSPasteboard.PasteboardType) -> String? {
        switch type {
        case .string: "text/plain"
        case .html: "text/html"
        case .rtf: "text/rtf"
        case .png: "image/png"
        case .tiff: "image/tiff"
        default: nil
        }
    }
    static func copyClipboardContents(_ pointer: UnsafePointer<ghostty_clipboard_content_s>?, count: Int) -> [ClipboardContent] {
        guard let pointer else { return [] }
        return (0..<count).compactMap { index in
            let entry = pointer[index]
            guard let mime = entry.mime, entry.len == 0 || entry.data != nil else { return nil }
            return ClipboardContent(mime: String(cString: mime), data: entry.len == 0 ? Data() : Data(bytes: entry.data!, count: entry.len))
        }
    }
    static func withClipboardPayload(contents: [ClipboardContent], available: [String], confirmed: Bool,
                                     body: (UnsafePointer<ghostty_clipboard_complete_s>) -> Void) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            for string in strings { free(string) }
            for buffer in buffers { buffer.deallocate() }
        }
        var representations: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = strdup(entry.mime) else { continue }
            strings.append(mime)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(1, entry.data.count), alignment: 1)
            buffers.append(buffer)
            entry.data.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { buffer.copyMemory(from: base, byteCount: bytes.count) }
            }
            representations.append(.init(mime: UnsafePointer(mime), data: UnsafePointer(buffer.assumingMemoryBound(to: CChar.self)), len: entry.data.count))
        }
        let availablePointers: [UnsafePointer<CChar>?] = available.compactMap { value in
            guard let string = strdup(value) else { return nil }
            strings.append(string)
            return UnsafePointer(string)
        }
        representations.withUnsafeBufferPointer { representations in
            availablePointers.withUnsafeBufferPointer { available in
                var payload = ghostty_clipboard_complete_s(contents: representations.baseAddress, contents_len: representations.count,
                    available: available.baseAddress, available_len: available.count, confirmed: confirmed, remember: false)
                withUnsafePointer(to: &payload, body)
            }
        }
    }

    /// Owner must close its terminal surfaces before closing the runtime.
    func close() {
        secureInputOwner = nil
        applySecureInput(false)
        if let keyboardObserver { NotificationCenter.default.removeObserver(keyboardObserver); self.keyboardObserver = nil }
        if Self.current === self { Self.current = nil }
        if let app { ghostty_app_free(app); self.app = nil }
        if let config { ghostty_config_free(config); self.config = nil }
    }
}

enum TerminalError: Error, CustomStringConvertible {
    case initialization(String)
    case inputRejected
    var description: String {
        switch self {
        case .initialization(let message): message
        case .inputRejected: "The terminal did not accept input"
        }
    }
}
