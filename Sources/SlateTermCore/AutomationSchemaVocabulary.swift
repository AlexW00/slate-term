/// Additional host constraints, not permission tiers. A generic JSON Schema
/// validator may ignore custom formats/annotations; the host remains authoritative.
public enum AutomationSchemaVocabulary {
    public static let extensions: [String: String] = [
        "x-packageManifestResolution": "Portable manifest must resolve through PluginManifest into a valid bounded runtime registration; managed-root expansion can impose further runtime size limits. Compatibility and installed resource availability are separate checks.",
        "x-signed64BitInteger": "Numeric value must be an integral signed 64-bit host Int. This annotation preserves the exact bound without emitting Int.max as a lossy JavaScript number.",
        "x-maxUTF8Bytes": "Maximum bytes in the decoded string's UTF-8 representation.",
        "x-maxUTF16CodeUnits": "Maximum UTF-16 code units in the decoded string, not Unicode scalars or graphemes.",
        "x-maxGraphemeCount": "Maximum Swift extended-grapheme-cluster count.",
        "x-maxEncodedJSONBytes": "Maximum compact Foundation JSONEncoder bytes for this value.",
        "x-maxValueDepth": "Maximum JSON nesting depth; this value is depth zero and each object value or array item adds one, including scalar leaves.",
        "x-noControls": "Reject Foundation CharacterSet.controlCharacters Unicode scalars.",
        "x-noWhitespaceOrControls": "Reject Foundation whitespace/newline or control Unicode scalars.",
        "x-trimmed": "Must equal its whitespace/newline-trimmed form.",
        "x-nonemptyAfterTrimmingWhitespaceAndNewlines": "Foundation whitespace/newline trimming must leave nonempty text.",
        "x-nonemptyAfterNotificationSanitization": "NotificationStore title sanitization must leave nonempty text.",
        "x-disjointLiteralPaths": "Operation paths are literal component arrays; duplicates and ancestor/descendant overlaps are forbidden.",
        "x-maxSetValueDepthIncludingPath": "For every set operation: JSON value depth plus path component count minus one must not exceed this limit.",
        "x-uniqueProperty": "Array items must have distinct values of the named property.",
        "x-orderedIntegerFields": "The first named integer field must be no greater than the second, using each field's declared default when omitted.",
        "x-layoutFieldValueRules": "Choice fields need nonempty unique options; other kinds need no options. Optional defaults must satisfy required/type/choice/directory/browser-URL rules; null input defaults mean absent. Text defaults are at most 16384 UTF-8 bytes without NUL.",
        "x-pluginContributions": "Require a panel source, command, or service. Without a source, panel process and layout fields are forbidden. Every header button must reference a declared local command.",
        "x-pluginSourceProcessRelationship": "Directory sources forbid a panel process. A panel process requires an HTTP 127.0.0.1 source. Port zero requires a panel process.",
        "x-refIdentityMatchesExpected": "If an element ref and expected automation IDs are both supplied, their view and document components must match exactly.",
        "x-savedLayoutTopology": "Enforce the declared split depth, globally unique recipe pane IDs, and exactly one matching recipe per layout leaf in each tab.",
        "x-maxNormalizedSavedLayoutBytes": "Maximum compact JSONEncoder bytes after SavedLayoutDefinition decoding fills omitted defaults; independent of raw-input and pretty-printed-file bounds."
    ]

    public static let formats: [String: String] = [
        "slate-package-relative-path": "Package-relative path after optional ./ prefix removal: nonempty, at most 1024 UTF-8 bytes and 32 components; no absolute path, backslash, NUL, empty, dot or parent components.",
        "slate-package-root-relative-path": "Same package-relative path rules, additionally accepting the single dot for the package root.",
        "slate-package-argument": "Literal argument, or standalone {pluginRoot}, or {pluginRoot}/ followed by a package-relative path. Embedded occurrences are rejected; no shell expansion.",
        "slate-web-key": "BrowserAction key parser: case-insensitive named key or ASCII graphic character, with unique ctrl/alt/shift/meta modifiers separated by plus; use plus for the literal plus key.",
        "slate-presence-note": "After Foundation whitespace trimming: nonempty, at most 80 graphemes and 320 UTF-8 bytes, with no control or newline scalars.",
        "slate-pane-id": "Canonical p-prefixed positive decimal integer representable by the host's signed 64-bit Int.",
        "slate-tab-id": "Canonical t-prefixed positive decimal integer representable by the host's signed 64-bit Int.",
        "slate-group-id": "Canonical w-prefixed positive decimal integer representable by the host's signed 64-bit Int.",
        "slate-terminal-key": "TerminalKey.parse named key with supported modifiers, at most 128 UTF-8 bytes; not arbitrary terminal text.",
        "slate-event-cursor": "Opaque EventJournal UUID-epoch and canonical decimal sequence cursor; format validity does not imply a live epoch or retained position.",
        "slate-key-chord": "KeyChord.parse configuration shortcut syntax and supported modifiers/key names.",
        "slate-keybinding-setting": "The keybind. prefix followed by a valid KeyChord.",
        "slate-configuration-line": "A nonempty configuration-line-safe value without prohibited line/control characters, as accepted by AppConfiguration.",
        "slate-working-directory": "An absolute or home-relative configured directory without control characters; availability is checked when creating terminals.",
        "slate-shell-path": "An absolute configured shell path accepted by AppConfiguration; live executable availability is checked separately.",
        "slate-palette-name": "A bundled terminal theme or safe custom palette name accepted by AppConfiguration.TerminalTheme; availability is checked separately.",
        "slate-search-url-template": "An AppConfiguration browser search URL template with a query placeholder in the permitted URL component, not the authority.",
        "slate-plugin-relative-entry": "Nonempty relative entry path without NUL or a .. path component; file containment/readability are checked separately.",
        "slate-plugin-url": "A valid PluginOrigin: HTTPS, or HTTP on localhost/127.0.0.1/IPv6 loopback, without credentials or invalid port. Process/port-zero relationships are separate constraints.",
        "slate-browser-url": "Strict BrowserURL.parse saved-recipe location: HTTP(S) without credentials, about:blank, local file URL, absolute or ~/ path; no controls or invalid unescaped URL characters.",
        "slate-browser-navigation-url": "BrowserURL.parse with assumingHTTPS: trim whitespace/newlines and use Foundation escaping and HTTPS inference, not a search query. File existence is checked separately.",
        "slate-browser-data-site-url": "BrowserDataRequest.siteHost absolute HTTP(S) URL without credentials, whitespace, controls, invalid percent escapes or ports; at most 16384 UTF-8 bytes.",
        "slate-web-element-ref": "Opaque view:document:counter. Both identities are 1...128 ASCII alphanumeric/underscore/hyphen bytes; counter is canonical positive UInt64. Live document/ref retention is checked separately.",
        "slate-layout-launcher-path": "URL(fileURLWithPath: value).pathExtension must be app; absolute/no-NUL syntax, new destination and library availability are separate constraints.",
        "slate-manual-pane-title": "After Foundation whitespace/newline trimming, at most 4096 UTF-8 bytes; empty clears. Internal controls are not rejected by this legacy operation.",
        "slate-manual-tab-title": "After Foundation whitespace/newline trimming, at most 100 graphemes/1024 UTF-8 bytes without controls; empty clears."
    ]
}
