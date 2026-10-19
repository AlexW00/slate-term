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

## Preserve the user's focus

Keep the user's active pane, tab and window focused while working. Change focus only when the user asks, or when the task requires an interaction that cannot work without it. Creating a pane or running commands in it does not require focusing it.

- Plugin startup, refresh and background updates must not request focus. Test intentional focus behavior only when the task requires it, using the fewest focus changes needed.
- Use explicit pane IDs for inspection, terminal commands and captures. Avoid `--active`, `panes focus`, `tabs focus`, `window.focus`, `presence focus` and app activation as routine setup.
- When splitting, read the source pane's `layoutRevision`, then use `slate-term panes split --pane SOURCE --right --focus-policy preserve --expected-layout-revision REVISION`. Keep the returned `paneId` and target it directly for subsequent calls. Current structural automation preserves focus by default; older builds may focus new panes, so pass the policy explicitly.
- Through the socket or plugin bridge, use `command.run` with `id: "pane.split"`, `focus: "preserve"` and the current `expectedLayoutRevision`. Use other operations' preserve-focus options where available.
- Split/tab/window creation and saved-layout opening accept `preserve` or `new`; pane moves accept `preserve` or `target`. Discover support before passing new options to an older build. Select `new` or `target` only for a requested or necessary focus change.
- Read the new terminal's state, shell and session with `panes inspect --pane NEW_PANE`; wait for its prompt, then use `terminal run --pane NEW_PANE --session-id SESSION --shell SHELL --command '…'`. Capture output with `terminal capture --pane NEW_PANE`.
- If focus is necessary, make the fewest changes needed. Do not focus a pane and immediately restore the old one as a workaround: both changes can interrupt the user.

## Prefer Slate's browser

When working inside Slate, use its browser panes and documented browser/web API for browsing, previews and UI checks by default. Discover the running app's capabilities and read the applicable browser-work guidance. Create a task-owned browser pane with focus preserved, use explicit pane IDs, and leave a requested preview open for the user.

Use another browser only when the user explicitly requests it, a higher-priority instruction requires it, or the task needs a capability or isolation boundary Slate cannot provide. Another browser tool or skill being available is not by itself a reason to switch. State the reason for a necessary fallback and follow that integration's instructions. A missing capability is not permission to bypass access or safety restrictions.

## Key concepts

- **Panes and tabs.** IDs such as `p1` and `t1` are stable slots. A terminal's `sessionId` changes when its shell is replaced. Pass `--session-id` or `sessionId` for delayed terminal work.
- **Tab names.** Discover `api.describe.tabTitle`. Use `tabs set-title --tab t2 --title 'Build'` / `tabs clear-title --tab t2`, shared `command.run tab.title.set/clear`, or page `workspace.tabs.setTitle/clearTitle`. Names persist independently of pane/document titles; trimmed empty input resets to `New Tab`. Limits: 100 characters / 1024 UTF-8 bytes, no controls. `tab.rename` opens a native editor, not an automation setter. Title changes advance workspace, not layout, revisions.
- **Implicit targeting.** Inside a pane, `SLATE_TERM_PANE_ID` and `SLATE_TERM_TAB_ID` are the default target. Explicit `--pane`/`--tab` override them; `--active` targets current focus. Stale IDs fail; they never fall back to the focused pane.
- **Move panes across windows.** Discover `api.describe.paneMovement`, `window.list` and `pane.inspect` destinations. `panes move --pane SOURCE --destination TARGET --right --expected-layout-revision SOURCE_TOKEN --expected-workspace-revision WORKSPACE_TOKEN` invokes shared `pane.move`; `workspace.panes.move(target, direction, params)` is equivalent. Source/destination must belong to this app. A sole-pane source tab closes safely; terminal/browser/pane/global-plugin live content stays intact. Tab-scoped plugin pages recreate in destination runtime scope (unsaved DOM may reset), with `contentRecreated` in the reply. Shared plugin data and the moved panel’s saved state/configuration remain intact. `tabId`/layout revision/path describe the destination. Inspect after an uncertain reply; do not replay.
- **Window presentation.** Discover `windowControls`. `windows frame|minimize|restore|fullscreen` targets explicit stable `windowId`, never inherited pane/focus. Only selected group members may change; frames must fit one visible screen. Fullscreen acceptance is asynchronous: poll `windows get` for settled state. No implicit app activation.
- **Web input.** Discover `webAutomation.actions`. Guarded `web focus|key|check|set-value` works for browser and registered-plugin panes. `key` dispatches synthetic events with limited Tab/activation/form defaults, not native editor typing or trusted user gestures. `check` uses a Boolean desired state; `set-value` uses canonical strings for supported typed inputs. Use fresh refs or paired view/document guards.
- **Warning preferences.** `warnings close|type --suppressed true|false` changes native prompt preferences only, not API `force` requirements or clipboard/OS consent.
- **Agent presence.** Every Slate CLI invocation by an AI agent must identify the agent with `SLATE_TERM_ACTOR` or `--actor` (for example `codex` or `claude`). With fresh-shell execution tools, begin **every command block** with `export SLATE_TERM_ACTOR=codex`; an export in an earlier tool call does not persist. An inline assignment such as `SLATE_TERM_ACTOR=codex slate-term …` covers only that one command. Alternatively, pass `--actor codex` on every invocation. Slate then shows the user a frame and tag on panes you touch. Add `--note "short reason"` (at most 80 characters) to calls where the why is useful, and use `presence hold --pane P --note ...` / `presence release --pane P` for multi-step work on one pane. Your own pane is never highlighted. See `api.describe.presence`.
- **Revisions and guards.** Mutations can carry `expectedWorkspaceRevision`, `expectedLayoutRevision` and other guards. On a conflict, read state again; do not replay blindly.
- **Unknown outcomes.** After a timeout or disconnect, a mutation may already have happened. Inspect state before retrying.
- **Terminals.** `terminal send` writes literal bytes. `terminal run` runs a command at an idle authenticated prompt, written in the pane's shell language: read `shell` from `context get` or `panes inspect` (zsh, bash or fish) and pass `--shell` so a different shell refuses instead of misreading it. Apple's bash 3.2 reports state but cannot run. `capture` is the current screen, not command stdout.
- **Plugins.** A manifest can add commands (executables), a panel (a web UI in a pane) and a manual background service. Registration trusts that code fully; it is not a sandbox. Discover `pluginPersistence`: `workspace.pluginData` saves durable shared data; `workspace.panelState` saves one panel’s restoration context independently of runtime scope. Preferences stay in TOML; layouts capture starting configuration, not live state. Save explicitly during editing, handle revision conflicts/save errors, and never rely on ephemeral `localStorage`. Read the authoring reference before choosing a store.
- **Events.** A bounded, resumable journal with cursors and topics (`host.*` for native facts). Treat events as invalidations and re-read state.
- **Configuration.** TOML at `~/.config/slate-term/config.toml` with live reload. Write through `config patch` or `plugins settings patch` with the revision you read.

For consistent identity across fresh tool shells, launch the agent with the variable already set, for example `SLATE_TERM_ACTOR=codex codex`. Child processes inherit it when the execution tool preserves the parent environment. This does not retrofit an already running agent: continue exporting it in every tool call, or pass `--actor` on each invocation. Do not set an agent identity globally for ordinary interactive shells or unrelated agents.

## References

| Task | Read |
| --- | --- |
| Build or debug a plugin: manifest, panel or service, bridge, events, storage, settings, theming, reload loop | [references/building-plugins.md](references/building-plugins.md) |
| Design or build plugin pane UI: tokens, components, layout rules | [references/ui/INDEX.md](references/ui/INDEX.md), then [references/ui/guidelines.md](references/ui/guidelines.md) |
| Automate an existing workspace from a shell or script | The discovery commands above, then the subcommand's `--help` |

The user's own instructions and design preferences take precedence over the defaults here.
