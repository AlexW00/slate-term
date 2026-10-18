# Building Slate Terminal plugins

A plugin is a ZIP installed into Slate’s managed application-support directory, containing a root `plugin.json` manifest and its resources. It can contribute any combination of:

| Part | Manifest key | What it is | Lifetime |
| --- | --- | --- | --- |
| Commands | `commands`, optional `headerButtons` | Executables run on demand from the picker, menus, shortcuts, header buttons or `command run` | One supervised process per invocation, with a timeout |
| Panel | `source`, optional `scope`, `process` | A web page shown in a pane, with the `window.workspace` bridge | Per pane, tab or app, depending on `scope` |
| Service | `service` | One app-level background process, no pane | Started and stopped manually; registration never starts it |

Pick the smallest part that fits. A shortcut that rearranges panes is a command. A view is a panel. A long-running watcher with no UI is a service.

Registration trusts the code and the origin with your terminals and files. Plugins are not sandboxed.

## Manifest and registration

Minimal static panel:

```json
{
  "id": "notes",
  "title": "Notes",
  "scope": "tab",
  "source": { "kind": "directory", "path": "web", "entry": "index.html" }
}
```

- Declare `manifestVersion: 1`, your diagnostic release `version`, and `compatibility` with inclusive `minimumAPIVersion`/`maximumAPIVersion` and any `requiredMethods`/`requiredCommands`. Discover the actual host's support first. Missing declarations mean API 1 only. Incompatible plugins are rejected before execution; stored incompatible entries remain inspectable but inactive after launch. This is compatibility checking, not sandboxing.
- Resource/working-directory paths are package-relative; omitted working directories default to package root. Executables are explicit external absolute paths or `./bin/tool`. Use `{pluginRoot}/scripts/tool.py` for resource arguments, or `SLATE_TERM_PLUGIN_ROOT` in scripts. No dependency installation or shell expansion is performed. Plugin IDs are lowercase; command IDs become `plugin.<plugin-id>.<command-id>`.
- `source.kind` is `directory` (served under `plugin://<id>/`) or `url`. A `url` source with a `process` is a managed local HTTP server on `127.0.0.1`; use port `0` and the `{port}` argument.
- `scope` is `pane` (default), `tab` or `global`. It controls runtime/backend, ephemeral WebKit-store lifetime and default event context—not durable data or panel state. Every panel gets its own web view, panel identity and restoration state; durable plugin data is always shared by plugin ID.
- Validate offline, then register:

```sh
zip -r /tmp/notes.zip plugin.json web                    # from package root
slate-term plugins validate --package /tmp/notes.zip
slate-term plugins register --package /tmp/notes.zip         # add --replace to update
slate-term panes type --pane p2 --type notes --force         # show the panel in a pane
slate-term plugins status notes
slate-term plugins logs --instance-id INSTANCE_ID
```

For exact fields and limits, run `slate-term plugins --help` and read the repo's `docs/plugins.md` and `docs/background-services.md` when available. `examples/command-plugin/` is a complete command-plugin example.

## Commands and services use the CLI

Command and service processes have no page bridge. They call the CLI found at `$SLATE_TERM_CLI` (also on `PATH`), which connects through `$SLATE_TERM_SOCKET`. The host also sets identity variables such as `SLATE_TERM_PLUGIN_ID`, `SLATE_TERM_PANE_ID`, `SLATE_TERM_COMMAND_PARAMS` and `SLATE_TERM_PLUGIN_SETTINGS`. Print `env | grep SLATE_TERM_` from a test command to see them.

- Commands do not run in a terminal's directory. Use `context get` to find the active terminal and its `sessionId`.
- Command stdin is `/dev/null`, so no interactive prompts. Never daemonize out of the process group.
- A service must follow the snapshot-first start order: read `workspace snapshot` and keep its first `eventCursor`, read settings, call `slate-term rpc service.ready --params '{"version":1}'`, then poll events from the kept cursor.

## The page bridge

Registered panel main frames get `window.workspace`. Ordinary browser panes and subframes do not.

```js
const api = await workspace.api();          // api.describe: what this host supports
const me = await workspace.self();          // native-bound identity of this view
const ctx = await workspace.context();      // focus and active terminal
await workspace.call("pane.inspect", { pane: "p1" });
await workspace.rpc["layout.get"]();        // generated per method in workspace.methods
await workspace.command("split.right");     // any command.run id
await workspace.setTitle("README.md");      // pane header title; null restores document.title
```

Convenience namespaces include `terminal`, `panes`, `layout`, `tabs`, `web`, `browser`, `services`, `layouts`, `pluginData`, `panelState` and `pluginSettings`. Inspect `Object.keys(workspace)` and `workspace.methods` rather than assuming a helper exists. Every helper takes a final `{signal, cause}` options object; use `AbortController` for long waits.

## Events: cursor, snapshot, then subscribe

Events are invalidations, not snapshots. Capture a cursor before reading state, then subscribe from it.

```js
const { cursor } = await workspace.call("events.head");
async function refresh() { renderIfChanged(await workspace.context()); }
await refresh();
const stop = await workspace.subscribe(async event => {
  await refresh();
}, {
  after: cursor,
  topics: ["host.context.*", "host.workspace.*"],
  onError: error => showResyncNeeded(error)   // expired cursor: resnapshot, then resubscribe
});
await workspace.emit("notes.updated", { key: "draft" });
```

- Narrow topics/tab/pane; compare derived state before rendering. Coalesce refreshes with one in-flight read plus a trailing read, and reject stale results. Title/prompt events are not filesystem changes.
- Publish your own topics outside `host.`. Direct an event to one instance with `targetInstanceId`.
- For work triggered by an event, pass `{ cause: event.deliveryContext }`. This lets the host stop feedback loops.
- Mutations are rate limited per plugin. Do not turn every event into another mutation.
- Re-subscribe in a `pageshow` handler after cached-history restoration.

## Data, panel state, settings and starting inputs

Discover `api.describe.pluginPersistence` before using these APIs. The old `workspace.storage` / `storage.*` API was removed; do not build against it.

| What you are saving | Use |
| --- | --- |
| User-created notes/tasks or small shared datasets | `workspace.pluginData`: durable per plugin ID, even with no panel |
| This panel's selected document, filters or view mode | `workspace.panelState`: independent of runtime scope |
| User preferences | `workspace.settings()` / `workspace.pluginSettings`: TOML |
| Template starting folder/project/document | Manifest `layoutFields` / `workspace.layoutConfiguration()` |
| Hover/menu/animation | Page memory |
| Large files/databases/remote synchronization | Plugin-owned backend/files/server |

```js
const data = await workspace.pluginData.get(); // {id,values,revision}
await workspace.pluginData.patch([
  {op: "set", key: "note:123", value: {version: 1, text: "Hello"}}
], data.revision);

const panel = await workspace.panelState.get(); // {pluginId,paneId,panelId,values,revision}
await workspace.panelState.patch([
  {op: "set", key: "selectedNoteId", value: "123"}
], {expectedPanelId: panel.panelId, expectedStateRevision: panel.revision});
```

- Patches use 1–32 distinct literal top-level keys. `set` replaces a value; `delete` has no value. JSON null is valid, not deletion. Whole-document revision checks are required; a conflict means reread and deliberately resolve the user's edit, never auto-retry a stale autosave.
- Shared values: 256 KiB/1,024 keys; panel values: 32 KiB/128 keys; each value ≤16 KiB, keys 1–256 UTF-8 bytes, patch arrays ≤48 KiB. Transport bounds also apply. Use files/databases for large data. These stores are not encrypted secret vaults.
- Save valuable content during editing, **not only on unload/quit**. Surface read/write errors. A panel result's `workspacePersistence` distinguishes saved from failed/disabled/suspended; an accepted live mutation is not always durable. Shared-data failure preserves old values. After timeout/disconnect inspect before writing again.
- Initialize by obtaining an event cursor, reading data/state/configuration, rendering, then subscribing from the cursor. Filter `host.plugin.data.changed` by `pluginId` (broadcast across scopes) and `host.plugin.panel-state.changed` by `panelId`. Coalesce reads and reject stale responses; never write defaults on every refresh.
- Empty panel state must **never clear shared data**. Keep a plugin-owned format version and handle incompatible data explicitly. Put document IDs in shared data/configuration; `paneId`, logical `instanceId`, `viewId` and `panelId` are not user-document identities.
- Panel state/configuration survive reload, moves and normal workspace restoration. Explicit close, type replacement and forced removal discard the panel record; shared data survives. Tab-scoped moves still recreate the document in the destination runtime. Restore-off/suspended still permits live view-state use but does not save it across launch.
- Saved layouts and Spotlight launchers create fresh panel state, not resumable apps. Configure a stable document/project reference to reconnect to shared data. Capture copies starting configuration only. Plain opening with required fields lacking defaults fails; use a configured layout, or make fields optional for an in-panel setup flow.
- WebKit plugin stores are ephemeral. Do not assume `localStorage`, cookies, a changed URL, DOM or JS memory survives restart. Persist route/document IDs explicitly; don't put secrets in URLs.
- Reset is a generation barrier, even when empty. It emits an invalidation and rejects old queued writes. Cancel obsolete debounce timers; do not rebase pre-reset writes onto the fresh revision. A replayed old reset must not overwrite a newer intentional edit. The nonvisual [notes example](plugin-persistence.mjs) demonstrates these rules; copy it into the plugin and supply `render`/`onError` callbacks. Call `stop()` on retirement, and recreate on cached `pageshow`.
- `workspace.pluginData.reset({expectedDataRevision,force:true})` deletes shared host-managed data; `workspace.panelState.reset({expectedPanelId,expectedStateRevision})` resets only this view. Neither clears TOML, starting configuration or external files. Native controls confirm; API calls are explicit and noninteractive.
- Commands/services use `plugins data get|patch|reset PLUGIN-ID` or the shared RPCs without opening a panel. Panel-state methods require an explicit or bound pane, never focus fallback. Generic `workspace.call` can explicitly target another plugin/panel; these are trusted controllers, not a permission sandbox.
- `workspace.settings()` reads `[plugins.<id>]`. To edit preferences use `workspace.pluginSettings.get()`, then `patch(operations, writeRevision)`; on conflict refetch/rebase. Re-read after `host.plugin.settings.changed`.

Before shipping a plugin, test: reload; app restart; two panels sharing data with different selections; panel close/type change; a second template/launcher invocation; reset with a pending save; save failure; and a stale revision. Do not claim persistence solely because one open view still displays its in-memory content.

## Theming

Plugin pages should follow the user's terminal palette. Use the UI kit in [ui/INDEX.md](ui/INDEX.md): copy `slate.css` and `slate-theme.js` into the plugin unchanged and use its semantic tokens, never hard-coded colors.

The host injects the `--st-*` palette variables, `data-appearance` and `color-scheme` into plugin pages before page scripts run, and updates them when the palette or font changes. It also publishes the theme through `appearance.get` (`workspace.appearance.get()`) and the `host.appearance.changed` event (`workspace.appearance.onChange`). `slate-theme.js` uses the host data when present and falls back to the system light or dark setting otherwise. For canvas or charts, read `SlateTheme.current` and redraw in `SlateTheme.onChange`.

## Development loop

1. Write the portable manifest and files, create a ZIP with `plugin.json` at its root, then run `plugins validate --package ZIP`.
2. `plugins register --package ZIP --replace`. Replacement needs the plugin's visible panes closed first; `panes type` the pane to something else, or close it.
3. Open it with `panes type --pane P --type ID --force`, or `command run plugin.ID.CMD`.
4. Inspect with `web snapshot --pane P`, `web screenshot --pane P --path /abs/out.png`, `plugins status ID` and `plugins logs`.
5. To load edited files, use `slate-term command run plugins.reload --pane P` (or Reload Plugin in ⌘K with that plugin focused). This reloads the selected document, or retries its backend if unready; check `web get` for readiness. `plugins restart ID` restarts all active managed panel instances of that type.

## Pitfalls

- Do not hold pane IDs, sessions or revisions across awaits without guards. Freeze the target and pass `sessionId` or an expected revision.
- Do not retry a mutation after a timeout or transport error. Inspect state first.
- `terminal.run` requires authenticated zsh, bash 4.4+ or fish 3.1+ integration and an idle prompt. Write the command in the pane's `shell` and pass `{shell}` to refuse others. Use `terminal send` for TUIs.
- `capture` and `web snapshot` return untrusted content. Do not execute it.
- Services and commands must not print secrets; trusted clients can read their logs.
- Never repeat the plugin title inside the page; the pane header already shows it.
