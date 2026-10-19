# Focus preservation audit

## Findings

The original missing-agent indicator was attributed to missing actor metadata. Focus stealing is a separate issue, reproduced in an owned VM fixture: with Settings key, even a no-op `layout.equalize` selected the workspace window. The red run is `artifacts/vm/20261019T133513Z-c37105d4/focus-preservation.log`.

Two independent paths caused this:

- Structural command defaults selected new/moved content: simple/atomic splits, pane movement, new tabs/windows and saved-layout opening.
- Shared native reconciliation unconditionally raised the model's key window, ordered every native group forward, and reset every tab's responder.

Pane/tab title and pane-header setters already use targeted commits that bypass reconciliation. They did not reproduce the bug. Terminal send/capture/run, direct plugin reload and browser/DOM automation do not explicitly activate native windows. DOM focus remains local to the document and is required for input actions.

## Changes

Shared command adapters now preserve focus by default, with explicit `new` or `target` policies exposed in CLI and discovery schemas. Native user actions supply those policies intentionally. Caller identity and actor metadata do not control focus policy, so CLI, registered pages and services share the same behavior.

Reconciliation only selects a window for explicit navigation, initial presentation, or a necessary change to the user's selected workspace. It restores responders only in rebuilt tabs or after an intentional selection change. It retains Settings key focus and derives terminal input focus from the actual native key window/responder. Unchanged native groups retain their window order; newly presented background groups appear behind existing windows.

Explicit pane/tab/window focus, tab navigation, pane zoom, Find, address editing, native creation/dragging and layout launchers remain intentional focus actions. Closing selected content chooses a survivor. A moved selected pane retains selection across windows; background pane movement preserves destination selection.

## Verification

- Added model regressions for creation defaults, explicit selection, background cross-window movement, selected-pane movement and invalid policy rejection. Confirmed red before implementation.
- Full Swift package suite passed after implementation: 107 settings, 31 IPC, 303 core, 29 CLI tests.
- `focus-preservation` is a registered VM gate covering actual native key changes, Settings, Find/address responders, structural defaults, native shortcuts and explicit navigation.
- The first changed-source VM batch, `20261019T134026Z-656c798d`, passed the native pane-header/hold-animation assertions but failed the focus-dependent gates. Several fixture setups relied on the old selection defaults and were corrected explicitly. An application-activation precondition also failed; the VM was subsequently confirmed locked.
- Independent review found the batch screenshots show the lock screen rather than Slate. They provide no rendered acceptance evidence. Actual application activation and Settings key-window preconditions now guard the focus regression.
- Final verification requires all relevant selected VM gates after unlocking: `focus-preservation`, `pane-titles-native`, `presence`, `layout-api`, `pane-movement`, `cross-window-pane-movement`, `saved-layouts`, and `terminal-history`, plus fresh rendered review. Package tests alone do not establish native focus behavior.
