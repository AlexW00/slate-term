# Slate Terminal implementation gates

Based on Programmable macOS Workspace v0.2 (2026-10-13). Public naming chosen by Alex: **Slate Terminal**, `slate-term`, `SLATE_TERM_*`, `~/.config/slate-term`. Static plugin origins retain `plugin://`.

## Working rules

Each gate needs an observed failing check, a minimal implementation, and a passing check. Compilation alone is not runtime evidence. Do not proceed to later product phases while the earlier runtime gate is failing. Test fixtures use isolated storage and never touch the user's terminal sessions, configuration, or restored workspace.

## Gates

1. **Build and terminal lifecycle spike**: baseline Xcode build; exact Ghostty source + Zig pins; a real rendered terminal surface survives removal/reinsertion, resize, and movement between native windows without replacing the surface or killing its child. Verify actual terminal output, not just pointers. Ghostling is a VT-only example; use Ghostty's macOS app for the full surface API.
2. **Pure workspace model**: stable monotonic pane/tab/group IDs; directional binary splits, collapse on close, fractions, focus and terminal history; explicit native tab groups; validated versioned JSON restoration. Tests must cover rejected operations preserving state and ID allocation after restoration. Model remains provisional until gate 1 passes.
3. **Control vertical slice**: shared protocol, handshake, bounded newline framing, private per-instance Unix socket and same-user peer check; CLI builds/inspects a real native split tree. Negative cases include stale protocol, invalid IDs, malformed messages, and disconnected clients.
4. **Native workspace**: AppKit owns windows/tabs/split controllers; stable leaf controllers retain terminal surfaces; menu/keyboard/CLI share commands. Verify focus, native tab detach/reattach, divider writeback, close, zoom, and restoration in the running app.
5. **Phase 1 usability**: TOML configuration/reload, shell integration/context, bundled CLI/environment, tmux smoke checks. Unknown context stays unknown. No substitute terminal renderer.
6. **Phase 2**: registered web views, static hosting, origin/data-store isolation and bridge tests, then supervised process lifecycle including process-group cleanup.
7. **Phase 3**: context scopes, ordered resumable bounded events, generic terminal input/key taps/capture, authenticated shell run/condition waits and backend CLI/IPC access. Tool-specific interpretation (including tmux state/control protocols) belongs in user extensions, not core. Verify that boundary with an external adapter fixture.
8. **Phase 4**: browser navigation/evaluation/screenshots, bounded DOM snapshots and references, click/fill/select/scroll/wait, documented WebKit limits and no plugin bridge.

## Architecture issues to prove rather than assume

- Network.framework's public Unix connection API may not expose a peer descriptor for `LOCAL_PEERCRED`. Verify before choosing transport; prefer a small Darwin socket transport over claiming an unenforced credential check.
- A JavaScript object in an isolated `WKContentWorld` is not directly visible to page JavaScript. The eventual bridge needs an explicit, origin-gated page facade and an isolated implementation; isolation alone does not expose `window.workspace`.
- A custom WebKit scheme's storage behavior must be tested on supported macOS versions before promising localStorage/IndexedDB persistence.
- Ghostty's full embedding API is not the standalone `libghostty-vt` API. Pin the full engine source and retain its runtime resources.

Progress and actual evidence are recorded in `verification.md`.
