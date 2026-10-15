# Guarded layout, tab and window operations

These commands use the same model/native reconciliation as menus and registered page controls. See [agent identity and guards](agent-api.md) for target resolution and recovery. `workspace.get` and `layout.get` keep their legacy shapes.

## Pane and layout commands

Use `command.run` with an explicit `id` and ordinary `pane`/`tab` targeting:

| ID | Arguments | Required precondition |
| --- | --- | --- |
| `pane.split` | `direction`: left/right/up/down; `target`: pane (default) or root; `type`: terminal (default), browser, or registered panel ID; `newPaneFraction`: default 0.5; `focus`: new (default) or preserve | `expectedLayoutRevision` |
| `pane.move` | `target`: destination pane ID; `direction`: left/right/up/down | `expectedLayoutRevision` |
| `layout.resize` | `path`: array of first/second branches; `firstChildFraction` | `expectedLayoutRevision` |
| `pane.title.set` | `title`: string | Optional ordinary identity/revision guards |
| `pane.title.clear` | None | Optional ordinary identity/revision guards |
| `pane.rename` | None; ordinary `pane`/`tab` target | A visible, non-minimized pane with its bar shown |
| `pane.header.show` / `.hide` / `.toggle` | None; ordinary `pane`/`tab` target | Optional ordinary identity/revision guards |

Fractions must be finite and strictly between zero and one. A split fraction always describes the **new pane**, regardless of direction; resize describes the **first child**, excluding the divider. `target: root` wraps the complete tab layout. Types are validated before native preparation: a browser/plugin split does not first create a terminal. Model allocation, topology and type are committed together. Failures do not imply rollback of arbitrary shell startup or other external side effects.

Paths address split nodes, not leaves, and have at most 64 branches. `[]` addresses the root. Obtain paths from `pane.inspect` or walk `layout.get`; always pair them with the observed layout revision. Successful mutations return resulting workspace/layout revisions and relevant IDs/paths.

Native admission requires affected panes to remain at least 80 points wide and high. Root splits and subtree resize validate all affected leaves. Unavailable native geometry fails closed. `pane.move` is within one unzoomed tab and preserves pane/content identity; its placement matches native drag/drop. `focus: preserve` does not steal focus from another tab and retains that tab's active-terminal history. Existing `split.left/right/up/down` remain simple 50/50 aliases and share native geometry constraints, without requiring a new revision argument. Native menus/picker suppress splits that cannot fit.

`pane.rename` is a presentation command: it opens the same anchored native popover used by clicking a header title, returns `{paneId: string}`, and does not set a title until the user confirms. It is discoverable through `command.list`, bindable without a default shortcut, and available via the picker, Workspace menu, CLI/socket (`command run pane.rename --pane p1`), registered pages (`workspace.command('pane.rename', {pane: 'p1'})`) and trusted services. Closed targets use the ordinary target error; hidden/minimized targets return `-32602` without revealing them. Native confirmation reuses `pane.title.set`; programmatic renaming should keep using `pane.title.set` / `.clear`, not a UI prompt. Cancel/outside dismissal never writes a title.

Manual titles are trimmed and limited to 4096 UTF-8 bytes; an empty title clears the override. Manual titles are separate from plugin-published automatic titles. Renaming does not close/rebuild live content or request busy-terminal consent. Inspection bounds displayed title strings and exposes `manualTitleTruncated`.

```sh
slate-term panes inspect --pane p1 --json
slate-term panes split --pane p1 --left --type browser --new-pane-fraction .3 --focus-policy preserve --expected-layout-revision TOKEN
slate-term panes split --pane p1 --up --root --expected-layout-revision TOKEN
slate-term panes move --pane p2 --destination p1 --down --expected-layout-revision TOKEN
slate-term layout resize --tab t1 --path first.second --first-child-fraction .6 --expected-layout-revision TOKEN
slate-term panes set-title --pane p1 --title 'Build output'
slate-term panes clear-title --pane p1
```

A plain `panes split --right` continues to call its legacy alias. Supplying type/root/fraction/focus options selects the guarded atomic operation.

## Pane bar visibility

```sh
slate-term panes hide-header --pane p1
slate-term panes show-header --pane p1
slate-term panes toggle-header --pane p1
```

These aliases call `command.run` IDs `pane.header.hide`, `.show` and `.toggle`. All trusted clients use the same targeting, validation and dispatch. An explicit or inherited stale target fails; it never redirects to focus. Supported optional guards are `expectedInstanceId`, `expectedAnchorSessionId`, `expectedWorkspaceRevision` and `expectedLayoutRevision`. Unsupported document/configuration guards fail closed. Replies include `paneId`, `tabId`, `headerVisible`, path/layout revision and standard commit fields. Show/hide are idempotent; toggle is not retry-safe. Repeated no-ops emit no event or revision. A real change emits `host.pane.header.changed` with resulting state and advances only the workspace revision, not the layout revision.

Read `headerVisible` through `pane.inspect`, `workspace.snapshot`, `panes.list` or `workspace.get`. This is the persisted **requested** bar state, independent of whether the pane is currently rendered (background tab, zoom or minimized window). Hiding removes the entire 28-point native header and gives its height to retained content; it does not hide the pane, change layout fractions/focus, recreate content, or change browser address/native tab bars. State follows the slot through moves, zoom/restore and type replacement. New panes default shown. Old snapshots and recipes default shown when the field is absent.

Show/Hide/Toggle Pane Bar remain available through the Workspace menu, command picker and configurable shortcuts (no default binding). Show the bar before using native rename/type/drag controls. Hiding cancels an open rename draft without saving; `pane.rename` refuses a hidden bar instead of revealing it. Programmatic title changes and registered plugin commands remain available. Saved-layout capture records current state, and the editor exposes **Show pane bar** per pane.

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

Results include group/tab identity, selected/key/visible/minimized/fullscreen state and sampled frame/screen metadata. Frames use **screen-global bottom-left points**; they are not pane content rectangles and are not transactional geometry. OS focus/animation state may settle after the request. Geometry writes/minimize/fullscreen commands are not introduced by this slice.

## Registered page adapters

```js
const self = await workspace.self();
await workspace.panes.split({direction: 'left', type: 'browser', focus: 'preserve',
  expectedLayoutRevision: self.target.layoutRevision});
// Obtain fresh revisions before each subsequent operation.
await workspace.panes.move('p1', 'down', {pane: 'p2', expectedLayoutRevision});
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
