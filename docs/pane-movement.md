# Pane movement

A six-dot grip sits before the pane type picker. Drag it to the outer quarter of another pane to insert the existing pane to its left, right, above or below. The center is not a drop target. The source's old split collapses; the new split starts at 50/50. During the drag, only the relevant half of the current target is shaded edge-to-edge with a flat 30% accent tint, matching Ghostty’s drop highlight: no inset, rounded outline or separate split line. A directional label remains (an arrow in narrow panes). This is an insertion cue, not a prediction of final window-space bounds: the layout stays still until release, and removing the source may expand the final split. Keeping the cue local avoids highlighting an entire existing pane or spanning unrelated panes when a sibling collapses.

Moves work across unzoomed tabs/windows in the same app instance and must leave both new children at least 80 points in each dimension. The same grip opens a destination menu grouped by window/tab for click/keyboard/accessibility use; **Move Pane…** is also in the Workspace menu, Cmd-K and configurable shortcuts. Invalid/self drops and cancellation do not change the workspace. A successful move focuses the destination pane and persists both layouts without allocating pane IDs. Moving a tab's only pane closes the empty source tab/window, not its live content.

Terminals retain their running shell/surface/session; browsers retain their document/history/store. Pane/global-scoped plugins retain their document and logical instance. **Tab-scoped plugins join the destination tab's instance/storage/backend and recreate their page; unsaved page state may reset.** The menu and cross-tab preview identify this exception. Source tab storage is not copied or merged. A plugin moving its own tab-scoped page may lose its reply after commit; inspect placement instead of retrying.

The shared `command.run` ID `pane.move` implements the same behavior for native drop/menu, CLI/socket, registered pages and services. Pass source `pane`, destination `target` and `direction`, with source `expectedLayoutRevision`; cross-tab movement additionally requires `expectedWorkspaceRevision`. Discover destinations with `window.list`, `workspace.snapshot` and `pane.inspect`. Programmatic movement does not need a visible pane bar or drag session. See [layout API](layout-api.md) for results and examples.

## Implementation

- `Workspace.move` validates a complete replacement layout before committing.
- `PaneDragHandle` uses AppKit's drag session with a movement threshold and a private pasteboard type. Only a live, recognized in-process handle can supply a drop.
- `WorkspaceHost` revalidates source/target identity and destination geometry at drop time, then detaches affected old roots before rebuilding either layout or retiring empty source windows.
- Plugin rebinding is prepared before model/journal commit; rejection releases only provisional resources. Retained pane-plugin ownership and inherited tab event polls follow the live destination, while explicitly captured targets remain guarded.
- `PaneMoveGeometry` predicts bottom-up window-space frames including dividers for minimum-size validation. `PaneDropView` paints insertion feedback only inside the current target; no preview children are added to `NSSplitView`. Feedback is immediate, without layout animation; an opaque backing respects Reduce Transparency, and the arrow and label convey direction without relying on color.

## Verification

```sh
bash scripts/verify-model.sh
bash scripts/verify-pane-movement-native.sh
bash scripts/build-app.sh
python3 scripts/verify-cross-window-pane-movement.py
python3 scripts/verify-pane-movement.py
python3 scripts/verify-app.py
```

The movement integration gate drives the real destination validation/preview/commit callbacks and menu, verifies live terminal/session and browser state retention, and captures light/dark views. It does **not** synthesize a successful native drag session. A PID-targeted event-injection attempt did not reach the handle's mouse-down handler in this environment; it was removed rather than treated as passing coverage.

Manual checks still required:

1. Drag a terminal by its grip over both terminal and browser content; try all four edges and verify the committed pane is beside the indicated target, on the indicated side. Try two siblings and nested splits: only half the current target should highlight, even when the committed layout expands after source removal.
2. Press Escape mid-drag, release outside the window, and release in a pane's center. Layout and typing focus should remain unchanged.
3. Drag between two actual windows, including a sole-pane source, over terminal/browser/plugin content. Verify retained pane/global plugin pages and the labeled page recreation/destination storage of tab-scoped plugins. Test different screen scales and fullscreen/Spaces where macOS allows dragging.
4. Check drag feedback with VoiceOver, Reduce Motion and Increase Contrast, including narrow panes.
