---
name: slate-terminal
description: Use Slate Terminal, a macOS terminal workspace with split panes, plugins and a shared automation API. Use when driving or automating a running Slate Terminal (slate-term CLI, control socket, panes, tabs, terminal run/capture, events, layouts, palettes, config), when writing Slate plugins (commands, panels, background services, the window.workspace bridge), or when designing plugin pane UI.
---

# Slate Terminal

Slate Terminal is a native macOS terminal workspace built on the Ghostty engine. It has tabs, nested split panes, browser panes and plugin panes. One trusted automation API is shared by three clients:

- the bundled `slate-term` CLI (on `PATH` inside Slate terminals),
- the private per-instance Unix socket (newline-delimited JSON-RPC 2.0),
- registered plugin pages, through `window.workspace`, and background services, through the CLI or socket.

All three see the same methods and commands. Differences are transport, caller defaults and lifetime, not permissions.

## Discover capabilities at runtime

The API grows often. Ask the running app instead of relying on memory or on this file.

```sh
slate-term --help                    # subcommand list
slate-term <subcommand> --help       # actions and flags, e.g. panes, terminal, plugins, events
slate-term api describe --json       # api.describe: methods, commands, guards, bounds, feature flags
slate-term command list --json       # command.run ids (native menu/picker commands plus plugin commands)
slate-term context inspect --self --json   # who and where the caller is
slate-term workspace snapshot --json       # revisioned topology with an event cursor
slate-term rpc METHOD --params '{...}'     # call any catalog method directly
```

- `api.describe` is the source of truth. Its `methods` list matches the page bridge's `workspace.methods`. Feature entries such as `webAutomation`, `causation`, `workspaceCommit` and `backgroundServices` say what the host supports.
- In a plugin page, use `await workspace.api()` (same as `api.describe`), `workspace.methods`, generated `workspace.rpc[METHOD](params, options)`, and the generic `workspace.call(method, params, {signal, cause})`.
- All CLI output is JSON. With `--json`, errors go to stderr as one JSON object with a nonzero exit status.
- Outside a Slate terminal, pass `--socket PATH` or set `SLATE_TERM_SOCKET`.
- Some features may be newer than the running build, for example `appearance.get`. Check `api describe` before relying on them.

## Key concepts

- **Panes and tabs.** IDs such as `p1` and `t1` are stable slots. A terminal's `sessionId` changes when its shell is replaced. Pass `--session-id` or `sessionId` for delayed terminal work.
- **Implicit targeting.** Inside a pane, `SLATE_TERM_PANE_ID` and `SLATE_TERM_TAB_ID` are the default target. Explicit `--pane`/`--tab` override them; `--active` targets current focus. Stale IDs fail; they never fall back to the focused pane.
- **Revisions and guards.** Mutations can carry `expectedWorkspaceRevision`, `expectedLayoutRevision` and other guards. On a conflict, read state again; do not replay blindly.
- **Unknown outcomes.** After a timeout or disconnect, a mutation may already have happened. Inspect state before retrying.
- **Terminals.** `terminal send` writes literal bytes. `terminal run` runs a zsh command at an idle authenticated prompt. `capture` is the current screen, not command stdout.
- **Plugins.** A manifest can add commands (executables), a panel (a web UI in a pane) and a manual background service. Registration trusts that code fully; it is not a sandbox.
- **Events.** A bounded, resumable journal with cursors and topics (`host.*` for native facts). Treat events as invalidations and re-read state.
- **Configuration.** TOML at `~/.config/slate-term/config.toml` with live reload. Write through `config patch` or `plugins settings patch` with the revision you read.

## References

| Task | Read |
| --- | --- |
| Build or debug a plugin: manifest, panel or service, bridge, events, storage, settings, theming, reload loop | [references/building-plugins.md](references/building-plugins.md) |
| Design or build plugin pane UI: tokens, components, layout rules | [references/ui/INDEX.md](references/ui/INDEX.md), then [references/ui/guidelines.md](references/ui/guidelines.md) |
| Automate an existing workspace from a shell or script | The discovery commands above, then the subcommand's `--help` |

The user's own instructions and design preferences take precedence over the defaults here.
