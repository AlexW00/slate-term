# Guarded layout, tab and window operations

These commands use the same model/native reconciliation as menus and registered page controls. See [agent identity and guards](agent-api.md) for target resolution and recovery. `workspace.get` and `layout.get` keep their legacy shapes.

## Focus preservation

CLI, registered pages and services preserve the current pane, tab and native key window during structural work. `split.*`, `pane.split`, `tab.new`, `window.new` and `layouts.open` default to `focus: preserve`; pass `focus: new` to select the created content. `pane.move` accepts `preserve` (default) or `target`. Moving the currently selected pane across tabs follows that same pane; moving a background pane keeps the destination's selection and terminal history order. Creating the first workspace necessarily establishes its initial selection.

Native shortcuts, menu actions, pane drags and layout launchers explicitly select their result. Automation uses `--focus-policy new` for pane/tab/layout creation, or `--focus-policy target` for pane movement. `window.new` accepts `{focus:"new"}` through `command.run`. Read `api.describe.workspaceFocus` and each command's input schema for policies.

Explicit pane/tab/window focus commands, tab navigation, pane zoom, and presentation commands such as Find or browser address editing still move focus intentionally. `window.focus` only activates the application when `activate: true`. Closing the selected pane/tab chooses a surviving target. Ordinary reconciliation preserves Settings and existing native responders; it does not raise every workspace window. New background windows appear behind existing windows.

## Pane and layout commands

Use `command.run` with an explicit `id` and ordinary `pane`/`tab` targeting:

| ID | Arguments | Required precondition |
| --- | --- | --- |
| `pane.split` | `direction`: left/right/up/down; `target`: pane (default) or root; `type`: terminal (default), browser, or registered panel ID; `newPaneFraction`: default 0.5; `focus`: preserve (default) or new | `expectedLayoutRevision` |
| `pane.move` | `target`: destination pane ID in any same-app tab/window; `direction`: left/right/up/down; `focus`: preserve (default) or target | Source `expectedLayoutRevision`; also `expectedWorkspaceRevision` for different tabs |
| `layout.resize` | `path`: array of first/second branches; `firstChildFraction` | `expectedLayoutRevision` |
| `pane.title.set` | `title`: string | Optional ordinary identity/revision guards |
| `pane.title.clear` | None | Optional ordinary identity/revision guards |
| `pane.rename` | None; ordinary `pane`/`tab` target | A visible, non-minimized pane with its bar shown |
| `pane.header.show` / `.hide` / `.toggle` | None; ordinary `pane`/`tab` target | Optional ordinary identity/revision guards |

Fractions must be finite and strictly between zero and one. A split fraction always describes the **new pane**, regardless of direction; resize describes the **first child**, excluding the divider. `target: root` wraps the complete tab layout. Types are validated before native preparation: a browser/plugin split does not first create a terminal. Model allocation, topology and type are committed together. Failures do not imply rollback of arbitrary shell startup or other external side effects.

Paths address split nodes, not leaves, and have at most 64 branches. `[]` addresses the root. Obtain paths from `pane.inspect` or walk `layout.get`; always pair them with the observed layout revision. Successful mutations return resulting workspace/layout revisions and relevant IDs/paths.

Native admission requires affected panes to remain at least 80 points wide and high. Root splits and subtree resize validate all affected leaves. Unavailable native geometry fails closed. `pane.move` supports any unzoomed source/destination tab in the same app instance and matches native drag/drop. It retains the PaneID and live terminal/browser/pane/global-plugin content; a tab-scoped plugin recreates its page against the destination tab's instance/ephemeral WebKit store. Shared plugin data and the moved panel's state/configuration remain intact; no runtime-store merge is involved. Moving the only source pane closes its empty tab/group without terminating the pane. Source `pane`/optional `tab` must agree; destination is always the explicit `target`, never a focused-pane fallback. `focus: preserve` does not steal focus from another tab and retains that tab's active-terminal history. Existing `split.left/right/up/down` remain simple 50/50 aliases and share native geometry constraints, without requiring a new revision argument. Native menus/picker suppress splits that cannot fit.

`pane.rename` is a presentation command: it opens the same anchored native popover used by clicking a header title, returns `{paneId: string}`, and does not set a title until the user confirms. It is discoverable through `command.list`, bindable without a default shortcut, and available via the picker, Workspace menu, CLI/socket (`command run pane.rename --pane p1`), registered pages (`workspace.command('pane.rename', {pane: 'p1'})`) and trusted services. Closed targets use the ordinary target error; hidden/minimized targets return `-32602` without revealing them. Native confirmation reuses `pane.title.set`; programmatic renaming should keep using `pane.title.set` / `.clear`, not a UI prompt. Cancel/outside dismissal never writes a title.

Manual titles are trimmed and limited to 4096 UTF-8 bytes; an empty title clears the override. Manual titles are separate from plugin-published automatic titles. Renaming does not close/rebuild live content or request busy-terminal consent. Inspection bounds displayed title strings and exposes `manualTitleTruncated`.

```sh
slate-term panes inspect --pane p1 --json
slate-term panes split --pane p1 --left --type browser --new-pane-fraction .3 --focus-policy preserve --expected-layout-revision TOKEN
slate-term panes split --pane p1 --up --root --expected-layout-revision TOKEN
slate-term panes move --pane p2 --destination p1 --down --expected-layout-revision SOURCE_TOKEN --expected-workspace-revision WORKSPACE_TOKEN
slate-term layout resize --tab t1 --path first.second --first-child-fraction .6 --expected-layout-revision TOKEN
slate-term panes set-title --pane p1 --title 'Build output'
slate-term panes clear-title --pane p1
```

`api.describe.paneMovement` advertises cross-window movement, guards, result fields and tab-plugin recreation. Inspect `pane.inspect.windowId`/`tabId` to associate destinations with `window.list`. `pane.move` replies include moved `paneId`, **destination** `tabId`/`layoutRevision`/`path`, `sourceTabId`, `sourceTabClosed`, nullable `sourceLayoutRevision` (null if closed), `contentRecreated` and standard commit fields. Missing required/unsupported guards or malformed arguments fail with `-32602`; stale identity/revisions with `-32050`; unavailable target/zoom/geometry with `-32051`. No retries, modal consent, automatic unzoom or terminal restart. A tab-plugin moving its own page may retire its caller after commit and lose the reply; inspect before deciding on further work.

**Move Pane…** (`pane.move.chooseDestination`) opens the native destination menu for a visible pane bar and is shared with the picker/Workspace menu/configurable shortcuts. API movement itself requires neither a visible bar nor a drag session. Inactive native tabs can be destinations with valid displayed-group geometry; minimized/ordered-out groups fail closed.

A plain `panes split --right` continues to call its legacy alias. Supplying type/root/fraction options selects the guarded atomic operation. `--focus-policy` alone works with the simple alias and does not require a layout revision.

## Pane bar visibility

```sh
slate-term panes hide-header --pane p1
slate-term panes show-header --pane p1
slate-term panes toggle-header --pane p1
```

These aliases call `command.run` IDs `pane.header.hide`, `.show` and `.toggle`. All trusted clients use the same targeting, validation and dispatch. An explicit or inherited stale target fails; it never redirects to focus. Supported optional guards are `expectedInstanceId`, `expectedAnchorSessionId`, `expectedWorkspaceRevision` and `expectedLayoutRevision`. Unsupported document/configuration guards fail closed. Replies include `paneId`, `tabId`, `headerVisible`, path/layout revision and standard commit fields. Show/hide are idempotent; toggle is not retry-safe. Repeated no-ops emit no event or revision. A real change emits `host.pane.header.changed` with resulting state and advances only the workspace revision, not the layout revision.

Read `headerVisible` through `pane.inspect`, `workspace.snapshot`, `panes.list` or `workspace.get`. This is the persisted **requested** bar state, independent of whether the pane is currently rendered (background tab, zoom or minimized window). Hiding removes the entire 28-point native header and gives its height to retained content; it does not hide the pane, change layout fractions/focus, recreate content, or change browser address/native tab bars. State follows the slot through moves, zoom/restore and type replacement. New panes default shown. Old snapshots and recipes default shown when the field is absent.

Show/Hide/Toggle Pane Bar remain available through the Workspace menu, command picker and configurable shortcuts (no default binding). Show the bar before using native rename/type/drag controls. Hiding cancels an open rename draft without saving; `pane.rename` refuses a hidden bar instead of revealing it. Programmatic title changes and registered plugin commands remain available. Saved-layout capture records current state, and the editor exposes **Show pane bar** per pane.

## Tab names

Choose **Workspace → Tabs → Rename Tab…**, use Cmd-K, or bind `tab.rename` (no default shortcut). A native sheet opens for a selected, visible, non-minimized tab; other sheets and application-modal dialogs block it (`-32051`). Return/Rename saves; Escape/Cancel discards. Closing, deactivating, switching or reparenting the target cancels the draft. If an API client changes its name meanwhile, confirmation reports a conflict instead of overwriting it. **Reset Tab Name** (`tab.title.clear`) is available when the captured tab has an override.

```sh
slate-term tabs set-title --tab t2 --title 'Build 日本語'
slate-term tabs clear-title --tab t2
slate-term command run tab.rename --tab t2  # interactive editor, not a setter
```

Canonical automation uses `command.run` IDs `tab.title.set {title:string}` and `tab.title.clear {}`. Page helpers are `workspace.tabs.setTitle(title, params={}, options={})` / `clearTitle(params={}, options={})`, with final `{signal,cause}`. Services use the identical public commands. `tab.rename` returns `{tabId,editing:true}` acknowledging presentation; later user confirmation is a separate native operation.

Names are trimmed, bounded to **100 Swift characters / 1024 UTF-8 bytes**, and reject remaining control characters. Empty/whitespace-only clears the override. Literal duplicate names (including `Tab 2` and `Slate Terminal`) are allowed. Unnamed tabs use `New Tab`; there is no process/directory-derived naming. Invalid input/unknown payload fields return `-32602`; optional workspace guards detect concurrent renames (`-32050`). Layout revisions do not protect title metadata. Normal instance/anchor-session/workspace/layout guards and pane/tab routing apply; unsupported guards fail closed. Explicit and inherited stale targets never fall back to focus.

Set/clear results include `tabId`, nullable `manualTitle`, effective `title`, layout revision and standard workspace commit fields. `api.describe.tabTitle` advertises the contract. Read `manualTitle` in `tabs.list`/`workspace.get`, both titles in `workspace.snapshot.tabs`, and effective `title` in `window.list/get`. Inspection retains its pagination/envelope limits. Renames update native tab/window labels without selecting/revealing inactive/minimized targets, recreating content or changing focus, group IDs, terminal sessions or layout revision. Names persist through workspace restoration and tab moves. No-ops emit no events/revisions but retain the existing best-effort snapshot save attempt, permitting recovery after an earlier failed save. Saved recipes carry optional `tabs[].manualTitle` separately from their editor-only `name`.

## Tab groups

`tab.reorder`, `tab.move` and `tab.detach` require `expectedWorkspaceRevision`. `focus` is `preserve` by default, or `target` to select the moved tab. Indices are zero-based **final destination indices**, not insertion positions before removal. Move requires a live destination `group`; an omitted move index appends. Reorder requires an index. Detaching an already-singleton tab is a no-op and does not allocate another group ID.

```sh
slate-term tabs reorder --tab t2 --index 0 --expected-workspace-revision TOKEN
slate-term tabs detach --tab t2 --focus-policy target --expected-workspace-revision TOKEN
slate-term tabs move --tab t2 --group w1 --index 1 --expected-workspace-revision TOKEN
```

Native group identity belongs to the group, not whichever tab happens to be first. Moving/reordering/detaching retains terminal sessions, plugin views/documents and native window identities; surviving destination groups retain their identity. Existing destination selection is preserved unless target focus is requested or the currently focused tab is being moved into it.

The native **Move Tab to New Window** action is `tab.detachCurrent`, defaults to target focus and remains configurable at Control-Command-N. It is a convenience alias available to all trusted clients; guarded `tab.detach` is preferred for explicit revision-based automation. It is unavailable when the captured tab already has its own group.

## Native windows

```sh
slate-term windows list --limit 32 --json
slate-term windows get --window-id window-UUID --json
slate-term windows focus --window-id window-UUID
slate-term windows focus --window-id window-UUID --activate
```

`window.list`, `window.get` and `command.run` ID `window.focus` are shared API operations for every trusted client. A native `windowId` identifies an app-owned `NSWindow` lifetime, distinct from the tab, group and OS window number. A closed identity is rejected, never replaced by the current key window. Window operations do not inherit pane/tab targeting. Supported guards are app instance and workspace revision.

List accepts `limit` (1–64, default 32) and `cursor`, with `nextCursor`, `eventCursor`, `totalWindows` and workspace revision in its envelope. Pages follow model tab order; a changed workspace revision or different query requires restarting enumeration. The envelope is capped at 256 KiB. Window get/focus require `windowId`; only focus accepts the optional Boolean `activate` (default false). Focus selects/orders the owned window and restores it if minimized; activating the application is explicit.

Results include group/tab identity, selected/key/visible/minimized/fullscreen state and sampled frame/screen metadata. Frames use **screen-global bottom-left points**; they are not pane content rectangles and are not transactional geometry. OS focus/animation state may settle after the request. Frame writes and minimize/restore/fullscreen setters now use the [first-pass window controls](api-parity-first-pass.md#native-windows).

## Registered page adapters

```js
const self = await workspace.self();
await workspace.panes.split({direction: 'left', type: 'browser', focus: 'preserve',
  expectedLayoutRevision: self.target.layoutRevision});
// Obtain fresh revisions before each subsequent operation.
await workspace.panes.move('p1', 'down', {pane: 'p2', expectedLayoutRevision, expectedWorkspaceRevision});
await workspace.layout.resize(['first'], 0.6, {expectedLayoutRevision});
await workspace.panes.setTitle('Build output');
await workspace.panes.clearTitle();
await workspace.panes.hideHeader();
await workspace.panes.showHeader({pane: 'p2'});
await workspace.panes.toggleHeader();
await workspace.tabs.reorder(0, {expectedWorkspaceRevision});
await workspace.tabs.move('w1', {index: 1, expectedWorkspaceRevision});
await workspace.tabs.detach({expectedWorkspaceRevision});
```

Unspecified targets bind to the calling view's live pane/tab. Explicit targets are validated, not silently replaced with current focus. `workspace.layout.get(params)` preserves the raw layout read. These wrappers use `command.run`; they do not introduce a second implementation. Discovery and invocation also include window methods and `tab.detachCurrent`; caller context supplies defaults, not a separate permission tier. Ordinary pages/subframes have no bridge.
