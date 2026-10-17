# Plugin persistence — implementation plan

Status: **independently reviewed; initial findings addressed; fresh follow-up found no actionable findings; not implemented**. This is a proposed breaking change for an unreleased app, not documentation of available APIs. Review must precede implementation. See the [review record](plugin-persistence-plan-review.md).

## Outcome and boundaries

Give plugin authors two explicit storage layers: **durable plugin data shared by plugin ID**, and **restoration state owned by one panel**. Persist plugin starting configuration with the workspace so restored panels know which project/document they represent. Keep preferences in TOML and reusable layout starting values in saved recipes. Update shared APIs, native controls, tests, and the shipped authoring skill together.

Users should not have to enable a per-panel persistence switch to retain their notes/tasks. Authors still must serialize meaningful state; Slate cannot snapshot arbitrary DOM/JavaScript, browser sessions, processes, or external databases.

Decisions:

- Keep manifest `scope: pane|tab|global` for runtime instance/backend, ephemeral WebKit data-store and default event-context lifetime. **Scope no longer chooses durable data or panel-state ownership.** Every visible panel remains a separate web view.
- Plugin data belongs to `(Slate state directory, plugin ID)`, regardless of runtime scope or whether a panel is open. It is not a machine-wide singleton or a permission boundary.
- Panel state belongs to the plugin content occupying one pane. It is independent of runtime scope, tab membership and web-document lifetime.
- Existing `layout.restore_workspace` controls restoration of the workspace and panel state, not retention of plugin data. No new per-panel persistence toggle in this change.
- Saved layouts remain starting templates. Spotlight launchers still open a fresh window from the latest template; no resumable launcher/workspace identity, restore-closed-window history, merge/open-existing behavior or new launcher mode.
- No automatic service activation, persistent WebKit profiles, URL/history restoration, generic dirty-document/quit-veto protocol, external file database, secret store, export/backup UI, or broad settings redesign.
- Breaking API/snapshot changes are acceptable. Remove ambiguous instance storage rather than retaining two overlapping systems. Do not migrate, reinterpret, or automatically delete old development data.

## 1. Current source and why it changes

| Source | Current behavior / implication |
| --- | --- |
| `Native/PluginInstance.swift` | Owns `[String: JSONValue]`, `PrivateJSONStore`, `storageGet/storageSet`, and `WKWebsiteDataStore.nonPersistent()`. Disk namespace is plugin ID + pane/tab/global scope key. Runtime closure does not remove files. Move durable storage out of this class; retain process/WebKit/runtime ownership. |
| `Native/PluginPane.swift` | Loads the registered entry URL for each new view; `workspace.storage` selects logical-instance storage. It neither snapshots DOM nor restores a live plugin route. Replace storage helpers with explicit data/panel-state helpers; preserve registered-origin/main-frame/document binding. |
| `Native/WorkspaceHost.swift` | `layoutRecipes` is an in-memory map. `layout.configuration` reads it, capture copies it, reconciliation filters/merges it. `storage.*` requires a live instance or plugin pane. New stores must not depend on instance acquisition or page readiness. |
| `Sources/SlateTermCore/Workspace.swift`, `Sources/SlateTermSettings/WorkspaceStore.swift` | Snapshots preserve pane/tab IDs and topology, but no plugin starting configuration or panel payload. Add plugin content identity/configuration/state to the authoritative pane model and snapshot. |
| `Native/ApplicationSettings.swift` | Workspace restore defaults on; save is best effort with `saved/failed/disabled/suspended` outcomes. Preserve these semantics rather than claiming successful model changes are always durable. |
| `Native/WorkspaceOperations.swift`, `WorkspaceTransition.swift`, `APIFoundation.swift` | Prepared model/revision/event commits already exist. Panel mutations must use them, not a second sidecar with separate lifetime/GC. |
| `docs/saved-layouts.md`, `Native/SavedLayouts.swift` | Templates intentionally create fresh IDs and exclude plugin storage. Keep that contract; fix ordinary restart losing plugin starting configuration. |
| `Native/EventControl.swift`, `EventHub.swift`, `docs/events.md` | Bounded journal, preflight/commit primitives, post-commit facts, caller-bound causation, default recipient/tab filters. Reuse them; do not add a persistent event bus or per-view fan-out loop. |
| `skills/slate-terminal/references/building-plugins.md` | Mentions instance storage without a complete data-vs-view/lifecycle recipe. Replace that guidance in the same implementation, never advertise proposed helpers prematurely. |

Existing `verify-plugins.py` covers storage across restart and document replacement, not the proposed split. `verify-cross-window-pane-movement.py` currently expects moved tab plugins to adopt destination storage: that storage expectation changes, while destination backend/WebKit ownership remains correct.

## 2. User-visible lifecycle contract

“Panel removed” means explicit pane close, owning tab/window close, type replacement, or forced plugin disable/unregister removing that panel. Quitting is **not** equivalent to closing each pane.

| Action | Durable plugin data | Panel state / starting configuration | Runtime |
| --- | --- | --- | --- |
| Open a new panel | Same plugin namespace | Fresh content identity, empty state; template configuration if supplied, otherwise validated manifest defaults | Existing scope rules |
| Reload document / restart backend | Retained | Retained | Document/backend can be replaced; never copy unsaved DOM |
| Move pane, including another tab/window | Retained | Same content identity, configuration and state | Pane/global live views retained; tab scope still recreates page in destination runtime |
| Quit / ordinary launch with restore on | Retained independently | Restore previously saved open panels and their identities/state/configuration | Fresh processes/web views; no terminal command replay |
| Quit with restore off | Retained | Current in-memory panel state is not written/restored; preserve existing snapshot as today | Fresh workspace at next launch |
| Explicit panel/tab/window close | Retained | Remove the closed records with the model; no independently orphaned panel files | Current cleanup rules |
| Change pane type | Retained | Discard old plugin content record; a later switch back is a fresh panel, even in the same PaneID | Current replacement rules |
| Repeat setting current type | Unchanged | No-op, not a reset | Unchanged |
| Disable / unregister | Retained | Forced removal of open panels discards their records; enable/re-register does not reopen them | Current consent/force and stop policies |
| Replace registration | Retained | Existing requirement to close visible panels first remains; no hidden state migration | Current replacement policy |
| Reset panel view | Unchanged | Clear only panel state; retain configuration and content identity, advance state revision | Notify; no process restart or implicit page reload |
| Delete Slate-managed plugin data | Clear only that plugin's data, with guarded explicit consent | Unchanged; references can become missing and plugins must render that state | No automatic stop/start; stale writes conflict |
| Capture/open saved layout / Spotlight launch | Never copied or cleared | Capture starting configuration only; open fresh identities and empty state | Normal template opening |

Shared data does not force shared selection: two panels can show different documents/filters over one dataset. A plugin may explicitly put a setting/selection in shared data when synchronized views are intended.

Panel removal and save failure follow existing workspace semantics: the live removal can succeed while snapshot persistence fails. A later launch may recover the previous snapshot. Surface that status; do not promise close-time erasure or power-loss durability. Durable plugin data writes are independent and save-before-assignment.

## 3. Authoritative models and persistence

### 3.1 Durable plugin data

Add a `PluginDataStore` in `Sources/SlateTermSettings` and a host-owned manager/handler (prefer a focused `Native/PluginPersistenceAPI.swift`, not another large inline switch). There is exactly one loaded authoritative document per namespace, serialized on the host actor under the existing state-directory lease.

- New private path: `state/plugin-data-v2/<validated-plugin-id>.json`. Keep the old `state/plugin-data/<id>/<scope>.json` files untouched and unused.
- Versioned envelope `{schemaVersion, revision, values}`; `values` is a JSON object. Persist an opaque fresh revision with each effective mutation. Validate format/version, size, key/value constraints and file ownership on load; missing is empty, corrupt/unreadable is an error, never silently empty.
- Resolve a namespace if its ID is currently registered (enabled or disabled), or it has a retained new-format data file. Unknown/unregistered IDs with no retained file fail; validate canonical plugin IDs before any path construction. No arbitrary path parameter and no activation required.
- Absent registered namespace reads get a stable in-memory empty revision without creating files. Effective first mutation creates its document. Reset always saves an empty envelope with a **new revision**, even for an already-empty or never-persisted namespace, rather than unlinking and reusing an old empty token. This is an explicit generation barrier: queued writes using the pre-reset revision must conflict. Reset returns `changed:true` and emits its reset invalidation even when no values were present; it is not a no-op patch.
- Prepare and validate a complete candidate, enforce expected revision, preflight bounded notifications, then atomically save before assigning cache/revision. No automatic write retries. File failure leaves the previous authoritative cache and file intact; use the existing private-file writer and error conventions. Atomic rename is not fsync/power-loss durability.
- The manager is the sole supported writer while Slate owns the state directory. External edits of internal store files while running are unsupported; plugin-owned databases/files are a separate option. Do not watch/reload these files into racing live caches.
- Use a synchronous preflight/save/assignment/journal-commit sequence with no await or run-loop callbacks: the `EventHub` preparing-effects hook can perform the failure-atomic file replacement, followed by nonthrowing cache assignment and journal publication. A process crash after file replacement but before reply is still an unknown outcome, not rollback.
- Invalid/corrupt data is preserved with a bounded diagnostic. Normal reset cannot bypass validation to erase an unreadable file. Manual development repair while Slate is stopped remains outside this API; no silent recovery overwrite.

### 3.2 Panel restoration record

Add an optional plugin-content record to `Pane` in Core, present exactly for `.registered(pluginID)`:

```
PluginPanelRecord {
    panelId: UUID                 // durable plugin-content lifetime, NOT PaneID/viewId/instanceId
    configuration: JSON object   // merged starting inputs captured at creation
    state: JSON object           // panel-only restoration values
    stateRevision: opaque token
}
```

- The containing pane's type is authoritative for plugin ID. Validate record/type consistency, unique panel IDs across the workspace, revision syntax and bounds in candidate mutations and snapshot restore.
- Create a fresh record for a new plugin pane or genuine type replacement. Preserve it on moves, focus, renaming, chrome changes, zoom, web navigation/reload and backend restart. A no-op type setter must not allocate a new ID.
- `panelId` identifies plugin content even when a PaneID is reused for another type. It survives restart, unlike logical `instanceId` and `viewId`; it is not a document/database identity for shared plugin data.
- Defaults are resolved from the manifest and explicit layout inputs before constructing the **final prepared transition**, not in reconciliation after that transition is built. Build the complete candidate, fill new plugin records/configuration, check budgets/field requirements, and only then compute revisions/events and prepare resources. Reconciliation receives exactly that candidate; it must not alter records/IDs/defaults. Refactor the current command-to-transition boundary as needed rather than constructing a transition and patching its workspace afterward.
- Plain plugin panes also get validated manifest defaults. If a required `layoutField` has no usable default, plain type/split opening fails before commit with an actionable error to open a configured saved layout; the previous pane/process and identity counters remain intact. This is an intentional stricter plain-open contract. Authors who support an in-panel setup flow should make those starting fields optional. Template opening continues validating required fields after defaults/explicit inputs are merged. No new configuration prompt/setter is added.
- Persist the effective configuration. Restore the recorded configuration, not newly changed manifest defaults; the plugin handles its own configuration/state format evolution. Do not revalidate restored opaque configuration against a newly changed field schema and reject the whole workspace; structural bounds/type/identity validation still applies.
- Store panel records in the same `workspace.json` snapshot as membership. Do not add per-panel files or independently garbage-collected records. Removed records disappear only through the same model close/type transition.
- Add pure candidate operations for guarded state patch/reset. Advance state and workspace revisions for changed patches and for **every explicit reset**, including empty state; reset is a generation barrier with `changed:true`. Do not advance layout revisions. A reset retains `panelId`/configuration but changes the state revision and emits a reset invalidation, so queued old writes conflict and a cooperating view can clear unsaved presentation. Use the prepared `WorkspaceTransition`/event commit and direct model save; a state write must **not** invoke full native reconciliation, rebuild roots, focus a pane or recreate a view.
- Workspace state is accepted in memory before best-effort snapshot save, as today. Return `workspacePersistence` on writes. With restoration disabled/suspended, state remains useful for reload/moves within the current app, but is explicitly not reported as saved.
- Bulk metadata reads (`workspace.get`, `workspace.snapshot`, `pane.inspect`, context/debug listings where applicable) must not accidentally serialize the newly embedded state/configuration. Separate the public workspace projection from the disk encoder; expose only plugin/content identity and state revision metadata. Values are read through the explicit APIs below. This intentionally changes `workspace.get`'s implementation while retaining its existing topology fields; it must not become an implicit plugin-data dump or exceed response limits because of this change.
- Bump the workspace snapshot schema. Old development snapshots fail closed with the existing preserved-file/recovery-workspace behavior; document how to move the old file aside while stopped. Do not add migrations or auto-reset the user's workspace.

### 3.3 Persist plugin configuration, not terminal startup programs

Replace plugin uses of `WorkspaceHost.layoutRecipes` with the model record. Keep any terminal/browser startup recipe bookkeeping separate and transient.

- `layout.configuration` reads the plugin record for a plugin pane, including after restart and before its page is ready. Preserve existing nonplugin behavior.
- On saved-layout open, put resolved plugin configuration into the candidate pane record **before** preparing/committing/activating its view. On failed open/preparation/publication, no partial model records survive.
- Capture reads plugin starting configuration from that record. It does not read arbitrary runtime state or call page-provided capture callbacks.
- Do not persist or rerun terminal startup commands as an incidental consequence of persisting plugin configuration. Do not start retaining browser cookies/history or introduce links from live windows back to template files.
- Capture after app restart must retain the original plugin starting configuration. Changing a template later does not mutate a live panel; reopening the template uses its new values with fresh state.

## 4. Shared API contract

Names here are the implementation baseline. Remove `storage.get/set/delete`, `workspace.storage`, and `host.plugin.storage.changed`; update all shipped callers/tests/examples. Keep `settings.get`, `plugins.settings.*`, `workspace.settings/pluginSettings` and `layout.configuration` for their existing distinct purposes.

### 4.1 Methods and helpers

| Method | Parameters beyond supported guards | Result |
| --- | --- | --- |
| `plugins.data.get` | `id` | `{id, values, revision}` |
| `plugins.data.patch` | `id, operations, expectedDataRevision` | `{id, revision, changed, persisted:true, operationId}` |
| `plugins.data.reset` | `id, expectedDataRevision, force:true` | Same result; clear data only |
| `plugins.panelState.get` | `pane`, optional consistent `tab` | `{pluginId, paneId, panelId, values, revision}` |
| `plugins.panelState.patch` | `pane`, optional consistent `tab`, `expectedPanelId, expectedStateRevision, operations` | IDs/revision/changed plus ordinary workspace commit fields |
| `plugins.panelState.reset` | `pane`, optional consistent `tab`, `expectedPanelId, expectedStateRevision` | Same result; clear state only |

Data methods default `id` from the native-bound page/service plugin identity; explicit IDs select another namespace for any trusted client. Commands/CLI can supply an explicit ID and use no pane. Merely reading or writing data never instantiates a panel or starts a process. Shared storage is namespaced, not an access-control boundary.

Panel methods default to the caller's host-bound pane when one exists. Services/tab/global backends without a pane must specify one; **no focused-pane fallback** and no synthetic instance target. Explicit pane/tab pairs must agree. Non-plugin, removed or stale targets fail even if another plugin currently has focus. A root CLI may use an explicitly supplied or validated inherited pane but must not accidentally inherit terminal-session guards for a different target.

Proposed page helpers:

```js
const data = await workspace.pluginData.get();
await workspace.pluginData.patch([
  {op: "set", key: "note:123", value: {text: "Hello"}}
], data.revision);

const panel = await workspace.panelState.get();
await workspace.panelState.patch([
  {op: "set", key: "selectedNoteId", value: "123"}
], {expectedPanelId: panel.panelId, expectedStateRevision: panel.revision});
```

Convenience methods default to self; use generic `workspace.call` / generated `workspace.rpc` for explicit other targets. Every helper accepts final `{signal,cause}` options, including reads and reset. Do not infer the latest revision silently or auto-retry conflicts. Data reset requires `{expectedDataRevision,force:true}`; panel reset requires the same identity/revision object as patch.

Typed CLI aliases: `plugins data get|patch|reset PLUGIN-ID` and `plugins panel-state get|patch|reset --pane P`, with `--operations`, `--expected-data-revision`, `--expected-panel-id`, `--expected-state-revision`, and reset `--force` where applicable. Support explicit plugin IDs for command-only plugins and live service callers with no workspace. Generic RPC and service clients see the same catalog/validation.

### 4.2 Patches, limits and errors

Use one small JSON-object patch validator for both stores, not TOML's editor or arbitrary JSON Patch:

- `operations` is 1–32 entries: `{op:"set",key,value}` or `{op:"delete",key}`. Keys are literal top-level strings, not dotted paths. Reject unknown fields, duplicate keys, invalid key grammar/size and delete with a value. `set` replaces that value; no recursive merge. Stored JSON null is valid and distinct from deletion; full-object reads preserve that distinction.
- Whole-document optimistic revision checks are mandatory on every patch/reset. Different-key concurrent writes may conflict; callers reread and deliberately rebase their local edit. No last-writer-wins whole-document helper, hidden retries or transaction spanning the two stores.
- Equal patches/deletions of absent keys retain semantic revisions and emit no event. Validate supplied guards even for a no-op. A durable-data no-op performs no filesystem write; a panel-state no-op may still attempt the existing workspace snapshot save and reports its actual `workspacePersistence` (support explicit recovery after a failed save without a new state/workspace revision). **Reset is not a no-op**, even on an empty document: it advances its generation and publishes a reset invalidation. Do not generalize patch equality into reset behavior.
- Initial budgets: 256 KiB JSON-encoded `values` and 1,024 keys per durable namespace; 32 KiB and 128 keys per panel state; 64 KiB plugin configuration per panel; 2 MiB aggregate encoded plugin records per live workspace. Keys are 1–256 UTF-8 bytes. A single `set` value is at most 16 KiB; an encoded patch array is at most 48 KiB for both stores. These are intentionally small structured stores, not document/blob databases. The former ~1 MiB instance-store allowance is not retained as a compatibility promise.
- Check all logical budgets before model/file effects. Independently enforce actual JSON-RPC/bridge envelope limits (64 KiB page requests, 1 MiB responses/socket messages), including UTF-8/escaping/metadata overhead; test worst-case strings. Never silently truncate values. Saved-layout validation/default merging must use the same plugin-configuration and aggregate budget rules as live creation.
- Required identity/revision mismatch: `APIError.conflict` (`-32050`), with bounded current IDs/revision when safe. Invalid shape/bounds/unsupported guard: `-32602`. Missing target/namespace: `APIError.unavailable` (`-32051`); retired caller/document follows existing lifecycle errors. Persisted data write failure uses `APIError.settingsWriteFailed` (`-32054`), `persisted:false`, and the unchanged revision, with no raw filesystem path or values in page errors. Corrupt/unsupported stored format is a typed incompatible/unavailable result, not an empty successful read.
- A panel mutation with `workspacePersistence:failed|disabled|suspended` is a successful **live model commit**, not a saved-write claim. The plugin can render “view state not saved”; do not retry the mutation blindly. A later ordinary autosave/no-op persistence recovery may save the current model without inventing another state change.
- After transport timeout/disconnect, either kind of write may have happened. Read state before deciding what to do next.

### 4.3 Catalog, guard plumbing, identity and revisions

Update `AutomationMethod` families/admission/default resolution, `APIGuards`, `Native/WorkspaceAPI` discovery and guard validation/stripping, host dispatch, generated page RPC inventory, CLI aliases and relevant contract tests in the same change.

- Data operations support `expectedInstanceId` and their required data revision; reject pane/tab/session/layout/workspace guards instead of treating data as workspace-owned. Panel operations support normal app/workspace and consistent pane/tab routing, plus required panel identity/state revision on writes; reject terminal-session, document and layout guards that are not meaningful to panel restoration data.
- Recognize new guard names and enforce them only for relevant methods. Do not strip method-specific revision/identity fields before the handler receives them. Use paired public metadata to revalidate explicit targets across dialogs/awaits; do not reuse a bridge token or automation document ID as panel identity.
- `api.describe.pluginPersistence` advertises version, method/helper meanings, reset consent, budgets, events, error/result schemas, identity and persistence semantics, and removal of legacy instance storage. Public capabilities and methods agree across CLI/page/service.
- Preserve native-bound caller liveness/origin, per-plugin mutation admission and `{cause}` lineage for both stores. All pages of a plugin still share its mutation budget. A service/command's native ownership is independent of the target data namespace.

## 5. Events and reset controls

### Events

- `host.plugin.data.changed`: one **broadcast**, untargeted value-free event per effective namespace mutation. Include plugin ID, before/after data revision, operation attribution, reset flag, bounded changed-key summary/count/truncation. No `tab`, `pane`, or `targetInstanceId`, so existing default page/service subscriptions receive it across scopes and tabs. Consumers filter `pluginId` and reread their namespace. This avoids fan-out proportional to live instances and works with no open panels or a starting service.
- `host.plugin.panel-state.changed`: pane/tab-scoped model fact for state patch/reset, with plugin/panel IDs, before/after state revisions, bounded key summary, reset flag, and standard workspace operation attribution. No state/configuration values. Keep this lowercase event spelling distinct from camelCase RPC names: the journal/topic-filter grammar rejects uppercase characters. Update `WorkspaceRevisions` and `WorkspaceTransition` so state-only changes produce this fact plus the ordinary appropriately scoped workspace invalidation, but no layout/focus/type facts.
- Use the settings-event summary limits (at most 32 keys and 4,096 encoded bytes, plus total/truncated). An event must fit the 16 KiB event limit after attribution/delivery overhead. Preflight complete batches before mutation; no partial notifications or post-save fan-out limit surprises.
- Get cursor **before** snapshots, then subscribe; expired cursors require resnapshot. Document that events are invalidations, not a durable history. Authors should coalesce reads, compare derived state, reject stale read results and pass cause on genuinely event-triggered writes; never echo every data event into another write.
- On a tab-scoped move, the fresh page reads the retained panel state and global data in its new runtime. Preserve existing inherited-poll transfer and old-document retirement rules; state is not copied into destination runtime storage.

### Native UI and command parity

- Keep **Restore workspace on launch**. Add concise help: restores open panels and saved view state; closing a panel removes it; plugin data is retained separately. No new global/per-panel toggle and no claim of complete application/process restoration.
- Add **Reset Plugin Panel View…** in the existing plugin-pane menu and contextual Cmd-K/shortcut inventory, available only for a real plugin panel. Native confirmation explains it keeps saved data and starting configuration. Freeze pane/content identity and revision before the dialog; confirm through the shared reset operation after revalidation. Cancel/stale target changes nothing. Adapt the current Cmd-K filter excluding `contract.requiresArguments` commands for this context-supplied native action; do not weaken the API's required guards to make it appear. Test actual picker visibility and dispatch. Plugins must reread panel state after the event; reset itself does not restart a backend or reload a document.
- Shared noninteractive command `plugins.panelState.reset` is a thin adapter to the reset operation, with explicit required guards for automation. Reserve `plugin.<id>.<command>` for contributed executable commands; never put this host operation in that dispatcher. Add this ID to `CommandContract` as explicitly **pane-dependent**, overriding the current broad `plugins.*` workspace-independent default, and support its guards through `command.run` as well as the direct RPC. Native actions may obtain the guards before confirmation; API callers never get an interactive dialog. No default shortcut.
- In Settings → Plugins add **Delete Slate-managed Plugin Data…** for the selected registration. Explain that all views share it and it does not delete preferences, panel selections, external files or a backend database. Capture ID/data revision before confirmation, then invoke `plugins.data.reset` with `force:true`; stale edits conflict. No silent reread/retry after confirmation. Enable/disable/unregister continue retaining data and say so.
- Data deletion has an ID-targeted API/CLI but no parameterless destructive Cmd-K action or automatic shortcut. Retained data for an unregistered plugin remains accessible/resettable by explicit ID through the API/CLI, or by re-registering for the Settings control; no separate orphan-data browser in this change.
- Reset advances the namespace/state revision so queued stale autosaves fail. Live consumers can intentionally create new data after rereading the empty namespace; reset is not a permanent write lock. It does not clear unrelated storage, settings, layout library, cookies, or command/service configuration.

## 6. Implementation sequence and file map

Do these in reviewable increments, not as independently shipping half-contracts:

1. **Core/persistence foundations, red tests first.** Add patch/document/record types and validators in Core, `PluginDataStore` in Settings, tests in `Tests/SlateTermCoreTests` and `Tests/SlateTermSettingsTests`. Extend `Pane`, creation/type/close/move/restore invariants, snapshot version, revision ledger/transition. Add pure model operations; do not implement storage in a web view.
2. **Shared host operations and clients.** Add host data manager/API handlers, panel commit fast path, discovery/guards/defaults, CLI/page helpers and events. Remove `PluginInstance` persistence/legacy methods and instance-directed storage callbacks. Preserve runtime scope and WebKit behavior. Update caller/SDK/inventory/guard tests and build scripts/project file inclusion if required for new Native files.
3. **Configuration restoration and lifecycle integration.** Move plugin starting inputs into candidate model creation; audit every creation path (normal type switch/split, saved-layout open, restore), close/forced disable/unregister, provisional preparation rollback and cross-tab move. Remove plugin reliance on `layoutRecipes` without persisting/rerunning terminal startup. Update capture and UI/state reset paths.
4. **Native controls and authoring contract.** Wire Settings deletion, pane reset/menu/picker/shortcut metadata and native confirmation through shared handlers. Update help, public docs, skill/reference, and a minimal nonvisual persistence example/fixture demonstrating shared notes + independent selections. Do not redesign example UI or add a framework/backend just for persistence.
5. **Verification and independent implementation review.** Update existing fixtures, add targeted regressions/fault injection, run package/build/static gates and selected VM integration gates; obtain fresh implementation review and rendered visual review for changed native controls. Resolve findings before claiming completion; record exact tests, failures and omissions.

Primary files besides the new types/handler: `Sources/SlateTermCore/{Workspace,WorkspaceTransition,WorkspaceMutationCommand,APIFoundation,AutomationAPI,SavedLayout,SavedLayoutFields,CommandContract}.swift`; `Sources/SlateTermSettings/{WorkspaceStore,PrivateJSONStore,PluginCatalog}.swift`; `Native/{ApplicationSettings,PluginInstance,PluginPane,WorkspaceHost,WorkspaceOperations,WorkspaceAPI,SavedLayouts,SettingsWindow,EventControl,EventHub}.swift`; `Sources/SlateTermCLI/{SlateTermCLI,LayoutCLI}.swift`; relevant IPC client guard negotiation/adapters. Reuse existing catalog/lease/atomic-file helpers; do not rewrite them gratuitously.

Documentation deliverables: `docs/{plugins,saved-layouts,configuration,agent-api,control,events,background-services,pane-movement}.md`, relevant API parity/discovery descriptions and `docs/api-extension-progress.md`. Update references/tests that describe tab-scoped storage adoption. Keep historical design/review documents clearly historical rather than rewriting their evidence.

Skill deliverables: `skills/slate-terminal/SKILL.md` and `references/building-plugins.md` must include a decision table for shared data / panel state / preferences / template inputs / ephemeral DOM / external database; exact new helper examples; runtime-scope independence; save during editing rather than unload; startup/read/subscribe order; conflict/recovery and save-error handling; no browser-storage durability assumption; lifecycle/reset/template/launcher semantics. Require a panel's data defaulting to be non-destructive: an empty panel state must never clear shared data. Record a plugin-owned format version within values and explicitly handle incompatible content; host envelope versioning cannot migrate an author's schema. Do not promote panel/instance/view IDs to durable user-document identities. Verify the packaged/installed skill copy follows the app's existing resource refresh path.

## 7. Acceptance tests and evidence

### Pure model/store and static tests

- Same plugin, different panes/tabs/runtime scopes: one shared namespace, independent state. Different plugin IDs and isolated state roots cannot collide. Command-only/disabled registrations and retained unregistered namespaces can access data without activation; unknown IDs/path traversal fail.
- Missing vs empty vs corrupt/unsupported namespace; null vs absent key; invalid/duplicate operations; all limits including escaped Unicode, request/result envelopes and aggregate workspace budget; no-op writes/events/revisions.
- Save-before-assignment failure, private-file ownership/symlink checks, initial empty revision, two readers competing, reset invalidating stale writers, revision persistence across app restart; no automatic retries. Specifically read empty revision R, queue a set, reset, then submit the old set: it must conflict for a missing data file, persisted empty namespace, and empty panel record. Assert reset notification/changed revision even when empty. Fault injection before journal publication/file replacement leaves previous file/cache untouched.
- Panel content identity uniqueness, plain/default/template creation, required-field-without-default rejection before activation, changed manifest defaults across restart, same-type no-op, genuine type replacement then switch back, close/tab close/removal, move preserving state, reload/navigation preserving state, reset retaining configuration. Plain opening and template opening must both validate complete candidates/defaults/aggregate budgets before transition construction; rejected preparation/publication leaves identity counters/records unchanged.
- Snapshot round-trip includes starting configuration/state; legacy schema preserved and rejected without overwriting; malformed record/type/identity/size fails. Update current-schema fixtures such as `scripts/verify-window-recovery.py` (currently hardcoded schema 1), separately retaining explicit legacy-rejection coverage. Old scoped plugin-data files remain byte-identical and unconsumed. Public topology projections omit values. State-only changes advance state/workspace but not layout revision; no focus/native reconstruction.
- Feed actual transition publications through `EventJournal.appendBatch` and poll using exact `host.plugin.panel-state.changed` topic filtering; verify its scoped workspace invalidation. Test `command.run` with `plugins.panelState.reset` via native/page/CLI/service paths, no contributed process launch, proper page defaults and no unanchored service fallback.
- After a panel snapshot-save failure, restore write access and issue an equal guarded patch: file is saved, semantic revisions/event cursor unchanged. Separately assert equal durable-data patches perform no filesystem write.
- Template capture excludes shared data/panel state and includes original configuration before/after restart. Opening twice yields separate identities/empty state while both see shared data; no startup-command replay on app restoration.
- Method catalog/guards/helpers/CLI alias parity; meaningful missing/foreign identity errors; explicit cross-namespace access allowed for trusted clients; ordinary browser/subframe/foreign-origin pages remain unbridged. Unsupported guards fail closed.

### Native/API integration gates (VM only)

Add a registered `plugin-persistence` gate in `scripts/verification_gates.py`, covering production APIs with isolated fixtures, plus updates to existing `plugins`, plugin-services/lifecycle, saved-layouts, workspace-persistence, window-recovery, agent-skills, storage-causation/trusted-api fixtures, API-settings, cross-window movement and background-service gates as appropriate. Rename legacy storage test labels if removed; do not leave tests calling removed helpers.

Scenarios:

1. Write shared notes and two independent selections; reload both, move between tabs for each runtime scope, quit/restart. Verify data/selection/configuration and fresh runtime/document IDs; retain panel IDs. Global same-runtime panels still have independent selections.
2. Close a panel/window, then reopen template/Spotlight recipe target: data retained, fresh panel state, configured document reference resolves. Close then quit is distinct from quit with windows open. Verify launcher packaging/URL opens the existing template route; real Spotlight indexing/Launch Services testing is separate and must not be claimed from API coverage.
3. Disable/unregister force and cancel/stale native dialogs; re-register; data retained, no restored deleted panel record. Delete/reset cancellation, revision races, no unrelated namespace/settings/configuration deletion, no automatic process activation.
4. Service/command with no panels reads/writes shared data; service sees data invalidation between snapshot and ready. Different pane-scope instances in different tabs receive a shared-data change; unrelated plugins can filter it. Default/explicit recipient and stale-document/cause rejection unchanged; event values remain absent.
5. Storage/file/journal failure and workspace save failure: inspect real file/cache/revisions/events and response statuses. Restore off/suspended does not block data persistence; panel writes report the actual workspace save outcome. Restart confirms only acknowledged saved state, not a test fixture's in-memory values.
6. Reset with a queued old write conflicts; a fresh intentional write after reread works. State reset updates a cooperating page without a process restart. The example/helper cancels pending pre-reset debounces and does not rebase an obsolete edit onto the new reset revision; stale reads/reset rehydration never overwrite a subsequent intentional edit. Distinguish an explicitly chosen post-conflict user edit from automatic stale autosave recovery.
7. Native menu/picker availability and Settings confirmation texts/actions with fresh screenshots; no focus change or layout rebuild while autosaving state. Explicit foreign target and inherited-target races remain guarded.

Run host-classified package/build/static checks only on the host. Discover exact integration gate names with `python3 scripts/verify-vm.py --list`; run native gates sequentially in VMPal, no host-GUI fallback or guest compilation. Register any new gate, inspect actual gate statuses/source-binary receipts and report what was not run. A reviewed plan or old suite receipt is not proof of implementation correctness.

## 8. Review checkpoint and completion criteria

Before implementation, ask an isolated read-only reviewer to inspect this plan against the relevant source. Focus on lifecycle ambiguity, deletion/data loss, scope/move compatibility, startup/configuration restoration, stale guards, storage failure semantics, event routing/bounds, API parity and missing tests. Record findings and resolutions in `docs/plugin-persistence-plan-review.md`; re-review material corrections if necessary.

Implementation is complete only when the new stores/identities work through native and all trusted clients, lifecycle and layout regressions are covered, unsupported legacy calls are removed, authoring guidance matches the shipped build, and actual verification/review outcomes are recorded. Unimplemented recommendations remain explicitly planned, not checked off.
