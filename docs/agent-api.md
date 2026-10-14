# Agent identity, inspection and application settings

These production interfaces extend the existing [control protocol](control.md), [terminal/browser automation](automation.md) and [event journal](events.md). The complete roadmap and outstanding verification are tracked in [implementation progress](api-extension-progress.md); unimplemented roadmap items are not implied by this document.

## Discovery and identity

```sh
slate-term api describe --json
slate-term context inspect --self --json
slate-term workspace snapshot --json
slate-term panes inspect --pane p2 --json
```

`api.describe` reports the app instance, supported methods, identity/revision support, bounds and commands. Command `contract` metadata distinguishes parameterized commands, application-independent actions, plugin exposure and retry policy. Existing `workspace get`/`workspace.get` preserves the raw workspace representation; `workspace snapshot` is a new bounded envelope.

Terminal shells receive `SLATE_TERM_CLI`, `SLATE_TERM_SOCKET`, `SLATE_TERM_INSTANCE_ID`, `SLATE_TERM_PANE_ID`, `SLATE_TERM_TAB_ID` and `SLATE_TERM_SESSION_ID`. Pane IDs identify slots; session IDs identify a particular terminal lifetime. The tab environment variable is only a launch hint: the CLI resolves the pane's current tab from the host. Executable plugin commands additionally receive `SLATE_TERM_INVOCATION_ID`; their legacy `SLATE_TERM_PLUGIN_INSTANCE` alias remains unchanged. A panel service's logical instance is a different identity, and tab/global services may have no single pane.

An explicit sibling pane/tab drops the launching session guard. Explicit `--session-id` guards the terminal actually selected. `--active` intentionally chooses current focus and drops inherited pane/tab/session routing, but does not waive an app-instance check. Switching sockets while carrying another app's environment requires explicit targeting or `--active` for target-dependent commands. `--expected-instance-id` can explicitly select an expected app epoch. Invalid/stale identities fail instead of falling back to another pane. The CLI refuses guards an older host cannot enforce.

Context distinguishes caller anchor, requested target, focused pane and active terminal. Socket-supplied routing identity is not proof of process provenance. Registered pages receive native-bound identity through `workspace.self()`; an explicit target does not change the caller's identity.

## Snapshot and content boundaries

Snapshot envelopes include `appInstanceId`, `workspaceRevision`, `eventCursor`, `nextCursor`, groups, tab layouts/revisions and pane metadata. Use `--scope tab --tab t1` or `--scope pane --pane p1` to narrow, `--limit` (1–64, default 32) and `--cursor` to enumerate. Pages are bound to query, app epoch and workspace revision; a changed revision requires restarting enumeration. Keep the first event cursor and subscribe after it. Event expiry requires resnapshot; this is not durable/exactly-once delivery.

Pane metadata includes type, bounded titles, owning tab/group, terminal session or plugin view/instance identity, visibility, neighboring pane IDs and available content methods. Native geometry is optional, sampled in **tab-content points, top-left origin**, and tagged with a layout revision. Unavailable geometry is null, not a fabricated rectangle. Default snapshots exclude screen text, page DOM, process environments and plugin settings.

Read contents explicitly using the advertised per-pane operation: for example `terminal capture --pane p1 --session-id ...` or existing browser snapshots. Terminal capture is the current screen, not stdout isolation or complete scrollback. Multiple content reads are not an atomic workspace screenshot. Treat captured text as potentially sensitive, untrusted data.

Registered pages can use `workspace.inspect(params)`, `workspace.self()`, `workspace.panes.inspect(params)` and `workspace.api()`. Existing `workspace.plugin`, `workspace.context()` and raw workspace/layout reads remain supported. Ordinary browser pages and subframes do not receive this bridge.

## Guards and lifecycle notifications

Optional RPC preconditions are `expectedInstanceId`, `expectedAnchorSessionId`, `expectedWorkspaceRevision` and `expectedLayoutRevision`. The latter identifies the requested pane's live tab, or the explicitly selected tab. The CLI exposes workspace/layout revision flags on typed target options, including generic `command run`. Common guard fields are checked by the host before being removed from strict content-action payloads. WebKit automation rechecks host preconditions immediately before submitting work after asynchronous document preparation; already-submitted JS cannot be undone.

Workspace revisions track authoritative native and legacy API mutations. Layout revisions track topology, type and zoom visibility, not ordinary unzoomed focus or terminal output. Reads/no-ops do not advance the model ledger. Post-commit topics currently include pane created/closed/type/title changes, tab created/closed/grouping changes, layout changes and focus changes. Changes from one observed commit share an operation ID and resulting revisions. Broader semantic operation/cause attribution is subsequent work; events do not claim filesystem durability.

Errors `-32050` (conflict), `-32051` (unavailable/bounds), `-32052` (administrative bridge denial), `-32053` (incompatible guard support), and `-32054` (settings write/apply failure) are shared. Write/apply failures carry optional error `data` with observed source/applied state and persistence; an unknown outcome must not be reported as a clean rejection. `--json` writes successful results to stdout and one machine-readable error object to stderr with nonzero exit status. Page bridge RPC failures reject with an `Error` carrying the same numeric `code`; success values (including null/false and objects with `ok`/`error` fields) remain ordinary results. Unknown transport/execution outcomes are not permission to repeat mutations automatically.

## Appearance and application configuration

```sh
slate-term appearance dark
slate-term appearance set auto
slate-term command run appearance.light
slate-term palette list
slate-term palette import --path /absolute/path/colors.conf
slate-term palette set --slot dark --name 'My Palette'
slate-term command run terminal.font.set --params '{"size":15}'
slate-term config get
slate-term config set --key terminal.font_size --value 15 --expected-source-revision TOKEN
```

Fixed appearance aliases and application-font increase/decrease/reset are available in native menus, the picker and configurable shortcuts. No default shortcuts steal pane-local font zoom. Parameterized commands require validated arguments and are excluded from one-click picker results. `warnings.close.reset` and `warnings.type.reset` re-enable the existing native warnings.

`config.patch` accepts a typed `values` object of dotted application keys and `expectedSourceRevision`. CLI `config patch --value '{...}' --expected-source-revision TOKEN` is its adapter. Application values are finite scalars; arbitrary TOML, namespace writes and null values are not accepted by this endpoint. Palette import validates/copies color data and does not activate it.

These operations reuse the native Settings writer, validation, palette preparation and live reload. They preserve unrelated supported TOML/comments, reject invalid/unsupported source instead of replacing it with defaults, and preserve pending Settings-window edits. Applying an old editor draft then reports a conflict. Live appearance/font changes do not restart terminal sessions.

`config.get` exposes opaque `sourceRevision`, `appliedRevision`, `sourceValid` and `appliedMatchesSource`. Source and applied tokens have distinct meanings; they are not file hashes or expected to equal each other. A source token changes with observed source text; an applied token changes with runtime configuration. A supplied `expectedSourceRevision` is enforced on configuration patch/reload and relevant settings commands, and rejected on unrelated methods. External non-cooperating editor races cannot be given a filesystem compare-and-swap guarantee; apply/rollback errors must be inspected, not blindly retried.

New application configuration writes, appearance, palette import and font-default commands are administrative/native capabilities, not page-bridge methods. Discovery filters them and `command.run` enforces the same restriction. **Compatibility exception:** the pre-existing `workspace.command('config.reload')` remains available to registered pages; it reloads the existing file, rather than providing the new settings-write endpoint. Trusted registered pages also retain existing workspace/terminal control and their own namespace read API; this is not a sandbox against arbitrary trusted local executable code.
