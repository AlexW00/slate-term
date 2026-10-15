# Slate Terminal

A native macOS terminal workspace, implemented in verification-gated increments from the v0.2 specification.

**Status: v0.2 implementation and the full automated suite verified on Apple Silicon/macOS 27. Manual release QA remains; not release-certified.**

Implemented:

- Real, pinned libghostty terminal surfaces in AppKit windows.
- Native tabs and nested `NSSplitViewController` panes, directional focus, zoom, and equalization.
- Shared pane headers with type, a live title centered on the full panel width, optional command-backed plugin buttons, and a close control using the existing confirmation policy. Titles stay centered and truncate before overlapping the controls in narrow panes. Click the title once to edit it inline; Enter or clicking away saves, and Escape cancels. Manual names persist and override plugin/browser/terminal updates. Clear the name to restore automatic titles. **Copy Pane ID** is available in the command picker/Workspace menu and can be assigned a shortcut.
- A six-dot grip to the left of each pane type: drag to another pane’s left/right/top/bottom edge to move the existing pane within its tab. The highlight previews its new position; Escape or an invalid drop cancels. Click the grip for an accessible destination menu. Live terminal sessions and web content are retained. Unzoom before moving; cross-tab/window moves are not supported.
- A dropdown beside each pane type, plus a native Pane menu, for type changes without replacing pane identity or layout. Switching warns that the current state is discarded; “Don’t show again” remembers your choice separately from close warnings.
- Real WebKit browsers with navigation and administrative evaluation; shared guarded `web` snapshots, click/fill/select/scroll, waits and screenshots for browser/plugin panes. Plugin views retain separate origin, store and bridge privileges.
- Pure Swift workspace model: monotonic IDs, split/close/focus, terminal focus history, fractions, tab groups, validated JSON roundtrips.
- Shared command registry for menus, default shortcuts, and CLI actions; a keyboard-first **⌘K command picker** with native Liquid Glass, fuzzy search, context-aware availability, and built-in/plugin commands.
- Private per-instance Unix control socket with same-user `LOCAL_PEERCRED`, JSON-RPC handshake, bounded framing/output, and nonblocking server I/O.
- Bundled Swift Argument Parser CLI, terminal self-identification, literal input, protocol-aware key taps, bounded screen capture and authenticated shell run/condition waits.
- Typed TOML settings with live font/theme/shortcut reload, last-valid retention, offline validation, and restart diagnostics.
- Private, atomic workspace restoration with single-writer ownership, native tab order, and corruption-preserving recovery (never placeholder views).
- Native terminal input/composition, mouse input, clipboard confirmation, and token-bound zsh context reporting.
- Trusted plugins can contribute on-demand executable commands, panels, or both. App-local shortcuts, namespaced settings, pane/tab/global panel instances, private persisted storage, bounded process logs, supervision and owned-group cleanup after GUI crashes.
- Bounded resumable event polling/streaming, native source attribution, scoped plugin subscriptions, directed delivery and cancellation.
- Unit, socket, native lifecycle, CLI-driven restart/configuration, production-zsh, and regression-mutation checks.

The sequential whole-application suite records source/binary hashes in `artifacts/verification.json` only after every gate passes without source changes. Consult the verification ledger and current run artifacts rather than treating historical results as certification of a later working tree. Manual IME/accessibility, long-use soak and wider platform coverage remain unverified. Capture is current-screen text, not an isolated last-command stdout stream. See [automation contracts and limits](docs/automation.md) and the [verification ledger](docs/verification.md).

Core remains terminal-agnostic: no tmux adapter, session discovery, command parsing, or tmux runtime dependency. Extensions implement tool-specific integration using the generic bridge, managed backend, CLI/IPC, input/capture, and events. Isolated tmux fixtures verify compatibility only.

See [agent identity, inspection and shared commands](docs/agent-api.md), [guarded layout/tab/window APIs](docs/layout-api.md), [trusted plugins](docs/plugins.md) for commands, panels, settings and supervision, the [command picker](docs/command-picker.md), and [workspace events](docs/events.md). Historical capability audits document [native UI/CLI layout parity](docs/layout-cli-audit.md) and [plugin integration/hooks](docs/plugin-integration-audit.md); see [implementation progress](docs/api-extension-progress.md) for delivered slices and remaining work.

Pane titles follow terminal process/context information, browser document titles, and plugin document titles or `workspace.setTitle(title)`. Passing `null` restores a plugin's document title. macOS can redact process environments; authenticated zsh reports supply ownership for foreground-process sampling, while unavailable process metadata falls back to the configured shell and engine title.

## Build and run

Requires Apple Silicon, Xcode with the Metal toolchain, and Swift 6.2 or newer. The existing Xcode app deployment target is macOS 27; older OS versions and Intel have not been validated.

```sh
bash scripts/build-ghostty.sh   # pinned source + checksum-verified local Zig download
bash scripts/build-app.sh      # CLI, native app, resources, development-only ad hoc signature
open ".derived/Build/Products/Debug/Slate Terminal.app"
```

In Xcode select **SlateTermApp**, not `slate-term` (the package CLI can create a same-named autogenerated scheme). Run the build script first to install the CLI into the development bundle. No toolchain or CLI is installed globally, and nothing is published or notarized.

The Ghostty pin is `554ea65867ffe34bb3e51e09bd016e154a1f9d7a`, built with Zig `0.16.0`. Sources are fetched into `.build/bootstrap/ghostty`; binaries are not checked in. See `scripts/build-ghostty.sh` for the pin and toolchain checksum.

## CLI

Inside a terminal pane, `slate-term` is on PATH and automatically targets that pane/tab:

```sh
slate-term panes split --right
slate-term panes split --down --pane p2
slate-term panes list --json
slate-term layout get --tab t1
slate-term panes focus --pane p1
slate-term panes send --pane p1 --text $'printf "hello\\n"\r'
slate-term panes capture --pane p1
slate-term terminal key --pane p1 --key ctrl+c
slate-term terminal run --pane p1 --command 'printf "hello\\n"'
slate-term terminal wait --pane p1 --contains READY --timeout-milliseconds 5000
slate-term panes type --pane p2 --type browser --force
slate-term context get
slate-term plugins register --manifest /absolute/path/plugin.json
slate-term plugins list
slate-term events watch --topic 'host.context.*'
slate-term events emit --topic build.finished --payload '{"exitCode":0}'
slate-term tabs new
slate-term command list
slate-term command run split.right
slate-term config get
slate-term config reload
slate-term config validate --file ~/.config/slate-term/config.toml
```

External shells must pass `--socket <path>` or set `SLATE_TERM_SOCKET`. Socket files live under `~/Library/Application Support/SlateTerm/control/`; the host accepts only the same user. This is intentionally a powerful local interface, like a tmux socket.

`--pane`/`--tab` override the corresponding `SLATE_TERM_PANE_ID`/`SLATE_TERM_TAB_ID` defaults. An explicit tab suppresses an inherited pane target; an explicit pane suppresses an inherited tab target. Closing a potentially busy terminal requires `--force` or confirmation in the native UI. All current CLI responses are JSON.

## Configuration

Edit `~/.config/slate-term/config.toml`; valid changes reload automatically. Workspace structure is saved under `~/Library/Application Support/SlateTerm/state/`. Restored terminals are new processes, not resumed PTYs. See [configuration and recovery](docs/configuration.md) for fields, shortcut overrides, diagnostics, and limitations.

## Verify

```sh
bash scripts/verify-all.sh               # expanded sequential suite with source/binary manifest

# Or run individual gates:
bash scripts/verify-model.sh             # pure model/protocol + actual Unix socket tests
python3 scripts/verify-model-mutations.py
bash scripts/verify-terminal.sh          # own shell/windows: reparent, resize, tabs, output, child cleanup
bash scripts/build-app.sh
python3 scripts/verify-app.py            # own app/storage: drive and inspect it using the bundled CLI
python3 scripts/verify-config-cli.py     # offline validation, no running app required
python3 scripts/verify-settings.py       # live reload, native key routing, reorder, restart/recovery
python3 scripts/verify-shell.py          # production zsh path, isolated dotfiles, OSC 133, UTF-8 input
python3 scripts/verify-browser.py
python3 scripts/verify-context.py        # shell context and pane headers
bash scripts/verify-pane-titles-native.sh # isolated production header layout/editing and native renders
python3 scripts/verify-pane-titles.py    # full-app title centering, narrow panes and inline rename
bash scripts/verify-pane-movement-native.sh # drop geometry and native preview helpers
python3 scripts/verify-pane-movement.py  # native drop callbacks, retained content, menu, previews and persistence
python3 scripts/verify-plugins.py        # actual modules/bridge/storage/restoration/header controls
python3 scripts/verify-plugin-services.py
python3 scripts/verify-plugin-commands.py
python3 scripts/verify-command-picker.py
bash scripts/verify-plugin-process.sh
python3 scripts/verify-plugin-worker.py
bash scripts/verify-plugin-listener.sh
bash scripts/verify-process-titles.sh
bash scripts/verify-event-hub.sh
bash scripts/verify-terminal-keys.sh
bash scripts/verify-terminal-runs.sh
python3 scripts/verify-events.py
python3 scripts/verify-extension-interop.py # external adapter; owns an isolated tmux server
```

Native gates require a logged-in macOS GUI session, tmux on PATH, and permission to capture their own windows. They use deadlines, fail on unavailable capture, ignore physical keyboard input in their test windows, and never automate unrelated applications. Generated logs/screenshots stay in ignored `artifacts/`. Integration-only `debug.*` methods are enabled only with `SLATE_TERM_INTEGRATION=1`.

See [implementation gates](docs/implementation.md) and the [verification ledger](docs/verification.md) for evidence, failed checks, and remaining work. [Pane movement](docs/pane-movement.md) documents the new interaction, callback-level coverage, and remaining manual drag checks.
