# Plugin data and panel restoration

Discover `api.describe.pluginPersistence`. Runtime `scope` (`pane`, `tab`, `global`) controls backend/WebKit instance lifetime and default event context, **not** data ownership. Every panel has its own web view. No arbitrary DOM, JavaScript memory, browser cookies/history or running process is snapshotted.

## Choose the right layer

| Purpose | API / owner | Lifetime |
| --- | --- | --- |
| Notes, small task datasets, shared document references | `plugins.data.*`, page `workspace.pluginData` | One durable namespace per plugin ID and Slate state directory; available without an open panel |
| Selection, filters, view mode | `plugins.panelState.*`, page `workspace.panelState` | One plugin-content record per pane; preserved on reload, moves and workspace restoration |
| User preferences | `plugins.settings.*`, page `workspace.pluginSettings` / `workspace.settings()` | User's `[plugins.<id>]` TOML namespace |
| Starting folder/project/document | `layoutFields`, `workspace.layoutConfiguration()` | Captured configuration for this panel; saved templates copy these inputs, not live state |
| Hover, menu, animation | Page memory | This document only |
| Large documents, databases, remote sync | Plugin-owned backend/files/server | Plugin-defined; not managed/deleted by these APIs |

Namespacing is not a permission boundary. Registered plugins, services and CLI/socket callers are trusted controllers and may explicitly access another namespace or panel. Ordinary websites and subframes receive no bridge. WebKit stores for plugin instances remain ephemeral: **do not rely on `localStorage` for cross-launch persistence**. URLs can encode routes, but Slate does not automatically save a plugin's current URL; persist route/document identifiers explicitly. Do not put secrets in URLs or these unencrypted JSON stores.

## Shared plugin data

```js
const saved = await workspace.pluginData.get(); // {id, values, revision}
await workspace.pluginData.patch([
  {op: "set", key: "note:123", value: {version: 1, text: "Hello"}},
  {op: "delete", key: "obsolete"}
], saved.revision);
```

Methods:

- `plugins.data.get {id}` → `{id,values,revision}`.
- `plugins.data.patch {id,operations,expectedDataRevision}` → `{id,revision,changed,persisted:true,operationId}`.
- `plugins.data.reset {id,expectedDataRevision,force:true}` → same mutation fields. Resets all host-managed data for that ID, not preferences/panel state/external files.

Page/service callers default `id` to their bound plugin ID. CLI uses an explicit ID:

```sh
slate-term plugins data get notes
slate-term plugins data patch notes --expected-data-revision REVISION --operations '[{"op":"set","key":"draft","value":{"text":"Hello"}}]'
slate-term plugins data reset notes --expected-data-revision REVISION --force
```

Registered IDs (enabled or disabled), or IDs with retained new-format files, can be accessed. Unknown IDs with no data fail. Reads/writes never start a panel, command or service. Unregister retains data; explicit ID access still works, and re-registering reconnects to it.

Files live at `state/plugin-data-v2/<id>.json` under the app's state root, using private ownership/modes and atomic replacement. One host cache is authoritative under the state-directory lease. Do not edit internal files while Slate runs. Missing data is empty; unreadable/corrupt/unsupported files fail without overwrite. Repair while stopped rather than treating errors as empty data. Atomic replacement is not power-loss durability.

## Panel state and configuration

```js
const panel = await workspace.panelState.get(); // {pluginId,paneId,panelId,values,revision}
await workspace.panelState.patch([
  {op: "set", key: "selectedNoteId", value: "123"}
], {expectedPanelId: panel.panelId, expectedStateRevision: panel.revision});
const inputs = await workspace.layoutConfiguration();
```

- `plugins.panelState.get {pane,tab?}` → `{pluginId,paneId,panelId,values,revision}`.
- `plugins.panelState.patch {pane,tab?,operations,expectedPanelId,expectedStateRevision}` → IDs, `revision`, `changed` and standard workspace commit fields.
- `plugins.panelState.reset {pane,tab?,expectedPanelId,expectedStateRevision}` → same mutation fields. Clear state, retaining panel identity and starting configuration.
- `command.run {id:"plugins.panelState.reset",...}` is the equivalent noninteractive reset command, with the same required guards.

Page helpers default to their own pane. Services without a pane must specify one; there is no focused-pane fallback. Explicit pane/tab pairs must agree. `panelId` follows the plugin content across reload, navigation, movement and app restart; replacing its pane type creates a new ID even if the slot's PaneID is reused. It is distinct from logical `instanceId`, `viewId` and document ID. Do not use any of these runtime/content identities as the identity of a user's document.

```sh
slate-term plugins panel-state get --pane p2
slate-term plugins panel-state patch --pane p2 --expected-panel-id PANEL --expected-state-revision REVISION --operations '[{"op":"set","key":"selectedNoteId","value":"123"}]'
slate-term plugins panel-state reset --pane p2 --expected-panel-id PANEL --expected-state-revision REVISION
```

Values/configuration are embedded in the authoritative workspace snapshot. Bulk topology reads omit them; use explicit reads. `pane.inspect` includes `pluginPanelId` and `pluginStateRevision` metadata. State-only changes advance state/workspace revisions, not layout revisions, and do not rebuild/focus native views.

Plain opening merges manifest defaults. Required `layoutFields` with no usable default reject the open before changing the old pane; configure a saved layout instead. Mark fields optional if the plugin supports an interactive setup flow. Saved-layout opening merges validated explicit inputs/defaults before committing. Restoring an existing panel uses its recorded configuration, even if manifest defaults/schema changed. The plugin owns semantic validation and format evolution.

## Concurrency, failures and bounds

Both patch APIs take 1–32 distinct literal top-level keys: `set` replaces a value, `delete` removes it. No recursive merge or dotted paths; unknown fields and duplicate keys fail. JSON null is a stored value, distinct from deletion. Whole-document revision checks are mandatory. After a conflict, reread and **deliberately** rebase the user's edit; never blindly retry an old autosave or recreate reset/deleted data.

- Equal patches/absent deletes retain semantic revisions and emit nothing. Shared-data no-ops do no I/O. Panel no-ops may retry workspace snapshot persistence without another semantic mutation.
- Reset is an explicit generation barrier, **including when empty**. It advances revision, emits a reset invalidation and reports `changed:true`. Queued writes with old revisions conflict. Intentional writes after a fresh read remain possible.
- Shared data saves before publishing its cache/event. Failure leaves old state and returns `-32054` with `persisted:false` and its unchanged revision.
- Panel state follows existing best-effort workspace persistence: a live commit may report `workspacePersistence: failed`, `disabled` or `suspended`. It is not a saved-state claim. Show save problems; do not replay the accepted mutation. An equal guarded patch or later autosave can recover persistence.
- Invalid inputs/bounds/unsupported guards: `-32602`; conflicts: `-32050`; missing namespace/non-plugin pane: `-32051`; unreadable/incompatible data: `-32053`. Retired callers/documents follow normal lifecycle errors. Timeout/disconnect can mean an unknown outcome: inspect before deciding whether to write again.
- Data methods accept the app-instance guard plus their data write guard, not pane/workspace/layout/session/document guards. Panel methods accept app/workspace guards and their content/state guards, not terminal/document/layout guards. Guard names are advertised centrally and never silently ignored.

Budgets: shared values 256 KiB / 1,024 keys; panel values 32 KiB / 128 keys; starting configuration 64 KiB per panel; 2 MiB aggregate plugin records per workspace. Keys are 1–256 UTF-8 bytes, each set value at most 16 KiB, patch arrays at most 48 KiB and JSON nesting at most 32. Encoded transport envelopes remain independently bounded (64 KiB page requests, 1 MiB responses/socket messages). Use external files/databases for larger data; never silently truncate.

All helpers accept final `{signal,cause}` options. `workspace.pluginData.reset({expectedDataRevision,force:true}, options)` and `workspace.panelState.reset({expectedPanelId,expectedStateRevision}, options)` are explicit. Generic `workspace.call` / generated RPC helpers select other targets. Native-bound ownership, document liveness and mutation budgets still apply, regardless of target namespace.

## Events and authoring

Capture `events.head` **before** reading snapshots, then subscribe from that cursor:

- `host.plugin.data.changed` is a single value-free broadcast: filter `payload.pluginId` and reread. It reaches default subscriptions across tabs/runtime scopes and services, without per-instance fan-out.
- `host.plugin.panel-state.changed` is a pane/tab-scoped workspace fact: filter `payload.panelId` and reread the view state. Notice the lowercase/hyphen event spelling versus camelCase RPC names.

Both include before/after revisions, reset flag, operation attribution and a bounded changed-key summary, never values/configuration. Equal patches emit nothing; reset does. Events are not durable data or exactly-once delivery. Expired cursors require explicit resnapshot/resubscribe. Coalesce reads, discard superseded results, preserve unsaved editor drafts, and never echo every invalidation into another write.

Save user content during editing, not in unload/quit callbacks. Keep a plugin-owned format version and handle unsupported formats explicitly. Empty panel state must never clear shared data. Cancel obsolete debounced view saves on reset; revisions are opaque, so a replayed old reset must not erase a newer edit made against a fresh snapshot. The copyable nonvisual [notes controller](../skills/slate-terminal/references/plugin-persistence.mjs) demonstrates shared notes, independent selection, explicit conflicts and reset-safe debounce cleanup. Recreate subscriptions/controllers on cached `pageshow` as appropriate.

## Lifecycle and native controls

- Reload/backend restart/move retain data, panel identity, state and configuration. Tab-scoped moves still recreate the page in the destination runtime/WebKit store; unsaved DOM may reset.
- Quit with workspace restoration enabled restores saved open panels. Closing a pane/tab/window explicitly removes its panel record, but not shared data. A failed workspace save can leave an older snapshot recoverable at next launch.
- Genuine type replacement, forced disable/unregister discard removed panels' records. Re-enabling/re-registering does not reopen them. Registration replacement still requires visible panels to close first.
- **Reset Plugin Panel View…** is in the plugin type menu, Workspace menu, Cmd-K and shortcut inventory. Confirmation keeps shared data/configuration; the cooperating plugin rehydrates on the event, without an implicit reload/backend restart. No default shortcut.
- **Settings → Plugins → Data actions → Delete Slate-managed Plugin Data…** clears shared data with confirmation. It does not delete preferences, panel selections/configuration, external files or backend databases. A stale confirmation fails, not retries.
- **Restore workspace on launch** affects panel restoration only, never shared-data retention. No per-panel persistence toggle.
- Templates/Spotlight launchers create fresh panel identities/empty state while accessing the same shared data. Capture includes starting configuration only. Closing and relaunching a launcher does not resume the old panel; use configured stable document/project references.

Installed code is separate from user data: [managed ZIP packages](plugins.md#managed-zip-packages) live under application support `plugins/`, while shared values and panel records keep their existing state/workspace locations. Package replacement/uninstall never deletes shared data, settings or shortcuts. Old loose-manifest catalogs are not migrated; installing a repackaged ZIP with the same plugin ID reconnects retained shared data.

## Breaking development formats

`storage.get/set/delete`, `workspace.storage` and `host.plugin.storage.changed` are removed. No automatic mapping from old pane/tab/global stores is safe. Old `state/plugin-data/` files remain untouched and unused. Workspace snapshots now use schema 2; old snapshots are preserved, rejected and trigger the existing recovery workspace with autosave suspended. While Slate is stopped, move the old `state/workspace.json` aside if you want a fresh development workspace. No migration, deletion or automatic overwrite is performed.
