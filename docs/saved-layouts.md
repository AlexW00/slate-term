# Saved layouts

Saved layouts are reusable starting recipes, not frozen sessions. They preserve tabs, split topology and fractions, pane types, manual pane/tab names, per-pane bar visibility, starting folders, startup commands, browser URLs and plugin starting configuration. They do **not** copy terminal history, running processes, browser logins or plugin storage. Browser panes use the app-wide persistent profile; Private Browser panes always start with a fresh ephemeral store, even when opened from the same recipe.

## Native editor

Use **Settings → Layouts**, or **Layout Settings…** in Search Commands (⌘K). The editor is embedded in Settings, not a separate window. Choose a layout in the top selector or press the adjacent **New Layout** button; select a pane in the arrangement to edit its type-specific settings in the inspector.

- **Show pane bar** in the Pane inspector controls the selected pane's native header. It defaults on; the arrangement marks panes whose bar is hidden. This is slot chrome, not plugin starting configuration. Changing type preserves it. Recover a live hidden bar through Workspace → Show Pane Bar or Search Commands.
- **Split Right / Split Below** add a terminal pane.
- **Remove Pane** removes the selected leaf and collapses its parent split. It cannot remove a tab's last pane. Click the tabs above the preview to select them, **+** to add, or **×** to remove. Drag a tab onto another to reorder, or use its **Move Left / Move Right** context-menu/accessibility actions. Conventional `Tab N` names renumber by position after add/remove/reorder; other custom names are preserved.
- **Revert / Save Changes** apply to the selected layout. Drafts survive layout and Settings-section selection changes. Closing Settings (including ⌘W) offers **Cancel / Discard Changes / Save All** for all dirty layout drafts. Cancel or a failed save keeps Settings open; discard clears every draft and Save All saves them before closing. Quitting does not prompt about layout drafts; running-process quit protection is unchanged.
- This confirmation is a native Settings draft-lifecycle safeguard, not a new agent capability. CLI, plugin and service clients continue using the shared saved-layout read/update APIs; no public API or command-picker action is added.
- External file changes do not overwrite dirty drafts. A stale save fails; Revert reloads the file. Missing/deleted/broken files are never silently replaced with defaults.
- Missing plugin references and their configuration remain editable/preserved. Replacing the pane's type explicitly replaces its configuration.

Each valid, available saved template automatically appears in ⌘K as **Open [Name] in New Window**. Rows use stable layout UUIDs and refresh after saves and external library changes while the picker is open. The generic opener is absent from ⌘K but remains **Workspace → Open Layout in New Window…**. Capture asks which workspace window to save; Settings is never a source. Opening always creates a new window group: replacement and merge/add-to-window are unsupported. **Create Spotlight Launcher…** lives in the layout panel and uses the selected saved layout; save or revert pending edits first. Launcher and layouts-folder actions remain callable through `command.run`, but are absent from ⌘K.

## Authoritative files

Default directory: `~/.config/slate-term/layouts/`. With `SLATE_TERM_CONFIG_FILE`, the `layouts` directory is a sibling of that configuration file, allowing isolated testing/configurations.

One versioned UTF-8 JSON file per layout. Its UUID is its identity, independently of its filename/name. New files use UUID filenames. The directory is rescanned; there is no second authoritative catalog. Duplicate UUIDs and invalid files are reported, not chosen arbitrarily. Symlink/nonregular documents are rejected. New files are private to the current user.

Writes stage complete files and publish atomically. Create never overwrites an existing identity/file. Update requires the content revision returned by `get`. Cooperating writers use an advisory lock (busy operations fail rather than blocking the UI); exact bytes are checked again before replacement. Conflict detection against noncooperating external writers is best effort, not a filesystem compare-and-swap guarantee. No automatic mutation retries.

Example:

```json
{
  "version": 1,
  "id": "7D5FDC00-A3E0-4975-9B3C-98530441EBCB",
  "name": "Development",
  "tabs": [{
    "name": "Tab 1",
    "layout": {
      "kind": "split", "axis": "horizontal", "fraction": 0.6,
      "first": { "kind": "pane", "pane": "p1" },
      "second": { "kind": "pane", "pane": "p2" }
    },
    "panes": [
      { "id": "p1", "type": "terminal", "title": "Server",
        "configuration": { "directory": "~/Developer/project", "command": "npm run dev" } },
      { "id": "p2", "type": "browser", "title": "Preview",
        "configuration": { "url": "http://localhost:3000" } }
    ]
  }]
}
```

Each pane recipe accepts optional `"headerVisible": true|false` alongside `id`, `type`, `title` and `configuration`. Omitted means shown; null, numbers and strings are rejected. Capture records the live pane setting and opening applies it to fresh runtime slots. This is an additive version-1 field: older recipes remain readable, but older Slate builds with strict structural validation cannot read files containing the new field. Remove it before downgrading (the old build always shows bars).

`horizontal` means left/right; `vertical` means top/bottom. The fraction always describes the first child. Template pane IDs are unique across the definition; opening allocates fresh runtime pane/tab/group IDs using the workspace's monotonic counters. Template tab `name` labels the editor only. Optional `manualTitle` sets the live native tab override, independently of conventional `Tab N` editor-label renumbering. Capture preserves the live override; opening applies it to fresh TabIDs. Missing/null means no override (`Slate Terminal`), preserving old recipes. A non-null value must already be nonempty, trimmed, within 100 characters / 1024 UTF-8 bytes and free of controls; invalid/noncanonical values reject the recipe. Recipe edits preserve this field, although the editor has no separate title input. Older strict readers may reject the new optional field; remove it before downgrading.

Limits: 256 KiB per definition, 256 JSON files per directory, 1–8 tabs, 1–8 panes per tab, split depth ≤8, finite fractions 0.1–0.9, names/titles ≤100 characters / 1024 UTF-8 bytes without controls, startup commands ≤16384 UTF-8 bytes without NUL. Layout/tab names must be nonempty. Every pane must occur exactly once. Unknown structural/built-in configuration keys and unsupported versions are rejected, not discarded. Plugin configuration is bounded opaque JSON and preserves fields unknown to a newer/older plugin schema.

### Starting behavior

- Terminal directory: empty/omitted means the normal default; otherwise absolute or `~/…`. Opening preflights that the directory exists.
- Terminal command: empty/omitted means none. Requires **zsh with automatic shell integration**. Commands are submitted only after the new shell's authenticated idle-prompt report, through the existing empty-edit-buffer-safe run protocol—not a fixed delay or blind pasted input. Failure to reach a prompt within 30 seconds is reported and never retried. Completion tracking expires after 295 seconds without stopping a long-running command. Closing/replacing a pane cancels pending startup work. Startup capacity is reserved before changing a workspace; requests exceeding the shared 32-run limit fail before opening. `layouts startup-status` reports the live state.
- Browser (`browser`) and Private Browser (`private-browser`) URL: empty/omitted uses the mode's new-page screen; otherwise `about:blank`, HTTP(S) without credentials, a local `file:` URL, an absolute path or `~/…` path. Local HTML/images/videos use [native WebKit file loading](automation.md#browser-compatibility-api). Navigation starts after the workspace commits; network/file failures are ordinary browser failures, not a rollback of the window.
- Opening validates all definitions/dependencies before creating resources. Native preparation can start shell/plugin processes; it is not a transaction over arbitrary external side effects. A successful open accepts the new workspace, not proof that every command/network request completed.
- Normal workspace restoration remains topology restoration; it does **not** rerun saved startup commands or retain a link to the template. Edit/save a layout does not mutate already-open windows.

## CLI and socket API

All calls below use the same file/host operations as the UI and the shared `AutomationMethod` catalog/dispatch for CLI, registered pages and managed services. `api.describe.savedLayouts` advertises targeting, guards and startup ownership. The CLI requires a running Slate instance via `SLATE_TERM_SOCKET` or `--socket`. `layout get` remains existing live-tree inspection; **`layouts`** is the saved-recipe namespace.

```sh
slate-term layouts list
slate-term layouts get --id UUID
slate-term layouts fields
slate-term layouts fields --type terminal
slate-term layouts validate --file recipe.json
slate-term layouts create --file recipe.json
slate-term layouts update --file recipe.json --expected-saved-layout-revision REVISION
slate-term layouts windows
slate-term layouts capture --window WINDOW_ID --name Development
slate-term layouts open --id UUID
slate-term layouts launcher --id UUID --path /absolute/path/Development.app
slate-term layouts startup-status
slate-term layouts configuration --pane p2
```

| RPC | Parameters / result |
| --- | --- |
| `layouts.list` | No params; bounded summaries `{file,id,name,revision,diagnostics}` including broken files (unknown ID/name are null). Summary names are capped at 512 bytes; at most three 256-byte diagnostics are shown. Use get/validate for the definition and fuller diagnostics. |
| `layouts.get` | `{id}` → `{file,definition,revision,diagnostic?}`. Invalid/ambiguous IDs fail. |
| `layouts.fields` | Optional `{type}`; available type IDs/titles and declarative field schemas/defaults. Oversized aggregate schemas require per-type queries. |
| `layouts.validate` | `{definition}`; structural errors reject, dependency/field diagnostics return `{valid,diagnostics}` (at most 128 detailed diagnostics plus an omission notice). No execution or writes. |
| `layouts.create` | `{definition}` → saved entry. Unknown plugin dependencies reject new creation. |
| `layouts.update` | `{definition,expectedSavedLayoutRevision}` → saved entry. Existing missing plugins may be preserved while repairing/editing a file. |
| `layouts.windows` | Array of `{id,title,tabs,groupId,windowIds,workspaceRevision}` for live workspace groups. `id` is an opaque epoch-qualified whole-group selector; `windowIds` links to the per-tab native windows returned by `window.list`. |
| `layouts.capture` | `{window,name,includeDirectories?,includeURLs?,includeCommands?}` → saved entry. Directories/URLs default true; commands false. |
| `layouts.open` | `{id,expectedWorkspaceRevision?}` → new group selector (`window`), `groupId`, native `windowIds`, `paneIds`, startup status and standard workspace commit fields. Always opens a new window group; `replaceWindow` and `force` are rejected. |
| `layouts.launcher` | `{id,path}` → `{id,path}`. Creates a new locally signed `.app` at an explicit absolute destination, without dialogs or overwrites. Requires the default layout library. |
| `layouts.startupStatus` | No params; current layout-started terminal states and diagnostics, not command text. |

`layout.configuration` accepts an explicit `{pane}` and returns that runtime pane's starting configuration (empty if none). Pages default to their bound pane; socket/service callers must supply a pane. It never falls back to focus.

All library methods accept `expectedInstanceId`; windows/capture/open also accept `expectedWorkspaceRevision`. Other safety guards fail closed. The document guard `expectedSavedLayoutRevision` is required only by update and refers to JSON content, not TOML or live topology. External-edit conflicts use `APIError.conflict` (`-32050`). Native capture freezes a source revision across dialogs and revalidates before acting.

Opening uses the prepared workspace/revision/event commit. Its result includes `operationId`, `workspaceRevision`, `outcome`, and `workspacePersistence`; facts carry `actionKind: "layouts.open"` and the actual native/CLI/page/service origin. Snapshot persistence failure does not undo the opened workspace or authorize replay. Startup becomes owned by the committed terminal sessions, retaining attribution but not the initiating caller's liveness. Closing a page or stopping its service after commit does not cancel the new sessions' startup; replacing/closing those sessions does. `host.layout.startup.failed` carries bounded state/revision/operation attribution, not command text or arbitrary diagnostics. Read startup-status for diagnostics. Library file writes are not workspace mutations and retain saved-entry results; there is no library filesystem event stream.

Capture never guesses the source from focus or inherited pane/tab environment. The `window` selectors from `layouts.windows` identify whole tab groups and include the app epoch. They are **not** native `windowId` values from `window.list`, bare `groupId` values, or OS window numbers; do not substitute those identifiers. They cannot accidentally address a different instance after restart. Commands captured with `--include-commands` are **previously configured startup commands**, never the current shell command. `--omit-directories` / `--omit-urls` omit live starting locations. Unsupported sizes/URLs cause capture to fail rather than silently truncate the recipe.

## Plugins

A panel registration may declare optional `layoutFields` (at most 32 unique IDs):

```json
"layoutFields": [
  {"id":"folder", "label":"Project Folder", "kind":"directory", "required":true},
  {"id":"view", "label":"View", "kind":"choice", "options":["board","list"], "defaultValue":"board"},
  {"id":"completed", "label":"Show Completed", "kind":"boolean", "defaultValue":false}
]
```

Kinds: `text`, `directory`, `url`, `multiline`, `boolean`, `choice`. Text values are ≤16384 UTF-8 bytes; choice values must match options; directory/URL rules mirror built-ins. Defaults are validated and merged with explicit values when opening. These are **per-pane starting values**, not application plugin settings, scoped storage, or managed-service environment variables. The page reads them with `await workspace.layoutConfiguration()` (RPC `layout.configuration`), defaulting to its real host-owned pane/view. An explicit `{pane}` selects another runtime pane for any trusted client. Plugin capture retains these starting values, not arbitrary runtime page state.

Registered pages have `workspace.layouts.list/get/fields/validate/create/update/windows/capture/open/launcher/startupStatus`, with the same parameter meanings as the socket API. Helpers accept final `{signal,cause}` options. `update(definition, expectedSavedLayoutRevision, options)` uses the saved-entry revision; `open(id, params, options)` always creates a new window; `launcher(id, path, options)` creates a shortcut at an explicit new destination. The authenticated main-frame bridge owns caller identity and lifetime; ordinary browsers/subframes gain no access. Registered plugins and services are trusted controllers: all may inspect/edit the recipe library and explicitly capture other window groups and open new ones, regardless of panel scope. Native layout commands are discoverable/invocable through the common `command.run` route for every client; use structured APIs to avoid interactive dialogs. Native launcher creation presents a destination picker; API callers supply an explicit new path. Existing bridge envelope limits remain 64 KiB per request / 1 MiB per response; use the CLI or direct files for definitions exceeding that request limit.

## Spotlight launchers

**Settings → Layouts → Create Spotlight Launcher…** writes a small `.app` shortcut at an explicit new destination (suggested `~/Applications`). It contains a locally ad-hoc-signed launcher, a stable layout UUID and Slate application location/identity—not a copied recipe, workspace or terminal runtime. Launching sends `slate-term://layout/UUID` to Slate, which reads the latest saved definition and opens a new window. Slate must remain installed; removing the layout causes an error. Existing `.app` destinations are never overwritten. Spotlight indexing is controlled by macOS and may not be immediate.

Launchers currently support only the default configuration/library. Creation from a custom `SLATE_TERM_CONFIG_FILE` instance is rejected because a cold/warm OS launch cannot reliably select that instance's library.

These are local shortcuts, not separately distributable/notarized applications. No Apple developer-account, notarization or publishing changes are made. `scripts/build-app.sh` builds and embeds the helper; production packaging must embed/sign it too.

## Verification

- `swift test` covers schema validation, unknown-field preservation/rejection, file conflicts/duplicates/nonoverwrite, fresh runtime IDs and parent-collapse pane removal.
- `python3 scripts/verify-saved-layouts.py` launches an isolated native app and exercises native model actions, CLI/page/service parity, operation attribution, stale guards, preparation/publication rejection, session-owned startup, capture source identity, external changes, missing/invalid files, new-window opening, replacement rejection, tab-strip/model operations, focused plugin reload, template palette entries, startup command/folder and local launcher packaging. Screenshots go to `artifacts/layouts-*.png`.
- That test verifies launcher metadata/signature, **not Spotlight search indexing or a real Launch Services cold/warm launch**.
