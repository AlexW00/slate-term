# Native UI / CLI capability audit

Audit baseline: checkpoint `1f80bde`. This is an inventory and a prioritized proposal, **not a new layout API**. Public means available in an ordinary app launch; `debug.*` test controls do not count.

This matrix describes that historical checkpoint. Current incremental delivery is documented in [layout APIs](layout-api.md) and [implementation progress](api-extension-progress.md); entries marked absent below are not a current capability advertisement.

## Parity matrix

| Operation | Native UI | Public CLI / socket | Gap / constraint |
|---|---|---|---|
| Read topology, focused pane/tab, tab groups | Visible workspace | `workspace.get`, `tabs.list`, `panes.list`, `layout.get`, `context.get` | Group IDs/order exist in `workspace.get`; no dedicated window geometry API. |
| Create window | New Window | `command run window.new` | No initial frame, display, placement or size options. Native windows start at a fixed 1000×650 content size. |
| Create, close, focus tab | Native tabs and menu | `tabs new/close/focus`, `tab.next/previous/select1…9` | Close safeguards require `--force` for possibly running processes. |
| Reorder tabs | Native tab dragging | None | Native ordering is synchronized into the model, but no public reorder command. |
| Detach / merge / move tabs between windows | AppKit tab dragging; Move Tab to New Window | None | `Workspace.detach`, `moveTab`, `adoptTabGroups` exist internally; `debug.detach/reorder` are test-only. |
| Move/resize/minimize/full-screen window | Standard macOS window controls | None | Frames and screen geometry are not part of the persisted workspace model. Tab groups are not a general window-management abstraction. |
| Split left/right/up/down | Menu and shortcuts | `panes split --left/--right/--up/--down`, `split.*` | Splits only the target **leaf**, always 50/50. No initial fraction or direct pane-type option in the public split command. |
| Move an existing pane | Pane grip menu / edge drag | None | `Workspace.move` preserves the pane and its contents. Native move is same-tab, unzoomed, and geometry-constrained; new split is 50/50. |
| Resize a divider | Drag divider | None | `Workspace.resize(tab:path:fraction:)` exists internally. `debug.divider` is not public. |
| Equalize / zoom | Menu and shortcuts | `layout.equalize`, `pane.zoom` | Supported. Equalization is not arbitrary sizing. |
| Change pane type | Header type dropdown, with confirmation | `panes type --type …` / `pane.type` | Replaces content, not a move; potentially running terminals require force. Panel plugins only. |
| Rename pane | Editable native header | No public user-title setter | Page plugins can supply their own automatic title via `workspace.setTitle`; manual user names take priority. The model has `setManualTitle`. |
| Close/focus pane | Header/menu/directional navigation | `panes close/focus`, `focus.*` | Supported; terminal/session identity and destructive-close rules still apply. |
| Create a full-height left panel at 25% | No dedicated workspace-sidebar operation | None | A leaf split is not a split of the whole existing layout. See below. |

## The left-panel example

Today a plugin can create a left split, then change its type. It **cannot** request an initial 25% fraction, resize it publicly afterward, or guarantee that it spans the whole tab when the workspace already has multiple panes.

A generic root-split operation could wrap the existing layout tree with a new pane; this does **not** require baking “sidebar” into core. Distinguish these contracts:

- **Target:** a specific leaf versus the tab's root layout.
- **Fraction:** fraction of the new pane versus fraction of the first child; left/right and up/down must be consistent. Exclude the divider from available space.
- **Creation:** commit type and initial fraction atomically, so callers do not have to create a terminal, destroy it, then resize.
- **Concurrency:** a split-tree path becomes stale when topology changes. Mutation APIs need a layout revision/precondition, or stable split identity, rather than silently acting on a new node at the old path.
- **Focus/ownership:** a plugin should retain its pane ID and state per tab, not infer ownership from titles or restore a stale full-layout snapshot.

## Smallest useful API roadmap

These names are proposals, not implemented commands.

1. **Creation with initial dimensions:** extend split creation with a validated fraction, explicit pane type and target kind (`pane` or tab root). Validate all resources before mutation; return the created pane and split identity/revision. Reuse the same transaction path as native splitting.
2. **Movement and resizing parity:** expose existing pane-move and divider-resize primitives through host commands and typed CLI wrappers. Define geometry/minimum-size and zoom behavior consistently with native UI. Reject stale targets atomically; preserve live terminal/web view identity on moves.
3. **Tab-group parity:** public reorder, detach and move-to-group operations using existing group/tab IDs. Provide index validation and well-defined focus behavior; avoid APIs keyed by window titles.
4. **Manual title parity:** a small user-title setter/clearer, distinct from a plugin's automatic document title.
5. **Only then consider:** OS-window frame/display controls, under a separately approved geometry/persistence contract.

The separate hidden-pane proposal has been canceled by the user. Existing `pane.zoom` already provides pane maximize/restore without introducing another membership/lifetime system.

A minimal validation plan for each addition: model invariants and rollback tests; CLI schema/routing/error tests; real native geometry and content-identity checks; focus/zoom/close-safety regressions; and concurrency/stale-target checks. Do not expose existing `debug.*` methods as a shortcut to a supported API.

## Evidence and confidence

Inspected `Sources/SlateTermCore/{CommandRegistry,Workspace,Layout}.swift`, CLI `Tabs`, `Panes`, and `LayoutCommand`, and `Native/WorkspaceHost.swift` command dispatch, `movePane`, `controller(for:)`, and native tab-group synchronization. `docs/pane-movement.md` describes the native movement constraints.

Existing evidence includes `WorkspaceTests`, `PaneMovementTests`, `WorkspaceInvariantTests`, and `verify-app.py`, `verify-settings.py`, `verify-pane-movement.py`. This audit traces production code and existing tests; it does not claim a new manual exercise of every macOS window gesture. Native drag-session and multi-display behavior remain manual-validation concerns.
