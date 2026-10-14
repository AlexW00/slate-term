# Verification ledger

**Historical ledger:** the slice results below predate the current headers, shell context, plugins and event integration. They do not certify the current source tree. See [README](../README.md) for implemented features and newer individual gates; whole-application verification remains pending. Core has no planned tmux adapter: tmux appears only in isolated compatibility/extension tests.

## Historical scope

This implements the **Phase 1 terminal/control and configuration/restoration slices**, not the entire v0.2 specification and not yet a daily-driver replacement. The application now runs real libghostty terminals in native tabs/splits, controlled by its bundled CLI. No fake terminal or web-view substitute is used.

Completed slices cover pinned native terminal embedding/lifecycle, pure model, command/control, native split/tab reconciliation, a tmux smoke test, typed TOML reload, and disk workspace restoration. Remaining Phase 1 work includes shell context, directional focus/zoom/equalize, and terminal input/clipboard/mouse completeness. Phases 2–4 have not started.

## Environment and ownership

- Apple Silicon macOS 27, Xcode Swift 6.4, installed Metal compiler and tmux.
- Package requires Swift 6.2+ for isolated destruction; the existing app deployment target remains macOS 27. Intel and older OS versions are unverified.
- Original Xcode bundle identifier/platform/signing-team changes preserved. Nothing pushed, globally installed, notarized, or published.
- Exact Ghostty commit: `554ea65867ffe34bb3e51e09bd016e154a1f9d7a`; checksum-verified Zig 0.16.0 lives under `.tools/`.
- Native tests create their own windows, shells, sockets, temporary state directory, and uniquely named tmux server (`-L`, `-f /dev/null`). They never address a user's existing tmux server.

## Verification loops

```sh
bash scripts/verify-all.sh
```

This fails fast through engine build, **45 Swift tests** (25 model/protocol + 6 actual-socket + 14 settings/watcher/persistence tests), three regression mutants, native terminal lifecycle, app build, and **three separate CLI-driven app runs**, followed by offline configuration validation, configuration/restart/recovery scenarios, and three isolated production-zsh scenarios. Each native run has deadlines and cleanup. A timeout is a failure, not settling success. The final gate writes source SHA-256 hashes to `artifacts/verification.json`.

Latest complete run: **2026-10-13 20:08:09 UTC**, exit 0 (`artifacts/configuration-final-verification.log`). All **41** recorded source hashes were rechecked against the working tree, including the source-file set. Independent visual review of the light workspace and dark placeholder reported no visible findings.

Individual entry points:

```sh
bash scripts/verify-model.sh
python3 scripts/verify-model-mutations.py
bash scripts/verify-terminal.sh
bash scripts/build-app.sh
python3 scripts/verify-app.py
python3 scripts/verify-config-cli.py
python3 scripts/verify-settings.py
python3 scripts/verify-shell.py
```

Native gates require a logged-in GUI session and permission to capture their own windows. Failed capture fails the gate. Generated logs/screenshots are local, ignored `artifacts/`, not checked-in snapshots.

## Observed failures and fixes

| Check | Observed red state → passing correction | Local evidence |
| --- | --- | --- |
| Starter build | Existing Xcode app builds before modifications | `baseline-build.log` |
| Pure model contracts | Tests initially fail for missing implementation; split/close/focus/group/restore contracts implemented | `model-red.log`, `model-green.log` |
| Background close | Closing a focused pane in a background tab stole the key tab → preserve key-tab selection | `invariants-red.log`, `invariants-green.log` |
| Restore boundaries | Inconsistent focused-terminal history was accepted → validate references/history/counters at restore | same invariant logs |
| Regression quality | Independent review found self-referential direction expectations and a duplicate-leaf fixture failing for an unrelated reason → corrected fixtures, boundary tests, three deliberately broken implementations all rejected by assertions | `mutation-*.log`, `mutation-checks.log` |
| Engine/toolchain | Ghostty 1.2.3/Zig 0.14.1 could not resolve libSystem symbols against this SDK → newer exact source/toolchain pin builds full GhosttyKit | `ghostty-build.log`, `ghostty-build-current.log` |
| Surface lifecycle | Missing wrapper initially fails; actual PTY output survives split/window reparenting, native tab group/detach, and resize with the same surface and shell PID; closing terminates the child | `terminal-red.log`, `terminal-lifecycle.log`, `terminal-lifecycle.png` |
| Control protocol | Missing protocol/transport initially fails; same-user socket, permissions, handshake, framing, and real client/server tests pass | `protocol-red.log`, `ipc-red.log`, `model-tests.log` |
| JSON null / bad parent tab | Synthesized optional decoding lost explicit null; `tab.new --tab t999` created a window → retain null presence, reject invalid parent | `protocol-boundaries-red.log`, `protocol-boundaries-green.log` |
| Socket lifetime/errors | Final release left socket files; malformed JSON was confused with invalid envelopes → isolated destruction, bounded peer teardown, distinct wire errors; connected idle-peer destruction tested | `ipc-lifetime-red.log`, `ipc-wire-errors-red.log`, `model-tests.log` |
| CLI-driven native app | Starter never creates the control socket → CLI can build and inspect the actual AppKit split tree | `app-red.log`, `app-run-*.log` |
| Native geometry | Splitting grew the window; fractions differed from model → flexible terminal views, preserve window frame, apply fractions to **arrangedSubviews** (macOS 27 adds a decorative third subview) | `app-geometry-red.log`, `app-explicit-scheme.log`, `app-arranged-subviews.log` |
| Build identity | Autogenerated CLI/app schemes shared `slate-term`; an apparently successful build left an old app binary → explicit shared **SlateTermApp** scheme and target-graph assertion in build script | `app-build.log`, `scripts/build-app.sh` |
| Bundled terminfo | `$TERMINFO/78/xterm-ghostty` was absent → bundle terminfo beside Ghostty resources; execute `tput` in the real pane | `app-terminfo-red.log`, `app-terminfo-green.log` |
| Native tab detach | AppKit detached the tab but the model still had one group → import validated native tab grouping on activation/control dispatch | `app-native-actions-red.log`, `app-native-actions-green.log` |
| Engine focus | Two surfaces retained focus after rebuilding a split → explicitly reconcile engine focus, native first responder, key window, and application activation | `app-terminal-focus-red.log`, `app-terminal-focus-green.log` |
| Native Ctrl-C | Literal CLI input worked but native Ctrl-C failed to interrupt `sleep 30` → normalize AppKit control text before Ghostty encoding; now interrupts before the 10-second deadline | `terminal-control-c-red.log`, `terminal-control-c-green.log` |
| Background first responder | A one-survivor fixture passed accidentally; with two survivors, native activation focused the wrong terminal → restore per-tab first responder explicitly | `app-background-focus-red.log`, `app-shell-lifetime-green.log` |
| Shell-driven pane closure | Engine close callback was ignored → defer closure out of the C callback and invoke the same registry command. Fixture correction: the embedding API's surface `command` option implicitly enables wait-after-command, so isolated test shells are configured through an engine config file instead | `app-review-regressions-red.log`, `app-shell-lifetime-green.log` |

The final runtime gate also verifies native Command-D routing, divider writeback, stable surfaces through repeated split/close cycles, literal terminal input/capture, input/rendering inside an isolated attached tmux session, foreground-process close protection, terminal CLI-on-PATH and self-identification, explicit-tab targeting precedence, natural shell exit, and creating a new tab after the last shell exits.

## Configuration/restoration follow-up

| Check | Observed red state → correction | Local evidence |
| --- | --- | --- |
| Settings/store implementation | Missing settings module → strict typed TOML, validated private snapshots, live reload and restoration | `settings-red.log`, `settings-green.log`, `settings-app-red.log`, `settings-app-green.log` |
| Parser boundaries | CRLF bypassed Character-based checks; TOML timestamps decoded as font numbers; directories passed executable checks; literal/named key aliases collided → scalar validation, strict numeric decoding, regular-executable checks, canonical keys | `settings-review-red.log`, `settings-review-green.log` |
| Native key routing | Bare keys bypassed key-equivalent dispatch; shifted punctuation did not match additional bindings → intercept owned-window key events, retain native menu equivalents and raw/unshifted-event fallback | `settings-native-review-red.log`, `shifted-shortcut-red.log`, `native-menu-control-diagnostic.log`, `settings-native-final.log` |
| Three-tab order | Adding every new tab after the first reversed later siblings → insert after the preceding sibling | `settings-tab-order-red.log`, `settings-observation-green.log` |
| Native reorder persistence | Reordering the selected tab left the disk snapshot stale until a synchronizing RPC read → observe AppKit's KVO-compliant tab-group `windows`, coalescing transient moves | `native-reorder-persistence-red.log`, `settings-observation-green.log` |
| State ownership | Two stores could write the same directory → private single-writer flock lease, released on close/process exit | `state-ownership-red.log`, `settings-native-final.log` |
| Watcher feedback | Sibling generated-file writes triggered further reloads → compare target contents/read-error state before scheduling; real app now tests config/state colocation | `configuration-notification-red.log`, `settings-native-final.log` |
| Production shell integration | Single-quoted executable paths prevented Ghostty detection → compatible quoting, explicit restrictions for auto integration, literal quoting with integration off | `production-shell-integration-red.log`, `shell-contract-red.log`, `production-shell-green.log` |
| Raw terminal input | The C `surface_text` API is paste, so bracketed-paste zsh did not execute a trailing Return → use the escaped `text:` action for literal bytes | `production-shell-prompt-red.log`, `production-shell-green.log` |
| SIGINT fixture | Immediately sending another command after Ctrl-C could lose it to tty flushing → foreground child acknowledges SIGINT itself, before the 10-second deadline | `configuration-full-verification.log`, `terminal-signal-ack.log` |

The native settings gate checks stable surfaces and shell PIDs across font/theme reload, configured Command/Control/unmodified/shifted-symbol keys through `NSApp.sendEvent`, atomic/in-place editing, bad-edit retention, regular-file shell validation, a rejected second app writer, and a quiet generated-config file. It checks native reorder persistence directly from disk **before** any RPC read can repair the model. Restart scenarios cover tab order/groups/focus, closed-ID nonreuse, a new child process, disabled restoration, preserved corrupt snapshots, and unavailable-view placeholders.

Production-zsh fixtures use isolated dotfiles and history. They cover system and quoted/special paths, integration-off literal metacharacters, UTF-8 input, real OSC 133 idle-prompt detection, and the bundled CLI path even after startup files reset PATH. Other production shells are not established by these checks.

## Review evidence

- Independent bounded model review: no confirmed code defect; four test weaknesses corrected.
- Independent control review: lifecycle cleanup, post-bind cleanup, and wire error classification findings addressed. Deliberate `chmod`/`listen` failure injection has not been performed.
- Independent native review: Ctrl-C, shell-close callback, and background first responder findings reproduced and addressed. The background test needed two surviving panes to exercise the actual hazard.
- Independent configuration reviews found parser, shell-execution, shortcut, tab-order, and watcher-feedback defects; regressions were added and the listed corrections applied. Additional coverage checks unreadable-config errors, failed-save preservation, snapshot permissions, and writer ownership.
- Independent visual review of the light four-pane workspace and dark restored placeholder: no visible findings. Static evidence does not establish persistence or live interaction behavior.
- Independent visual review of rendered three-pane and single-pane states: no remaining visible findings after waiting for actual shell readiness and correcting focus. Static captures do not establish live input behavior; separate runtime gates cover the listed interactions.

## Explicit limitations

- Same-user acceptance and directory rejection are executed; a different-UID client has not been launched to independently test rejection.
- Socket framing/output are bounded; sustained hostile-load/slow-reader stress and future event backpressure are not validated.
- Restoration covers model structure, identities and focus, not PTY continuity, terminal output, working directories, or window geometry. Power-loss durability is not guaranteed.
- Configuration watches the file and its parent, not replacement of the parent directory itself. Keyboard-layout coverage is limited; avoid layout-dependent shortcut collisions. Concurrent native modal-confirmation interactions are not independently automated.
- No shell context reporting, plugin registry/bridge/process supervisor, event stream, browser automation, or release pipeline.
- No full IME, selection/mouse, clipboard, key-release/Kitty input coverage, accessibility audit, extended daily-use soak, or cross-version/platform testing. Basic text/control input and a tmux session are not terminal parity.
