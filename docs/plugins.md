# Trusted plugins

A plugin can provide **commands, a panel, a manual background service, or a combination**. Commands do not require an open pane, web view, HTTP server, or background service. Existing panel manifests remain valid. [Manual background services](background-services.md) have distinct lifetimes and shared-API start/stop controls; registration never activates them.

Registration grants the loaded code access to terminal content and workspace commands. Register only code and origins you trust. Plugins are not a sandbox for untrusted code; ordinary Browser panes have no plugin bridge.

Use **Settings → Plugins → Register Plugin…**, or:

```sh
slate-term plugins register --manifest /absolute/path/plugin.json
slate-term panes type --pane p2 --type notes --force
slate-term plugins status notes
slate-term plugins logs --instance-id INSTANCE_ID
slate-term plugins restart notes
slate-term plugins unregister notes --force
```

The pane-header type dropdown includes only plugins with a panel source. **Workspace → Plugin Commands**, the **⌘K command picker**, and **Settings → Keyboard Shortcuts** include contributed commands. Switching type destroys the live view; saved plugin data follows its declared scope. Registration replacement (`--replace`) requires that type's visible panes to be closed first. Unregister refuses active views unless `--force` is supplied. Unregister retains saved data.

## Command-only plugins

```json
{
  "id": "tools",
  "title": "My Tools",
  "commands": [{
    "id": "split-left",
    "title": "Split Left",
    "executable": "/bin/sh",
    "arguments": ["/absolute/path/to/split-left.sh"],
    "timeoutSeconds": 30
  }]
}
```

`split-left.sh` can call the bundled CLI directly:

```sh
#!/bin/sh
set -eu
"$SLATE_TERM_CLI" command run split.left
```

Register the manifest normally, then invoke it without opening a plugin panel:

```sh
slate-term command list
slate-term command run plugin.tools.split-left
```

Commands have namespaced IDs `plugin.<plugin-id>.<command-id>`. A local command ID is a lowercase letter followed by lowercase letters, digits, or hyphens (up to 64 bytes). A manifest supports at most 32 unique commands. Commands can also be included alongside a panel's existing `source`, `scope`, and `process` fields. A plugin without `source` must have commands and cannot declare a managed HTTP `process`. Panel `scope` does not control command lifetime.

Each command declares an absolute `executable`, optional literal `arguments` (default `[]`), absolute `directory`, `environment` (string map), and `timeoutSeconds` (default 30; 0.1–295). Nothing is implicitly shell-expanded or evaluated. Invoke `/bin/sh` or another interpreter explicitly for scripts. Without `directory`, the command inherits the app's working directory, **not** a terminal's current directory. Use `context get` when terminal context is needed.

### Native frame buttons

Plugins may contribute native pane-header buttons immediately left of Close. Add `headerButtons` to either a command-only or mixed manifest:

```json
"headerButtons": [
  {
    "id": "split-left",
    "title": "Split Left",
    "symbol": "rectangle.lefthalf.inset.filled",
    "command": "split-left",
    "paneTypes": ["*"]
  }
]
```

- `command` is a **local command ID declared by this same plugin**, not arbitrary JavaScript or a cross-plugin/built-in command ID. It uses the existing supervised command runtime. To wrap a built-in operation, invoke it through the CLI from the command script.
- `paneTypes` defaults to `["*"]` for every pane type. Use `["terminal"]`, `["browser"]`, `["private-browser"]`, a combination such as `["terminal", "browser", "private-browser"]`, or exact registered widget IDs such as `["acme.notes"]`. These are type IDs, not pane instance IDs or display titles. A target widget may be registered later. Wildcards cannot be mixed with explicit types. Selectors control button visibility, not permission to invoke the command through other entry points.
- `id` uses the command-local identifier grammar (lowercase letter, then lowercase letters/digits/hyphens; at most 64 bytes). IDs must be unique within the plugin, with at most **8 buttons**. `title` is required, up to 100 characters without control characters; it supplies the tooltip/accessibility label, prefixed by the plugin title. `symbol` is an SF Symbols name (up to 128 ASCII letters/digits/dots/hyphens, lowercase); unavailable system symbols use a generic plugin icon. No remote/custom images are loaded.
- The host preserves registration/button order, shows up to three direct buttons, and puts remaining actions in a native **More Plugin Actions** menu as the pane narrows. Below 180 points, contributions are hidden to preserve the structural controls; their commands remain available through the picker/menu/shortcuts. The title remains centered across the full pane.
- A click captures the **clicked pane and its current tab**, even if another pane/window is focused. Commands receive the normal `SLATE_TERM_PANE_ID`/`SLATE_TERM_TAB_ID`, settings, and CLI environment. Rendering buttons does not start a plugin process or require a plugin panel to be open. Busy actions are disabled until the invocation finishes.
- Register through the existing `plugins.register` RPC or `slate-term plugins register --manifest …`. Manifest contributions persist across app launches and update existing/new headers on registration, replacement, pane-type changes, and removal. Replacement/unregister removes old buttons and cancels owned running commands using the existing policy. A failed registration leaves the previous catalog/UI intact. There is no document-owned JavaScript callback registration API in this version.

See [`examples/command-plugin/plugin.json`](../examples/command-plugin/plugin.json) for a complete command-backed button. `scripts/verify-plugin-header-buttons.py` exercises native rendering, filtering, routing, busy state, overflow, persistence and cleanup without using the user's clipboard.

### Shortcuts and settings

Bind commands through the existing shortcut recorder or configuration:

```toml
[keybind]
"cmd+shift+b" = "plugin.tools.split-left"

[plugins.tools]
side = "left"
width = 0.25
```

Plugins have no default shortcuts in this version. The host dispatches bindings across terminal/browser/plugin panes while Slate is active; these are **not OS-wide hotkeys**. Bindings and settings survive unregister/re-register. Missing plugin commands are inactive (do not consume keys), appear as unavailable in shortcut settings, and are listed in `config.get.unavailableCommands`. Unknown built-in commands and malformed plugin command IDs are still configuration errors. Reset clears a plugin command's binding.

`[plugins.<id>]` contains JSON-compatible values, limited to 64 KiB across at most 64 plugin namespaces. Quote IDs containing dots, e.g. `[plugins."acme.tools"]`. Plugins own defaults and semantic validation; there is no generated settings form/schema yet. Settings reload normally and are captured for each invocation. Panel pages retain the simple live read `await workspace.settings()`. For versioned editing, use `workspace.pluginSettings.get()` and `workspace.pluginSettings.patch(operations, writeRevision)`; these conveniences default to the page's namespace; `workspace.call` with `plugins.settings.get` or `plugins.settings.patch` and an explicit `id` selects another namespace. CLI equivalents are `plugins settings get PLUGIN-ID` and `plugins settings patch PLUGIN-ID --operations '[...]' --expected-write-revision TOKEN`.

Patches contain at most 32 `set`/`delete` operations with literal string-array paths and use a whole-source optimistic revision. Set replaces the addressed value/subtree, not a recursive merge; delete omits `value`. JSON null, overlapping paths, whole-namespace replacement and traversing into arrays/scalars are rejected. Array values may be replaced as a whole. The shared source editor preserves unrelated settings/comments and supports ordinary nested tables and arrays of tables; unsupported multiline or standalone inline-table source is rejected without rewriting it. Valid strings containing quote characters are not mistaken for multiline syntax. See [the agent API](agent-api.md#own-plugin-settings) for examples and conflict behavior.

Successful applied namespace changes publish `host.plugin.settings.changed` to that plugin's live logical instances, without values. Default page/service subscriptions receive their own directed invalidations; every trusted client may explicitly select other recipients or all events. Invocation environments remain launch snapshots—long-lived consumers must read current settings after notification.

### Invocation, results, and lifetime

Each invocation captures the target pane/tab before launching (explicit routing wins; otherwise the active workspace is used). Commands may run with no open workspace, in which case pane/tab variables are absent. A nonterminal pane is valid context; use `context get` to resolve the active terminal before terminal operations. The environment includes:

- `SLATE_TERM_CLI`, `SLATE_TERM_SOCKET`, `SLATE_TERM_INSTANCE_ID`; the CLI's directory is prepended to `PATH`.
- `SLATE_TERM_PLUGIN_ID`, `SLATE_TERM_PLUGIN_INSTANCE` (a unique invocation ID), `SLATE_TERM_COMMAND_ID`.
- `SLATE_TERM_TAB_ID`, `SLATE_TERM_PANE_ID`, when a target exists. CLI calls inherit these, so focus changes do not redirect the script.
- `SLATE_TERM_COMMAND_PARAMS`: JSON invocation parameters, including resolved routing (at most 16 KiB).
- `SLATE_TERM_PLUGIN_SETTINGS`: that plugin's settings as a JSON object.

Inherited/manifest `SLATE_TERM_*` fields are discarded before authoritative values are added. Shell authentication tokens and test flags are not forwarded. Command processes have no page bridge; they use the CLI/socket. A panel can invoke these commands using `workspace.command(id, params, {signal})` too; its bridge allows up to 300 seconds for a plugin command.

`command.run` waits asynchronously for completion and returns the invocation ID, state, exit code, and bounded stdout/stderr tails. Nonzero exit, signal, launch failure, timeout, or cancellation returns an RPC error containing the invocation ID; inspect `plugins status <id>` and `plugins logs --instance-id <invocation-id>`. The typed `command run` CLI allows a 300-second transport timeout; raw socket clients must allow longer than the manifest deadline. Generic `rpc` retains its default transport timeout.

One invocation per command may run at a time (duplicates fail rather than queue); at most 16 command process slots are occupied concurrently. Unconfirmed cleanup retains its slot and diagnostic record, even after the invocation reports a terminal state. Status/results expose `cleanupPending`; confirmed reaping releases the slot without emitting a second finished event. At most 64 invocation records are retained in memory, with up to 64 KiB per output stream. Commands are never automatically restarted or retried. Closing a pane does not cancel an independent command, but subsequent CLI operations against stale targets fail. Caller disconnect/page cancellation, timeout, replacement/unregister, and app shutdown stop the owned process group. The supervisor also watches app death. Deliberately daemonizing into another process group escapes containment and is unsupported. Command stdin is `/dev/null`; interactive prompts are not supported.

`plugins restart` remains a panel-service operation; use `command run` for a fresh invocation. Do not blindly repeat a failed command: earlier workspace mutations may already have taken effect. Registration trusts executable code with your user's ordinary filesystem/process access, not just workspace APIs.

See the [command picker](command-picker.md) and [follow-up status and capability audits](plugin-followups.md) for UI/CLI parity and hooks/API boundaries.

## Panel manifest

A static panel:

```json
{
  "id": "notes",
  "title": "Notes",
  "scope": "tab",
  "source": {
    "kind": "directory",
    "path": "/absolute/path/to/notes",
    "entry": "index.html"
  }
}
```

Static modules/assets are served under `plugin://notes/`. Paths cannot escape the registered root; hidden components and escaping symlinks are rejected. Only regular files up to 16 MiB are served. The directory owner is trusted: this is not a filesystem sandbox against an author changing files concurrently.

A managed HTTP server:

```json
{
  "id": "dashboard",
  "title": "Dashboard",
  "scope": "global",
  "source": { "kind": "url", "url": "http://127.0.0.1:0/" },
  "process": {
    "executable": "/absolute/path/to/server",
    "arguments": ["--port", "{port}"],
    "directory": "/absolute/path/to/project",
    "environment": {},
    "restartLimit": 3,
    "readyTimeoutSeconds": 10
  }
}
```

Port `0` allocates a stable ephemeral port for that logical instance. The exact argument `{port}` is replaced with its port; other arguments are literal. The server also receives `SLATE_TERM_PLUGIN_HOST`, `SLATE_TERM_PLUGIN_PORT`, `SLATE_TERM_PLUGIN_ID`, and `SLATE_TERM_PLUGIN_INSTANCE`. Use port `0` for independent pane/tab instances rather than making them contend for one fixed port.

Managed servers must use HTTP on `127.0.0.1`. Readiness requires a same-origin successful HEAD response and a listening IPv4 socket owned by the managed process group. Redirects outside the registered origin are not followed. Ownership inspection is bounded to 64 group members and 512 descriptors per member; unusually large servers can fail readiness rather than bypass this check.

Without `process`, URL sources accept HTTPS or loopback HTTP. Registering a URL trusts that entire origin, including scripts it loads.

## Managed backend integration

A managed process receives authoritative connection/identity fields:

- `SLATE_TERM_CLI`: absolute path to the bundled CLI (also prepended to `PATH`).
- `SLATE_TERM_SOCKET`: this app instance's private JSON-RPC socket.
- `SLATE_TERM_INSTANCE_ID`, `SLATE_TERM_PLUGIN_ID`, `SLATE_TERM_PLUGIN_INSTANCE`, `SLATE_TERM_PLUGIN_SCOPE`.
- `SLATE_TERM_TAB_ID` for pane/tab instances; `SLATE_TERM_PANE_ID` only for pane instances. These identify the plugin's context, **not necessarily a terminal**.

Reserved `SLATE_TERM_*` values from inherited environments and manifests are discarded before these fields are assigned. Shell-report tokens and test-mode settings are not forwarded.

Backends can invoke the CLI directly with argument arrays, or use the documented socket protocol. Read `context get` to resolve the active terminal, then use its `paneId` and `sessionId`:

```text
SLATE_TERM_CLI context get
SLATE_TERM_CLI panes send --pane PANE --session-id SESSION --text TEXT
SLATE_TERM_CLI panes capture --pane PANE --session-id SESSION
```

Here `SLATE_TERM_CLI` means executing the environment variable's path, not a literal command name. `--session-id` rejects stale work after a pane's terminal has been replaced; the bridge supports the same `sessionId` input parameter. Input is literal UTF-8, including control characters—not shell-escaped text or bracketed paste.

A backend can run its own local tools/control protocols, interpret their results, and publish custom context using `events emit`. Direct the event to `SLATE_TERM_PLUGIN_INSTANCE` to deliver it to that instance's subscribed views. Backend socket events are truthfully attributed as `client`, not forged native telemetry; page bridge emissions have native-assigned `plugin` provenance.

For example, tmux users can implement discovery, control-mode clients, inner-pane capture and prompt interpretation entirely in an extension. Core does not recognize tmux commands or infer its state. `scripts/verify-extension-interop.py` exercises such an external adapter against a private test server.

## Scope and lifetime

- `pane` (default): separate instance for each pane, stopped when its view is removed.
- `tab`: views within one tab share an instance, which lasts until that tab closes.
- `global`: one instance per registered type, created on first use and retained until app shutdown or unregister.

Every visible pane has a fresh web view. Logical instances share their own ephemeral WebKit data store and private key/value store. Data files persist across app launches; browser/DOM history is not restored. Pane and tab IDs determine persisted storage scope.

## Page API

The main frame receives `window.workspace`. Native access checks the current view, main frame, registered origin and document lifetime. Other-origin navigation is blocked.

```js
const context = await workspace.context();
await workspace.terminal.send("printf 'hello\\n'\r");
const screen = await workspace.terminal.capture();
await workspace.terminal.key("ctrl+c");
const result = await workspace.terminal.run("printf 'hello\\n'");
await workspace.terminal.wait({ contains: "READY", timeoutMilliseconds: 5000 });
await workspace.command("split.right");
await workspace.storage.set("draft", { text: "メモ" });
const draft = await workspace.storage.get("draft");
await workspace.storage.delete("draft");
```

Terminal operations use the active terminal in the plugin's context; an explicit terminal `pane` overrides that history. A nonterminal focus does not erase it. Run/wait accept `{signal}` as a final options argument. Run requires authenticated zsh prompt/empty-buffer checks; it is not a generic TUI command runner. See [automation](automation.md) for limits, deadlines and the distinction between current-screen text and command stdout. `workspace.plugin` contains the type ID, logical `instanceId`, `viewId`, `paneId`, and scope.

Guarded pane split/move/resize, manual titles and native tab rearrangement are available through `workspace.panes`, `workspace.layout` and `workspace.tabs`; see [layout/page adapters](layout-api.md#registered-page-adapters). They use captured/live validated targets and explicit revisions rather than retargeting current focus. Window operations are available through the same `workspace.call`/`command.run` route.

### Saved layouts

Panel manifests may declare `layoutFields` for per-pane starting configuration. `workspace.layoutConfiguration(params, options)` reads these values, defaulting to this pane or accepting an explicit pane. `workspace.layouts` exposes the same recipe library, guarded file updates, capture, new-window opening, launcher creation and startup status as CLI/service clients. Panel scope supplies context, not a restriction on explicit cross-window access. See [saved layouts](saved-layouts.md) for schemas, helper signatures and whole-window-group targeting.

### Structured web interaction

`workspace.web.get/snapshot/click/fill/select/scroll/wait/screenshot(params, {signal, cause})` reuse the same guarded automation as browser panes. They target this pane by default or an explicit `pane`; cross-pane interaction is intentional for trusted registered controllers. Selector mutations require paired `expectedViewId`/`expectedDocumentId`, while opaque snapshot refs bind both identities. These public automation IDs are separate from bridge document credentials and initialize without a page API call. Trusted pages can use screenshot output for ready, attached browser/plugin panes even in inactive native tabs, without changing selection/focus (the `screenshotReady` field returned by `workspace.web.get(...)` describes sampled eligibility separately from `renderable`). DOM operations still require visibility, and zoom-detached panes remain unavailable. Pages can also use the generated `workspace.browser` namespace for browser navigation/evaluation. Arbitrary evaluation is still browser-only, not a plugin-document operation. Browser and Private Browser share these automation APIs. `workspace.browser.clearData({})` clears the app-wide persistent profile, and `clearSiteData({pane,url})` clears the selected browser's site group, including a private store; both are noninteractive and available to every trusted client. See [profiles and deletion scope](automation.md#browser-profiles-and-website-data). `workspace.methods` and generated `workspace.rpc[METHOD]` cover the full shared catalog; `workspace.call` remains compatible. See [shared web automation](automation.md#shared-web-panes) for renderability, cancellation, platform-capacity and stale-document rules.

### Theme

Registered panel pages follow the terminal palette without page code. Before page scripts run, the host sets CSS variables on `<html>` in the main frame: `--st-bg`, `--st-fg`, `--st-cursor`, `--st-selection-bg`, `--st-selection-fg`, `--st-ansi-0` … `--st-ansi-15`, `--st-font-mono` and `--st-font-mono-size`. It also sets `data-appearance` and `color-scheme` to the palette's own tone (`light` or `dark`). It updates them in the live page when the palette, light/dark slot or terminal font changes. Subframes and browser panes receive nothing. The web view's under-page background uses the palette background, so loading does not flash white.

```js
const theme = await workspace.appearance.get();   // same result as appearance.get
const stop = await workspace.appearance.onChange(() => redrawChart());
```

`onChange` subscribes to `host.appearance.changed`; re-read `appearance.get` for current values. The [plugin UI kit](../skills/slate-terminal/references/ui/INDEX.md) derives all its tokens from these variables. See [theme API](theme-api.md) for the result shape.

### Pane header

Each pane has a common native header: type, custom title, optional contributed command buttons, and Close. **Copy Pane ID** is now a stock command (`pane.copyID`) in the picker/Workspace menu rather than a permanent header button. Plugins can use their document title or explicitly control the header:

```js
await workspace.setTitle("Reviewing README.md");
await workspace.setTitle(null); // use document.title again
```

An explicit plugin title is limited to 512 UTF-8 bytes and resets on a new document. Each view has its own title, even when it shares a tab/global instance. A user can override it by clicking the header title or invoking `pane.rename` to open an anchored popover (Return/Rename saves; Escape, Cancel, or clicking outside cancels). Manual names persist with the workspace and take priority over both document and plugin titles. `workspace.panes.setTitle(title, params)` / `clearTitle(params)` set/clear this manual override; unlike `workspace.setTitle`, they are not automatic per-document title updates. Plugin updates are still accepted; clearing the manual name reveals the latest automatic title. Close uses the normal pane-close command; it does not implicitly close sibling panes.

Pane bar visibility is slot state, independently of document titles. Use `workspace.panes.hideHeader(params, options)`, `showHeader(params, options)` or `toggleHeader(params, options)` (normal `{pane, tab, expectedInstanceId, expectedAnchorSessionId, expectedWorkspaceRevision, expectedLayoutRevision}` targeting/guards; final `{signal, cause}`). These call shared `pane.header.*` commands, available identically through CLI/services. Hiding removes contributed header buttons too; their commands remain accessible through the picker/menu/shortcuts. It does not retire or navigate the document. Read `pane.inspect.headerVisible` for state. Show the bar before using native rename/type/drag controls; programmatic manual title changes remain available while hidden.

### Events and cancellation

```js
const stop = await workspace.subscribe(event => refresh(), {
  topics: ["host.context.*", "host.workspace.*"],
  onError: error => showError(error)
});
await workspace.emit("notes.updated", { key: "draft" });
stop();
```

Subscriptions follow the owning tab (or all tabs for global instances); directed delivery addresses a logical `instanceId`. Native source attribution cannot be supplied by page code. Unsubscribe, document navigation and view closure cancel outstanding native polls. Generic `workspace.call(method, params, {signal, cause})` supports cancellation and explicit event causation. Mutation helpers accept equivalent final options; `emit` accepts them alongside routing options. Pass `event.deliveryContext` as `cause` for event-triggered work. References are view/document-bound, and all views of a plugin share its mutation budget. See [causation and loop admission](events.md#causation-and-loop-admission).

See [workspace events](events.md) for bounds, replay, explicit cursor resynchronization, and cached-history lifecycle behavior.

### Reloading a panel

Plugin content fills its pane without a native status/reload footer. With a plugin focused, choose **Reload Plugin** in ⌘K or the Workspace menu. The same bindable command is available to CLI, page and service clients:

```sh
slate-term command run plugins.reload --pane p2
```

```js
await workspace.command('plugins.reload', {pane: 'p2'});
```

The command captures/resolves a plugin pane using normal pane/tab routing and guards; stale or non-plugin targets fail rather than falling back to focus. A ready instance reloads only that view’s document. An unready instance retries its logical backend (shared views follow its normal scope). Replies are `{paneId,reloading:true}`: acceptance, not proof that the document/backend is ready. Reload retires document-bound requests, so self-reloading pages may not receive their reply. Read `web.get` / `plugins.status` for readiness and diagnostics. This is distinct from `plugins.restart`, which restarts all active backend instances for a registered type.

## Supervision and limits

Backend stdout/stderr are bounded, with a retained 64 KiB log tail. Crashes use bounded exponential restart delays. Readiness failure stops the owned process group and is visible in status; Reload can retry. Concurrent explicit restarts coalesce rather than racing for the same port.

The reported PID is the bundled supervisor/group leader. Actual service exit codes are recorded in logs; the supervisor deliberately kills its own group to remove remaining descendants. It watches GUI death, including SIGKILL. Processes that deliberately daemonize into another group/session escape this containment; plugins must not do so.

The bridge bounds requests and responses; storage is limited to 1 MiB and 1,024 keys. Files are private and atomically replaced under the app's state directory. Atomic replacement is not a power-loss durability guarantee.
