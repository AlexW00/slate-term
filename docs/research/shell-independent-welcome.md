# Shell-independent welcome delivery: initial research only

> **Decision record.** The recommended native inline welcome has since been built; see [welcome](../welcome.md) for current behavior.

**Superseded recommendation:** read [welcome-reassessment.md](welcome-reassessment.md) first. The user did not require scrollback; native inline content is the smaller fit. A launcher with explicitly selected shell integration is also feasible without an engine fork. This document preserves the initial engine-path investigation, not the current preferred solution.

## Status and scope

At this initial research stage, no welcome feature was implemented and no builds, tests, installs, or modified-app launches were performed. The subsequent reassessment added isolated PTY and standalone VT-library probes, documented separately. No engine/application code, installed app state, shell files, or launch configuration was changed. Neither document authorizes implementation.

- Slate research branch: `investigate/shell-independent-welcome`, based on `f5638ec`.
- Slate worktree: `~/.worktrees/<owner>/<repo>/shell-independent-welcome`.
- Pinned Ghostty: `554ea65867ffe34bb3e51e09bd016e154a1f9d7a`.
- Engine source was inspected read-only in the existing `.build/bootstrap/ghostty` checkout of the original repository; its HEAD matched the pin and its tracked source was clean. No mutable dependency directories were linked into this worktree.
- An independent reviewer checked the candidate insertion point, ownership, parser side effects, and alternatives. Findings were checked against the source.

## Recommendation

If an **ordinary terminal-output/scrollback experience** is explicitly chosen, one candidate is a deliberately designed, creation-only **initial output** facility in the pinned engine. This was an assistant-introduced presentation assumption, not a user requirement. Have Slate supply its welcome as bounded plain text when creating an eligible terminal session. Parse it **before starting the subprocess/PTY reader**, then use the existing shell launch path unchanged.

This is genuinely shell-independent: automatic welcome rendering does not run a shell command or require a prompt hook. It should apply equally to zsh, bash, fish, another configured shell, and integration-off. It does **not** make authenticated automation available in shells that currently lack Slate's zsh-specific automation integration.

There is **no existing public surface-output API** in the inspected Ghostty pin. This proposal requires a deliberate engine extension and matching embedding API; it is not a configuration-only change. If avoiding an engine change is more important than scrollback semantics, the native-pane alternative below is the better route.

## Verified facts and concrete integration points

References to engine files below are relative to the pinned Ghostty checkout, not Slate's source tree.

| Location | Verified behavior / relevance |
| --- | --- |
| Slate `Native/WorkspaceHost.swift:1539–1568` | New terminal sessions are prepared centrally in `reconcile`; a fresh `ShellSession` and `TerminalView` are created here. Sample welcome eligibility here, not on focus or every shell invocation. |
| Slate `Native/Terminal/TerminalView.swift:58–83` | Builds per-surface options and calls `ghostty_surface_new`. The welcome would be an additional creation-only payload here. |
| Slate `Native/ApplicationSettings.swift:117–125,190–207` | Keeps the configured login shell as the detected command and redirects Ghostty's zsh integration bootstrap. These paths need not change for output seeding. |
| Engine `include/ghostty.h:508–521,1176–1241` | Surface options expose `initial_input`, not initial output. The public surface functions do not expose an output-feed operation. |
| Engine `src/apprt/embedded.zig:485–495,588–607,2073–2082` | `initial_input` is subprocess input; `ghostty_surface_text` follows text/paste input handling. Neither is a display-output API. |
| Engine `src/Surface.zig:691–708,734–746` | Initializes terminal IO/parser/mailboxes, starts the renderer thread, then starts the IO thread. Calling a new output function after `ghostty_surface_new` returns would be too late to guarantee banner-before-prompt ordering. |
| Engine `src/termio/Termio.zig:695–752` | `processOutput` takes the renderer-state mutex, schedules rendering, and feeds the existing terminal stream parser. This is the relevant output path. |
| Engine `src/termio/Termio.zig:365–404` | `threadEnter` prepares startup state and initializes thread data before invoking `backend.threadEnter`. A proposed insertion immediately before that backend call precedes child startup. |
| Engine `src/termio/Exec.zig:87–159` | Backend startup launches the subprocess and then the reader thread. Leave this shell/process implementation unchanged. |
| Engine `src/termio/Thread.zig:268–280` | IO mailbox processing is registered/run only after `threadEnter` returns. This constrains safe startup payloads. |
| Slate `scripts/build-ghostty.sh:5,27–32` | The build is pinned and rejects modified tracked engine sources. A future engine change must be a reproducible, tracked dependency decision, not an ad hoc edit to the cache or removal of the clean-source check. |

### Proposed data flow (not implemented)

1. Host determines eligibility when preparing each new terminal session. It supplies either no output or the shared welcome text. No CLI subprocess, socket lookup, sleep, or wait for a prompt is needed on startup.
2. A new engine creation API/option accepts the payload and copies it before the host's temporary buffer goes away. Its exact signature remains to be designed; do not retain Swift pointers or assume header-only changes are sufficient.
3. Thread that owned, creation-only value through surface initialization into startup state. Keep it out of inherited settings, hot reload, workspace snapshots, and the child environment.
4. In `Termio.threadEnter`, after thread-data initialization and before `backend.threadEnter`, synchronously call the output parser once with the validated text. Then proceed with the existing backend startup.
5. Preserve existing cleanup on both successful and failed startup. `ThreadEnterState.create` currently returns null for input-free configurations (`Termio.zig:87–92`); an output-only path must be represented too. The existing arena also owns prepared initial-input slices, so it must not be destroyed early just because welcome parsing finished. `threadEnter`'s deferred cleanup and `Termio.deinit` cover different ownership paths.
6. Keep explicit `slate-term welcome` as ordinary stdout output using the same content formatter. Normalize direct-to-emulator line breaks to CRLF; stdout can retain normal LF formatting. This does not require injecting anything into an existing terminal from the host.

### Mandatory payload restriction

This is **text-only welcome seeding**, not a general arbitrary-VT injection API. Accept validated printable UTF-8 plus explicit CR/LF, with byte/line bounds. Exclude escape sequences, other control characters, terminal queries, clipboard operations, hyperlinks and incomplete parser sequences. Reject/skip invalid optional welcome content without failing shell startup; do not truncate inside UTF-8.

Reason: `src/termio/stream_handler.zig:862–923` generates IO response messages for terminal queries. `src/termio/mailbox.zig:15,63–95` has a 64-message queue that can block when full. Because startup runs before that same thread starts draining its mailbox, a query-rich payload can deadlock startup; smaller query payloads can send unsolicited responses to the shell. A size bound alone is insufficient. An unfinished escape sequence can also consume later real shell output. The plain-text restriction avoids these parser side effects.

## Guarantees and limitations

**Source-supported design properties, still requiring implementation tests:**

- Welcome bytes are parsed before child output can be parsed.
- No command is typed into the user's shell, history, or editing buffer.
- No shell-specific dotfile edits, wrapper process, or first-prompt hook is needed.
- Shell detection, current zsh bootstrap, login semantics, job control, CWD, PATH, and exit handling remain on their current paths.
- Session creation is the trigger: splits, tabs, windows, restoration, and switching a pane back to terminal can create new eligible sessions; focus/reparenting and nested shells do not.
- Eligibility is sampled at creation. Acknowledgement affects later-created sessions; it does not recall already-created sessions or erase scrollback.

**Not guaranteed:**

- The welcome is visibly painted in a separate frame before shell startup.
- It remains visible after user startup code clears the screen, deletes scrollback, changes terminal modes, or starts a full-screen application.
- It appears after every shell's first prompt. No universal shell-independent first-prompt signal has been established.
- Existing capture is a scrollback export. Slate captures bounded current-screen text, so scrolled-away welcome content need not appear in capture.

If surviving shell clears/full-screen startup is a requirement, use native content outside the terminal grid instead of claiming terminal output can ensure this.

## Native-pane alternative: no engine changes

A native, nonmodal welcome area can be a sibling above the terminal inside its content wrapper. It must not cover the terminal grid or intercept terminal typing. Slate's `PaneContainer` already supplies stable native chrome around retained content (`Native/PaneContainer.swift:17–18,117–133`); terminal content controllers are constructed in `WorkspaceHost.reconcile` (`Native/WorkspaceHost.swift:1640–1643`). These are candidate composition points, not existing welcome slots.

Advantages: independent of every shell and integration mode, no launch delay, no VT/parser concern, not erased by terminal clears, and no engine dependency work. Explicit CLI welcome and acknowledgement can still share content/host state.

Tradeoffs: it is **not terminal output** and will not appear in terminal capture/scrollback; it consumes pane height; small panes need bounded/collapsible layout. Any dismissal/collapse behavior needs an explicit product decision rather than silently changing the proposed CLI acknowledgement semantics. Preserve `TerminalView` and session identity while resizing/reparenting; verify header hiding, inactive shading, focus, IME, zoom, drag/split sizing, and accessibility. Its different presentation should be explicit. The reassessment establishes that terminal output was not a user requirement, so this native option is now preferred.

## Alternatives evaluated and not recommended

- **Naive launcher with automatic detection:** Ghostty detects the first executable basename (`src/termio/shell_integration.zig:137–166`). This does not rule out all launchers: explicit shell selection plus a compiled exec launcher can preserve prepared arguments/environment without changing Ghostty. See the reassessment for target-aware `/bin/bash` handling and remaining verification.
- **Per-shell prompt/RC hooks:** practical for named shells but not an all-shell/integration-off solution; new shells require more maintained integrations.
- **`initial_input`, paste, or `terminal.send`:** input to the child, not output; risks executing text or polluting history/buffers.
- **Inject after surface creation or after a delay:** can interleave with prompts, TUI redraws or partially received VT sequences. A mutex protects memory, not semantic ordering. No safe universal timeout establishes readiness.
- **Open the exported TTY slave path and write:** still races child output and terminal mode changes, offers no startup ordering or first-prompt guarantee, and adds descriptor/process-lifetime handling. The subsequent reassessment includes an isolated PTY probe confirming direction and the absence of an ordering barrier.
- **Own/proxy the PTY or replace the renderer:** much larger architectural change. The inspected embedded surface uses the exec backend; it is not a ready-made external-PTY adapter.
- **VT-only `ghostty_terminal_vt_write`:** operates on a separate `GhosttyTerminal` handle, not a public handle to the live embedded surface's terminal state. Replacing the full surface stack is outside this feature's scope.

## Primary online sources

Online research supports the output-side approach; it does not verify a Slate implementation:

1. [WezTerm `pane:inject_output`](https://wezterm.org/config/lua/pane/inject_output.html): explicitly feeds output to the terminal, not input; warns that cursor movement can confuse running TUI programs. Supports preferring creation-time output over arbitrary live injection.
2. [iTerm2 session API](https://iterm2.com/python-api/session.html): distinguishes `async_inject(bytes)` (program output) from `async_send_text` (typed input).
3. [xterm.js Terminal API](https://xtermjs.org/docs/api/terminal/classes/terminal/): `write` feeds output; input/onData is the opposite direction. Parser completion is not the same as a completed repaint.
4. [Ghostty configuration reference](https://ghostty.org/docs/config/reference) and [shell integration](https://ghostty.org/docs/features/shell-integration): startup `input` is sent to the program; shell integration is shell-dependent, not a welcome-output mechanism. Current docs are supporting context, not a substitute for the pin.
5. Pinned upstream source: [surface C API](https://github.com/ghostty-org/ghostty/blob/554ea65867ffe34bb3e51e09bd016e154a1f9d7a/include/ghostty.h), [embedded runtime](https://github.com/ghostty-org/ghostty/blob/554ea65867ffe34bb3e51e09bd016e154a1f9d7a/src/apprt/embedded.zig), [output parser/startup](https://github.com/ghostty-org/ghostty/blob/554ea65867ffe34bb3e51e09bd016e154a1f9d7a/src/termio/Termio.zig), [exec startup](https://github.com/ghostty-org/ghostty/blob/554ea65867ffe34bb3e51e09bd016e154a1f9d7a/src/termio/Exec.zig), [core surface initialization](https://github.com/ghostty-org/ghostty/blob/554ea65867ffe34bb3e51e09bd016e154a1f9d7a/src/Surface.zig).

## Necessary future validation — not performed

- Engine tests for initial-output-only and output-plus-initial-input ownership, startup failure, immediate close, inherited/reloaded configuration not replaying, Unicode/control rejection, and bounded allocation/line count.
- Ordering against a child that immediately emits text, terminal queries and partial VT sequences. Welcome must remain before all child bytes and produce no unsolicited input.
- zsh, bash (including macOS `/bin/bash` with its existing integration limitations), fish, and a minimal shell, each with integration auto/off as applicable. Check non-default startup files, quoted paths and working directories, login flags, environment/PATH, signals/job control, child exit, and secure input.
- Authenticated zsh context and run/wait behavior remain unchanged. Do not claim the welcome extends automation support to other shells.
- New tabs/splits/windows/restoration/type replacement versus reparenting/focus/nested shells; acknowledgement races use creation-time cutoff.
- First actual pane-size reflow (the engine and host initially use provisional dimensions), narrow panes, Unicode wrapping, themes, capture, and screen-clearing/alternate-screen startup limitations.
- Existing `scripts/verify-shell.py`, `scripts/verify-context.py`, terminal lifecycle/run gates plus focused welcome/API/CLI/plugin/service parity gates. Add applicable gates to the verification manifest only when implemented.

## Product behavior remains separate from transport

Keep the proposed explicit welcome/read/reset operations and persisted host acknowledgement separate from the output mechanism. Missing acknowledgement can make existing installations eligible; app/copy updates must not silently reset an existing acknowledgement. Explicit welcome shows current bundled copy. Release announcements, if later desired, need their own state and presentation; this research does not authorize a What's New feature or any persistence/API implementation.
