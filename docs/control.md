# Local control protocol

The app exposes a private, per-instance Unix-domain stream socket. Terminals and managed backends receive `SLATE_TERM_SOCKET`; the bundled CLI handles connection and handshake. External tools pass `--socket PATH` or set the environment variable. Discovery is intentionally instance-specific, not a global command targeting an arbitrary running app.

The socket directory is private (0700), and the server verifies the connecting user's credentials with Darwin `LOCAL_PEERCRED`. Same-user access grants workspace/terminal control; this is not a sandbox against other processes running as that user. Never expose or proxy the socket to untrusted clients.

## Wire format

UTF-8 JSON-RPC 2.0 objects, one per newline. No HTTP, batch arrays, or binary framing. Send `hello` first on **each connection**:

```json
{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":1}}
{"jsonrpc":"2.0","id":2,"method":"context.get","params":{"scope":"global"}}
```

Wait for the matching handshake response before commands. Successful responses carry `result`; failures carry `{code,message}` in `error`, with the request ID. IDs may be integers, strings, or explicit null. A missing ID denotes a notification and receives no response. Prefer IDs for operations whose failure matters. Method parameters are objects.

Messages are limited to 1 MiB excluding newline. Per-peer pending queues are bounded to 64 messages/1 MiB; output is bounded too. Exceeding transport bounds closes the peer. Requests on one connection are processed in order; different connections progress independently. Use another connection while an event poll, navigation, or terminal run is waiting. Disconnect cancels owned asynchronous work, not already performed side effects or an already running shell command.

## Discovery and methods

```sh
slate-term command list
slate-term rpc workspace.get
slate-term rpc context.get --params '{"scope":"global"}'
```

Workspace commands use `command.run` with an `id` from `command.list` and routing fields. Read operations include `workspace.get`, `tabs.list`, `panes.list`, `layout.get`, `context.get`, `config.get`, `plugins.list/status/logs`. The CLI provides typed wrappers for workspace mutations, configuration, plugin registration, [events](events.md), and [terminal/browser automation](automation.md).

Pane/tab identities (`p1`, `t1`, etc.) are stable across layout changes, but a terminal's **session** changes on replacement/restoration. Capture `sessionId` from context and provide it for delayed terminal work. Explicit CLI pane/tab options override inherited identifiers; an explicit tab suppresses an inherited pane. Event filters deliberately do not inherit those targets.

Normal Browser pages have no bridge. Registered plugin main frames get a [scoped page API](plugins.md), which is a subset of the administrator socket. `shell.update` and shell run-input delivery are authenticated integration internals, not extension-owned context publication. Extensions publish their own context with custom events rather than spoofing native telemetry. Integration-only `debug.*` methods are unavailable in ordinary app launches.

## Failures and recovery

- `-32700`: JSON parse error; `-32600`: invalid request; `-32601`: unknown method; `-32602`: invalid parameters.
- `-32001`: handshake required; `-32002`: incompatible protocol version.
- `-32022`: resource/document/session closed or replaced; obtain fresh state before retrying.
- `-32024`: operation deadline/condition failure; do not assume side effects were undone.
- `-32031`: event cursor unavailable; explicitly resynchronize as described in [events](events.md).

Other workspace, storage, shell-state and admission errors have descriptive messages. Do not automatically replay a mutation after disconnect or timeout: it may already have taken effect. Read current state and decide deliberately. Unknown shell context stays unknown; neither quiet output nor process-name sampling proves an idle prompt.
