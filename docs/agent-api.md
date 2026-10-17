# Agent identity, inspection and shared commands

[First-pass parity](api-parity-first-pass.md) documents window frame/state commands, guarded web input additions, and warning-suppression setters shared by trusted clients.

These production interfaces extend the existing [control protocol](control.md), [terminal/browser automation](automation.md) and [event journal](events.md). The complete roadmap and outstanding verification are tracked in [implementation progress](api-extension-progress.md); unimplemented roadmap items are not implied by this document.

## Discovery and identity

```sh
slate-term api describe --json
slate-term context inspect --self --json
slate-term workspace snapshot --json
slate-term panes inspect --pane p2 --json
```

`api.describe` reports one shared method/command inventory, app identity, guards and bounds for CLI, registered-plugin bridge and service clients (`surface:"trusted"`). The Core catalog drives discovery, routing, admission and generated SDK inventories; remaining aliases have drift checks. Command `contract` describes arguments, workspace-independent targeting and retry policy, not client permissions. `backgroundServices.mode:"manual"` advertises start/stop/list/status/logs for every trusted client; no startup/restart or one-click controls are added. Ordinary websites/subframes receive no bridge. Existing `workspace get`/`workspace.get` preserves the raw workspace representation; `workspace snapshot` is a bounded envelope. See [manual services](background-services.md) for token-free public generation binding and ownership.

Terminal shells receive `SLATE_TERM_CLI`, `SLATE_TERM_SOCKET`, `SLATE_TERM_INSTANCE_ID`, `SLATE_TERM_PANE_ID`, `SLATE_TERM_TAB_ID` and `SLATE_TERM_SESSION_ID`. Pane IDs identify slots; session IDs identify a particular terminal lifetime. The tab environment variable is only a launch hint: the CLI resolves the pane's current tab from the host. Executable plugin commands additionally receive `SLATE_TERM_INVOCATION_ID`; their legacy `SLATE_TERM_PLUGIN_INSTANCE` alias remains unchanged. A panel service's logical instance is a different identity, and tab/global services may have no single pane.

An explicit sibling pane/tab drops the launching session guard. Explicit `--session-id` guards the terminal actually selected. `--active` intentionally chooses current focus and drops inherited pane/tab/session routing, but does not waive an app-instance check. Switching sockets while carrying another app's environment requires explicit targeting or `--active` for target-dependent commands. `--expected-instance-id` can explicitly select an expected app epoch. Invalid/stale identities fail instead of falling back to another pane. The CLI negotiates the explicit `guards` list and refuses guards an older host cannot enforce. Negotiation and guarded dispatch share one handshaken connection; a disconnect never triggers reconnection to a potentially different host. The first versioned API's five known guards have a narrowly defined compatibility fallback; new guards such as `expectedWriteRevision` are never inferred from an old boolean capability.

Context distinguishes caller anchor, requested target, focused pane and active terminal. Socket-supplied routing identity is not proof of process provenance. Registered pages receive native-bound identity through `workspace.self()`; an explicit target does not change the caller's identity.

## Snapshot and content boundaries

Snapshot envelopes include `appInstanceId`, `workspaceRevision`, `eventCursor`, `nextCursor`, groups, tab layouts/revisions and pane metadata. Use `--scope tab --tab t1` or `--scope pane --pane p1` to narrow, `--limit` (1–64, default 32) and `--cursor` to enumerate. Pages are bound to query, app epoch and workspace revision; a changed revision requires restarting enumeration. Keep the first event cursor and subscribe after it. Event expiry requires resnapshot; this is not durable/exactly-once delivery.

Pane metadata includes type, bounded titles, owning tab/group, terminal session or plugin view/instance identity, visibility, neighboring pane IDs and available content methods. Native geometry is optional, sampled in **tab-content points, top-left origin**, and tagged with a layout revision. Unavailable geometry is null, not a fabricated rectangle. Default snapshots exclude screen text, page DOM, process environments and plugin settings.

Read contents explicitly using the advertised per-pane operation: for example `terminal capture --pane p1 --session-id ...` or `web snapshot --pane p2` for browser/registered-plugin documents. Terminal capture is the current screen, not stdout isolation or complete scrollback. Multiple content reads are not an atomic workspace screenshot. `web screenshot --pane p2 --path /absolute/path/pane.png` captures browser/registered-plugin viewports, including ready, attached panes in inactive native tabs, without changing selection or focus. Check `web.get.screenshotReady` separately from visibility/renderability; DOM snapshots still require visibility. Treat captured text/images as potentially sensitive, untrusted data.

Registered pages can use `workspace.inspect(params)`, `workspace.self()`, `workspace.panes.inspect(params)`, `workspace.api()` and structured `workspace.web` helpers. Canonical web selector mutations require paired `expectedViewId`/`expectedDocumentId`; opaque snapshot refs bind both automatically. Public automation document identity is independent of the plugin bridge. Cross-pane structured interaction is explicitly allowed for trusted controllers. Pages can also write screenshots to an absolute path and use the browser-only `browser.navigate`/`browser.eval` API; arbitrary evaluation of plugin documents is not available to any client. See [shared web automation](automation.md#shared-web-panes). Existing `workspace.plugin`, `workspace.context()` and raw workspace/layout reads remain supported. Ordinary browser pages and subframes do not receive this bridge.

## Guards and lifecycle notifications

Optional RPC preconditions are `expectedInstanceId`, `expectedAnchorSessionId`, `expectedWorkspaceRevision` and `expectedLayoutRevision`. The latter identifies the requested pane's live tab, or the explicitly selected tab. The CLI exposes workspace/layout revision flags on typed target options, including generic `command run`. Common guard fields are checked by the host before being removed from strict content-action payloads. WebKit automation rechecks host preconditions immediately before submitting work after asynchronous document preparation; already-submitted JS cannot be undone.

Workspace revisions track authoritative native and legacy API mutations. Layout revisions track topology, type and zoom visibility, not ordinary unzoomed focus or terminal output. Reads/no-ops do not advance the model ledger. Post-commit topics currently include pane created/closed/type/title changes, tab created/closed/grouping changes, layout changes and focus changes. Changes from one prepared commit share an operation ID, native-assigned origin and pre/post revisions; native, CLI and registered-page adapters use the same boundary. `api.describe.workspaceCommit` describes the mutation-result fields and current divider-coalescing support. Mutation replies distinguish live-model acceptance from best-effort `workspacePersistence`; a failed save does not undo the command. See [workspace commit facts](events.md#workspace-commit-facts) for normalized events, revision correlation, persistence states and remaining gesture/causation/lifecycle work. Events do not claim filesystem durability.

Errors `-32050` (conflict), `-32051` (unavailable/bounds), `-32052` (reserved forbidden-operation code, not a trusted-client permission tier), `-32053` (incompatible guard support), and `-32054` (settings write/apply failure) are shared. Write/apply failures carry optional error `data` with observed source/applied state and persistence; an unknown outcome must not be reported as a clean rejection. `--json` writes successful results to stdout and one machine-readable error object to stderr with nonzero exit status. Page bridge RPC failures reject with an `Error` carrying the same numeric `code`; success values (including null/false and objects with `ok`/`error` fields) remain ordinary results. Unknown transport/execution outcomes are not permission to repeat mutations automatically.

## Layout, tabs and native windows

See [guarded layout operations](layout-api.md) for atomic pane/root split with type/fraction/focus, pane move, subtree resize, manual title set/clear, native tab reorder/move/detach and paginated native window inspection/focus. Layout/tab rearrangement requires an observed revision. Typed CLI and registered-page wrappers use the same command route, including window operations and the native detach convenience alias.

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

Application configuration writes, appearance, palette import and font-default commands are available to every trusted client through the same API and `command.run` route. Existing `workspace.command('config.reload')` remains compatible. Trust is established at the registered-origin/main-frame/document or same-user transport boundary; this is not an OS sandbox.

## Notifications

`notifications.post/list/dismiss/status` are shared trusted-client operations, also exposed as `workspace.notifications.*` and `slate-term notify` / `slate-term notifications …`. Posts capture the original content lifetime and never request OS permission. Replies distinguish native submission from policy/authorization suppression; neither proves display. Records and unread state are bounded/in-memory. `notifications.next` and `notifications.open` commands navigate without retargeting stale sessions. See [notification contracts, defaults and bounds](notifications.md).

## Plugin data and panel restoration

Discover `api.describe.pluginPersistence`. `plugins.data.get/patch/reset` (CLI `plugins data`) address shared durable values by plugin ID without an open panel. `plugins.panelState.get/patch/reset` (CLI `plugins panel-state`) address one panel’s restoration context; page defaults are native-bound, unanchored clients must supply a pane. Writes require data or panel/content revision guards. Native reset controls use the same operations; no legacy `storage.*` aliases remain. Bulk topology reads omit payloads; `pane.inspect` exposes `pluginPanelId`/`pluginStateRevision`. See [the complete schemas, lifetime and failure contract](plugin-persistence.md).

## Own-plugin settings

```js
const settings = await workspace.pluginSettings.get();
await workspace.pluginSettings.patch([
  {op: 'set', path: ['display', 'side'], value: 'left'},
  {op: 'delete', path: ['obsolete']}
], settings.writeRevision);
```

Every client can use `plugins.settings.get/patch` with an explicit plugin `id`; page/service callers default to their own ID. CLI conveniences are:

```sh
slate-term plugins settings get acme.tools
slate-term plugins settings patch acme.tools --operations '[{"op":"set","path":["enabled"],"value":true}]' --expected-write-revision TOKEN
```

Read results distinguish source `values`, live `appliedValues`, `sourceValid` and opaque `writeRevision`. A valid source with a removed namespace returns empty source values, not the older applied namespace. Invalid source can still expose last-valid own settings but cannot be overwritten by the patch API. Page and service callers default to their own namespace; an explicit `id` selects another plugin's namespace. Page errors retain typed failure codes/state but omit raw TOML/apply diagnostics that might quote another namespace.

Patch limits are 32 operations/64 KiB, paths of 1–32 literal components (at most 1024 UTF-8 bytes each), source/edited TOML of at most 1 MiB, and the existing aggregate 64 KiB/64-namespace configuration limit. Wide subtrees are inserted in batches; pathological dotted-key serialization expansion is rejected before producing an oversized file. Objects and arrays are supported; arrays are replaced whole. Null is rejected at any depth, deletion is explicit, and overlapping ancestor/descendant operations are rejected atomically. Setting a subtree replaces it; patch children separately to merge. Deleting the last child retains its empty object parent.

All settings writers share the same lexical source editor and semantic validation. Quoted/dotted keys, ordinary nested tables, arrays of tables and supported single-line array values remain editable by native Settings and appearance commands. Unsupported standalone inline-table or multiline syntax—including multiline strings nested inside arrays—fails closed, rather than being mistaken for application assignments. A patch does not normalize or overwrite unrelated plugin settings/comments.

The write revision covers the whole config source, so unrelated edits can cause a safe conflict. Refetch and intentionally rebase; do not blindly replay writes. Applied changes emit a value-free, directed `host.plugin.settings.changed` lifecycle notification. `workspace.settings()` remains the compatible default read of live own settings; `workspace.call('settings.get',{id})` selects another namespace. Settings environments for commands/services do not change after launch.
