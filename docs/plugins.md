# Trusted plugins

A plugin can provide **commands, a panel, or both**. Commands do not require an open pane, web view, HTTP server, or background service. Existing panel manifests remain valid.

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

The Pane menu includes only plugins with a panel source. **Workspace → Plugin Commands** and **Settings → Keyboard Shortcuts** include contributed commands. Switching type destroys the live view; saved plugin data follows its declared scope. Registration replacement (`--replace`) requires that type's visible panes to be closed first. Unregister refuses active views unless `--force` is supplied. Unregister retains saved data.

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

`[plugins.<id>]` contains JSON-compatible values, limited to 64 KiB across at most 64 plugin namespaces. Quote IDs containing dots, e.g. `[plugins."acme.tools"]`. Plugins own defaults and semantic validation; there is no generated settings form/schema yet. As with other configuration, inline tables or multiline syntax require editing the file directly; use ordinary nested tables to keep native Settings edits available. Settings reload normally and are captured for each invocation. Panel pages can read their own settings with `await workspace.settings()`.

### Invocation, results, and lifetime

Each invocation captures the target pane/tab before launching (explicit routing wins; otherwise the active workspace is used). Commands may run with no open workspace, in which case pane/tab variables are absent. A nonterminal pane is valid context; use `context get` to resolve the active terminal before terminal operations. The environment includes:

- `SLATE_TERM_CLI`, `SLATE_TERM_SOCKET`, `SLATE_TERM_INSTANCE_ID`; the CLI's directory is prepended to `PATH`.
- `SLATE_TERM_PLUGIN_ID`, `SLATE_TERM_PLUGIN_INSTANCE` (a unique invocation ID), `SLATE_TERM_COMMAND_ID`.
- `SLATE_TERM_TAB_ID`, `SLATE_TERM_PANE_ID`, when a target exists. CLI calls inherit these, so focus changes do not redirect the script.
- `SLATE_TERM_COMMAND_PARAMS`: JSON invocation parameters, including resolved routing (at most 16 KiB).
- `SLATE_TERM_PLUGIN_SETTINGS`: that plugin's settings as a JSON object.

Inherited/manifest `SLATE_TERM_*` fields are discarded before authoritative values are added. Shell authentication tokens and test flags are not forwarded. Command processes have no page bridge; they use the CLI/socket. A panel can invoke these commands using `workspace.command(id, params, {signal})` too; its bridge allows up to 300 seconds for a plugin command.

`command.run` waits asynchronously for completion and returns the invocation ID, state, exit code, and bounded stdout/stderr tails. Nonzero exit, signal, launch failure, timeout, or cancellation returns an RPC error containing the invocation ID; inspect `plugins status <id>` and `plugins logs --instance-id <invocation-id>`. The typed `command run` CLI allows a 300-second transport timeout; raw socket clients must allow longer than the manifest deadline. Generic `rpc` retains its default transport timeout.

One invocation per command may run at a time (duplicates fail rather than queue); at most 16 command processes run concurrently. The last 64 invocations are retained in memory, with up to 64 KiB per output stream. Commands are never automatically restarted or retried. Closing a pane does not cancel an independent command, but subsequent CLI operations against stale targets fail. Caller disconnect/page cancellation, timeout, replacement/unregister, and app shutdown stop the owned process group. The supervisor also watches app death. Deliberately daemonizing into another process group escapes containment and is unsupported. Command stdin is `/dev/null`; interactive prompts are not supported.

`plugins restart` remains a panel-service operation; use `command run` for a fresh invocation. Do not blindly repeat a failed command: earlier workspace mutations may already have taken effect. Registration trusts executable code with your user's ordinary filesystem/process access, not just workspace APIs.

See [planned follow-ups](plugin-followups.md) for the command picker, UI/CLI parity, and hooks/API audits.

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

### Pane header

Each pane has a common native header: type, custom title, and close button. Plugins can use their document title or explicitly control the header:

```js
await workspace.setTitle("Reviewing README.md");
await workspace.setTitle(null); // use document.title again
```

An explicit plugin title is limited to 512 UTF-8 bytes and resets on a new document. Each view has its own title, even when it shares a tab/global instance. A user can override it by clicking the header title once and editing inline (Enter or blur saves; Escape cancels). Manual names persist with the workspace and take priority over both document and plugin titles. Plugin updates are still accepted; clearing the manual name reveals the latest automatic title. Close uses the normal pane-close command; it does not implicitly close sibling panes.

### Events and cancellation

```js
const stop = await workspace.subscribe(event => refresh(), {
  topics: ["host.context.*", "host.workspace.*"],
  onError: error => showError(error)
});
await workspace.emit("notes.updated", { key: "draft" });
stop();
```

Subscriptions follow the owning tab (or all tabs for global instances); directed delivery addresses a logical `instanceId`. Native source attribution cannot be supplied by page code. Unsubscribe, document navigation and view closure cancel outstanding native polls. Generic `workspace.call(method, params, {signal})` also supports `AbortSignal`.

See [workspace events](events.md) for bounds, replay, explicit cursor resynchronization, and cached-history lifecycle behavior.

## Supervision and limits

Backend stdout/stderr are bounded, with a retained 64 KiB log tail. Crashes use bounded exponential restart delays. Readiness failure stops the owned process group and is visible in status; Reload can retry. Concurrent explicit restarts coalesce rather than racing for the same port.

The reported PID is the bundled supervisor/group leader. Actual service exit codes are recorded in logs; the supervisor deliberately kills its own group to remove remaining descendants. It watches GUI death, including SIGKILL. Processes that deliberately daemonize into another group/session escape this containment; plugins must not do so.

The bridge bounds requests and responses; storage is limited to 1 MiB and 1,024 keys. Files are private and atomically replaced under the app's state directory. Atomic replacement is not a power-loss durability guarantee.
