# Verification

The expanded end-to-end gate is `bash scripts/verify-all.sh`. It runs every check below sequentially, records each successful step in `artifacts/verification-checks.txt`, and writes `artifacts/verification.json` **only after all steps pass**. The manifest includes source and app/CLI binary SHA-256 hashes. Source changes during the run invalidate completion. A stale manifest does not certify newer edits.

**Last full-suite checkpoint (before subsequent UI changes):** the expanded combined run passed on **2026-10-14 at 07:41:31 UTC** (`artifacts/complete-verification.log`), all **25 gates**, including **77 Swift tests** (53 core, 8 IPC, 16 settings) and three regression mutants. All **94 source hashes and 2 executable hashes** were rechecked against the working tree, including by an independent reviewer. This establishes the automated coverage below, not release certification or manual/platform coverage. [Historical evidence](verification-history.md) retains the earlier terminal/configuration slice.

## Subsequent menu and close-warning changes

The menu/close-warning work has its own native gate, `python3 scripts/verify-menu-ui.py`, now included in `verify-all.sh`. It verifies submenu organization, visible shortcuts, actual key dispatch, removal of the disabled switching note, native alert cancellation/consent, restart persistence, reset, quit checks, and unchanged CLI `--force` safeguards. It captures the actual menus and alert in `artifacts/*-menu.png` and `artifacts/close-warning.png`.

`menu-shortcuts-red.log` records the missing-default-shortcuts regression. Model/build/native gate and affected regression logs use the `menu-` prefix. Subsequent menu and Settings work changes source hashes; the earlier combined manifest does **not** certify the current working tree. Cursor rectangles use AppKit's pointing-hand cursor; the native gate does not move the user's physical mouse to verify hovering.

## Automated checks

| Gate | Actual coverage |
| --- | --- |
| `build-ghostty.sh` | Pinned full Ghostty engine and checksum-verified local Zig toolchain |
| `verify-model.sh` | Workspace topology/IDs/focus/zoom/equalization, protocol, actual sockets, shell/event/browser input contracts, TOML/watchers, private state/catalog/storage |
| `verify-model-mutations.py` | Deliberate regressions rejected by assertions |
| `verify-terminal-keys.sh` | 74 physical SDK mappings × 8 modifier sets, parsing and byte bounds |
| `verify-terminal-runs.sh` | Unique command markers, quoting, one-shot shell input claims, draft refusal, sequences, UTF-8 output bounds, deadlines/cancellation/replacement/capacity |
| `verify-event-hub.sh` | Real suspension, replay/filtering, cursor advancement, cancellation, close, overload and deadline races |
| `verify-plugin-process.sh` | Actual executable/cwd/environment, bounded logs, exit/reaping, TERM/KILL and owned-group cleanup |
| `verify-plugin-listener.sh` | Real socket/process-group ownership and rejection of unrelated listeners |
| `verify-process-titles.sh` | Kernel-only process attribution against real owned PTYs and foreground jobs |
| `verify-terminal.sh` | Real Metal/libghostty PTY output, resize/reparent/native tabs without shell replacement, IME commit, clipboard consent, secure-input ownership, mouse, Kitty key press/release, application-cursor keys, Ctrl-C and child cleanup |
| `build-app.sh` | Explicit SlateTermApp target, bundled CLI/resources/terminfo and development-only ad hoc signature |
| `verify-plugin-worker.py` | Actual bundled group supervisor and cleanup after GUI death |
| `verify-app.py` ×3 | CLI drives actual native tabs/splits/focus/dividers, layout geometry, stable surfaces, terminfo, isolated tmux compatibility and shell closure |
| `verify-config-cli.py` | Offline configuration validation |
| `verify-settings.py` | Live reload, native shortcuts, last-valid retention, tab reorder persistence, writer lease, restart and corruption recovery |
| `verify-window-recovery.py` | Empty saved workspace opens a terminal without resetting IDs, windowless ⌘N/⌘T, creation from Settings, and idempotent Dock reopening |
| `verify-appearance.py` | Light/dark/auto, original palette choices, rendering-option translation, Settings/TOML persistence, invalid-edit retention, unchanged live PTY, and native settings/terminal captures |
| `verify-palettes.py` | All 25 bundled palettes in both modes, names-only custom imports, collision-safe copies, path rejection, custom rendering/snapshots, CLI/UI validation, explicit reload, and safe startup fallback |
| `verify-shell.py` | Production zsh with isolated startup/history, executable quoting, PATH, Unicode and OSC 133 integration |
| `verify-browser.py` | Actual owned HTTP fixture, WebKit navigation/evaluation/screenshots, isolated stores, DOM actions, stale/BFCache references, clipping, refusal paths and absence of plugin privileges |
| `verify-context.py` | Authenticated zsh prompt/running/cwd/status, pane headers, generic run/wait, unfinished-draft refusal, disconnect cleanup, scoped targeting, replacement and unknown-state refusal |
| `verify-plugins.py` | Actual ES modules, isolated bridge and frame/document boundaries, scoped storage/events/input, aborts, registration/unregister transactions, restoration and header controls |
| `verify-plugin-services.py` | Real readiness/listener ownership, restart coalescing, bounded restart/logging, process death, scopes and cached-history bridge recovery |
| `verify-plugin-commands.py` | Headless/mixed manifests, discovery, CLI and page commands, scoped routing, shortcuts/settings, exit reports, bounded output, timeouts, duplicate rejection, disconnect/unregister cleanup, persistence and app-crash supervision |
| `verify-events.py` | Public IPC replay/streaming/filtering, native provenance, bounded payloads, disconnect cancellation and explicit restart resynchronization |
| `verify-extension-interop.py` | Managed backend discovery/environment, real engine key input, extension-owned private tmux inspection, screen capture, directed context and stale-session rejection |

## Recent red → green evidence

Earlier feature logs remain under ignored `artifacts/`. Representative regressions include:

- `extension-interop-red.log`, `extension-session-red.log`: missing backend discovery/session guards, followed by working public CLI/IPC extension interoperability.
- `browser-actions-red.log`: missing DOM API. `browser-actions-green.log`: named content worlds were not retained between calls; retaining the world made the native DOM actions pass.
- `browser-truncation-unit-red.log`: the production snapshot script failed to flag a clipped single text node; the native browser gate also checks this case.
- `terminal-run-native-red.log`: missing run/wait commands, followed by real-zsh completion/exit status/timeout tests.
- `run-draft-red.log`: a nonempty ZLE draft was submitted by the original run implementation. Delivery now goes through an authenticated, one-shot shell widget which checks the editing buffer before accepting a command. `run-continuation-red.log` additionally reproduced execution of earlier continuation lines; `PREBUFFER` and primary-prompt checks now refuse that case, verified by `run-continuation-green.log` and the final context gate.
- `terminal-keys-native-red.log`: missing named-key CLI; real extension interoperability subsequently passed. `terminal-keys-protocol-isolated.log` proves exact PTY bytes for Kitty press/release and legacy application-cursor/control keys.
- Plugin screenshot-size failures exposed transformed thumbnail captures. Tests activate/restore only their owned window and require stable full-sized pixels rather than accepting the thumbnail.
- Secure-input fixture checks now establish an explicit baseline: `stty -echo` can itself make Ghostty request secure input. Tests inspect successfully balanced process-owned Carbon calls, not an unstable global baseline shared with other apps.

Independent automation review identified unfinished-draft submission (including continuation prompts), inherited pane IDs overriding an explicit CLI scope, and omitted empty/plaintext contenteditable controls. Corrections have dedicated regressions. Fresh independent read-only verification found no remaining actionable defects in those changes and verified the final source/binary hashes. That reviewer inspected outputs; it did not independently rerun the suite.

Independent visual review of the final `plugin-workspace.png` and `browser-workspace.png` found no visible issues in hierarchy, typography, spacing, pane headers, right-edge close controls, clipping or rendering. This covers those desktop states, not all layouts or live behavior.

One pre-final first-start context check timed out before diagnostic capture was added; its cause remains unconfirmed. The diagnostic rerun, continuation regression and expanded final suite passed. The later passes are not a claimed root-cause fix for that isolated timeout.

## Ownership and environment

Apple Silicon, macOS 27 and Xcode/Swift 6.2+ with the Metal toolchain. The app's existing macOS 27 target, user bundle ID and signing configuration are preserved. Nothing is globally installed, pushed, published, deployed or notarized.

GUI checks own their windows, temporary state/configuration, shell startup/history, Unix sockets, HTTP fixtures and process groups. Tmux checks use private test servers, never user sessions. Test-mode application windows ignore physical keyboard input; scripted input still follows the tested dispatch path. They may activate their windows, so concurrent mouse/focus interaction can still interfere. Native captures fail if permission or a usable GUI session is unavailable. Tests use real readiness conditions and hard failure deadlines, not sleep-based success.

## Remaining release/manual verification

These are explicit coverage/support limits, not placeholders replacing implemented features:

- Manual Japanese/Korean/dead-key IME behavior, trackpad/pressure behavior, keyboard-layout variety and a full VoiceOver/accessibility audit.
- Extended daily-use/soak, sustained hostile/slow-reader load, and an actual different-UID peer rejection test.
- Older macOS versions and Intel are not supported by this verification; the current project targets macOS 27.
- Workspace restoration restores topology/types/identity/focus, not PTY continuity, output, cwd, web history or window geometry. Atomic file replacement is not power-loss durability.
- Trusted plugin process groups do not contain deliberate daemonization; static asset containment is not a sandbox against a trusted owner concurrently replacing filesystem paths.
- Browser automation limitations and terminal output/completion semantics are documented in [automation](automation.md). Neither unknown shell state nor synthetic DOM input is presented as a stronger guarantee.
- Distribution signing/notarization/release publishing is not performed without separate authorization.
