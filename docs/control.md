# Local control protocol

The app exposes a private, per-instance Unix-domain stream socket. Terminals and managed backends receive `SLATE_TERM_SOCKET`; the bundled CLI handles connection and handshake. External tools pass `--socket PATH` or set the environment variable. Discovery is intentionally instance-specific, not a global command targeting an arbitrary running app.

The socket directory is private (0700), and the server verifies the connecting user's credentials with Darwin `LOCAL_PEERCRED`. Same-user access grants workspace/terminal control; this is not a sandbox against other processes running as that user. Never expose or proxy the socket to untrusted clients.

## Wire format

UTF-8 JSON-RPC 2.0 objects, one per newline. No HTTP, batch arrays, or binary framing. Send `hello` first on **each connection**:

```json
{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":1}}
{"jsonrpc":"2.0","id":2,"method":"context.get","params":{"scope":"global"}}
```

Wait for the matching handshake response before commands. Successful responses carry `result`; failures carry `{code,message}` and optional structured `data` in `error`, with the request ID. IDs may be integers, strings, or explicit null. A missing ID denotes a notification and receives no response. Prefer IDs for operations whose failure matters. Method parameters are objects.

Messages are limited to 1 MiB excluding newline. Per-peer pending queues are bounded to 64 messages/1 MiB; output is bounded too. Exceeding transport bounds closes the peer. Requests on one connection are processed in order; different connections progress independently. Use another connection while an event poll, navigation, or terminal run is waiting. Disconnect cancels owned asynchronous work, not already performed side effects or an already running shell command.

## Causation metadata

When `api.describe.causation.version` is `1`, requests may include `"metadata":{"version":1,"cause":"DELIVERY_CONTEXT"}` alongside `params`. Obtain the opaque reference from an event poll's `deliveryContext`; do not invent provenance or move it into command arguments. Unknown/malformed metadata is rejected, including explicit null. Handshakes do not accept metadata. Without metadata, a request starts independent work.

The CLI's `--cause` negotiates support and dispatches on the same handshaken connection, without reconnect/retry fallback. Administrative references work across same-user connections within the app epoch; page references are restricted to their issuing view/document. Registered plugins remain trusted controllers, not a sandbox. See [events](events.md#causation-and-loop-admission) for expiry, rate limits and recovery.

## Discovery and methods

```sh
slate-term command list
slate-term rpc workspace.get
slate-term rpc context.get --params '{"scope":"global"}'
```

See [agent API extensions](agent-api.md) for capability discovery, guarded self/workspace inspection, CLI routing/session rules and application settings writes. `workspace.get` and `layout.get` retain their legacy shapes; revisioned metadata uses `workspace.snapshot` and `pane.inspect`.

[Saved layouts](saved-layouts.md) add the shared `layouts.*` recipe library and pane-targeted `layout.configuration`. File updates use `expectedSavedLayoutRevision`; opening always creates a new window group. Capture/open optionally accept `expectedWorkspaceRevision`. These are separate from the live `layout.get` and native `windowId` contracts.

Workspace commands use `command.run` with an `id` from `command.list` and routing fields. Read operations include `workspace.get`, `tabs.list`, `panes.list`, `layout.get`, `context.get`, `config.get`, `appearance.get`, `skills.list`, `window.list/get`, `plugins.list/status/logs`. [Guarded layout operations](layout-api.md) document the shared pane/tab commands and stable native window targeting. The CLI provides typed wrappers for workspace mutations, configuration, [plugin registration and enable/disable/removal](plugins.md#shared-lifecycle-api), [events](events.md), and [terminal/browser automation](automation.md).

Per-pane bar visibility uses `command.run` IDs `pane.header.show`, `pane.header.hide` and `pane.header.toggle`. The CLI aliases are `panes show-header`, `panes hide-header` and `panes toggle-header`, with normal pane/tab routing and optional instance/session/workspace/layout guards. `api.describe.paneHeader` advertises support. Responses include `paneId`, `tabId`, `headerVisible` and standard commit fields. Show/hide are idempotent; toggle is not. No command is automatically retried. This hides only the pane's native header, never the pane, browser address bar or native tab bar. See [layout API](layout-api.md#pane-bar-visibility).

Pane/tab identities (`p1`, `t1`, etc.) are stable across layout changes, but a terminal's **session** changes on replacement/restoration. Capture `sessionId` from context and provide it for delayed terminal work. Explicit CLI pane/tab options override inherited identifiers; an explicit tab suppresses an inherited pane. Event filters deliberately do not inherit those targets.

Browser and Private Browser pages and subframes have no bridge. Both modes and the noninteractive `browser.clearData` / `browser.clearSiteData` operations are documented in [browser profiles](automation.md#browser-profiles-and-website-data). Native clearing commands ask for confirmation; API calls (including `command.run`) do not. Registered plugin main frames use the [same API](plugins.md) as CLI and service clients; differences are caller defaults, transport and lifetime, not capabilities. `shell.update` and shell run-input delivery are authenticated integration internals, not extension-owned context publication. Extensions publish their own context with custom events rather than spoofing native telemetry. Integration-only `debug.*` methods are unavailable in ordinary app launches.

## Manual background services

`plugins.service.start/stop/list/status/logs` are shared API operations, with `slate-term plugins service …` conveniences. Registration does not activate a service. Each launch has a private same-user endpoint bound to its public generation identity, not a bearer token or separate capability list. Ordinary hello replies include that identity; inherited service clients validate it on the same peer before dispatch and never silently discard their owner. Invalid repeated hello invalidates negotiation on both endpoint kinds. See [manual services](background-services.md) for schemas, readiness, bootstrap and teardown. Automatic startup/restart and enable/disable controls remain deferred.

## Failures and recovery

- `-32700`: JSON parse error; `-32600`: invalid request; `-32601`: unknown method; `-32602`: invalid parameters.
- `-32001`: handshake required; `-32002`: incompatible protocol version.
- `-32022`: resource/document/session closed or replaced; obtain fresh state before retrying.
- `-32024`: operation deadline/condition failure; do not assume side effects were undone.
- `-32031`: event cursor unavailable; explicitly resynchronize as described in [events](events.md).
- `-32055`: delivery context unavailable/expired/foreign; inspect state before starting new work.
- `-32056`: causal-depth limit; stop the feedback loop.
- `-32057`: automation mutation limit; bounded `data.retryAfterMilliseconds` indicates refill time, not permission to replay.
- `-32058`: operation admission unavailable.
- `-32059`: service generation unavailable or public routing context does not match; no owner-discarding fallback.

Other workspace, storage, shell-state and admission errors have descriptive messages. Do not automatically replay a mutation after disconnect, timeout or malformed response: it may already have taken effect. The CLI reports transport/response failures with `outcome: unknown`, not a clean rejection. Read current state and decide deliberately. Unknown shell context stays unknown; neither quiet output nor process-name sampling proves an idle prompt.

## Agent skill

The app ships the Slate Terminal agent skill (`skills/slate-terminal` in the repository). **Settings → AI Agents** and the **AI** menu install it for coding agents with one click. Install creates a symbolic link named `slate-terminal` in the agent's user skills folder. The link points to an app-managed copy under the app's state folder, which the app refreshes at launch while any link exists, so links survive app moves and pick up updates.

| ID | Folder | Read by |
| --- | --- | --- |
| `agents` | `~/.agents/skills` | The shared folder: Codex, Gemini CLI, Cursor, GitHub Copilot, OpenCode, Amp and others |
| `claude` | `~/.claude/skills` | Claude Code |
| `codex`, `cursor`, `gemini`, `copilot` | `~/.codex/skills`, `~/.cursor/skills`, `~/.gemini/skills`, `~/.copilot/skills` | That agent only |
| `opencode` | `~/.config/opencode/skills` | OpenCode |

Install in the shared folder plus Claude Code for most setups; installing in both the shared folder and an agent's own folder can show the skill twice. An existing file, folder or foreign link named `slate-terminal` is a conflict: install and uninstall fail with `-32050` and never replace or remove it. Uninstall removes only the link.

```sh
slate-term skill list --json
slate-term skill install --agent agents --agent claude
slate-term skill uninstall --agent claude
slate-term skill reveal        # command.run skills.reveal; shows the managed copy in Finder
```

`skills.list`, `skills.install {agents: [ID]}` and `skills.uninstall {agents: [ID]}` are shared API methods, so plugins and services can call them too. The command picker offers **Install Agent Skill…** (`skills.settings`) and **Open Agent Skill Folder** (`skills.reveal`). Integration runs link into `SLATE_TERM_AGENT_HOME`, or `agent-home` in the state folder, never the real home folder.

