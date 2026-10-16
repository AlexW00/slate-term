# First-pass API parity

This slice adds shared window presentation controls, bounded web input operations,
and native-warning preference setters. CLI, registered-plugin bridge and managed
services use the same host validation/dispatch. There are no client capability tiers.

## Native windows

Discover `windowId` and `visibleScreenFrame` with `windows list/get`. Commands are:

```sh
slate-term windows frame --window-id window-UUID --x 50 --y 50 --width 900 --height 650
slate-term windows minimize --window-id window-UUID
slate-term windows restore --window-id window-UUID
slate-term windows fullscreen --window-id window-UUID --enabled true
slate-term windows fullscreen --window-id window-UUID --enabled false
```

These map to `command.run` IDs `window.frame.set`, `window.minimize`,
`window.restore`, and `window.fullscreen.set`. Frame fields are `x/y/width/height`;
fullscreen requires Boolean `fullscreen`. All require explicit `windowId` and
accept `expectedInstanceId` and `expectedWorkspaceRevision` only. Unknown fields
and unsupported guards fail closed. No inherited pane, tab, or active-window fallback.

Only the selected member of a native tab group may be changed; otherwise use
`window.focus` explicitly first. A frame affects the shared native presentation,
not tab membership. Frames use screen-global bottom-left points, finite coordinates
bounded to ±1 million, positive dimensions, native size limits, and containment
inside one display's visible frame. Offscreen or display-spanning rectangles are
rejected, not silently clamped. No geometry persistence is added.

Restore minimized windows before frame/fullscreen changes; leave fullscreen before
frame/minimization changes. Attached sheets, live resize and pending fullscreen
transitions reject conflicting requests. None of these commands explicitly activates
the application or rebuilds pane content. Existing AppKit focus/Space behavior still
applies. Existing pane zoom and split-fraction observation remain authoritative.

Replies include sampled `window.get` fields plus `accepted`, `changed` (a native
change was requested), and `settled`. Fullscreen is asynchronous: poll `window.get`
for `fullscreenTransitionPending:false` and the requested `fullscreen` value.
`fullscreenTransition` is `idle`, `entering`, `exiting`, or `failed`; acceptance is
not completion or an automatic retry grant. Native callbacks publish bounded
`host.window.changed` invalidations with `windowId`, `presentationRevision` and
sampled `workspaceRevision`. These are native observations, not attribution of a
rollbackable workspace-model transaction; presentation revisions are not write guards.

Page helpers: `workspace.windows.list/get(params, options)` and
`setFrame/minimize/restore/setFullscreen(params, options)`; final options support
`{signal,cause}`. Explicit IDs make these argument-taking API operations, not
parameterless Cmd-K actions. Native window chrome remains the UI control.

## Shared web input

New methods are `web.focus`, `web.key`, `web.check`, and `web.setValue`. All require
exactly one `selector` or snapshot `ref`, plus a pane resolved by the normal web
adapter. Selectors require paired `expectedViewId`/`expectedDocumentId`; refs bind
both automatically. Existing visible/ready/renderable, disabled/inert/covered,
caller-liveness and stale-document rules apply. No implicit reveal or plugin eval.

```sh
slate-term web focus --pane p2 --ref REF
slate-term web key --pane p2 --ref REF --key arrowdown
slate-term web check --pane p2 --ref REF --checked true
slate-term web set-value --pane p2 --ref REF --value 2026-10-16
```

- **focus:** scrolls/checks the target, focuses it, and verifies it retained DOM
  focus. Returns `focused:true`; this does not activate the native app.
- **key:** one bounded ASCII character (use the `plus` alias for `+`) or named key with unique `ctrl/alt/shift/meta`
  modifiers, at most 128 bytes. Named keys: enter, tab, escape, space, plus, backspace,
  delete, home, end, arrowleft/right/up/down, pageup/down. Case-insensitive.
  Characters are logical keys, not physical keyboard-layout codes: supply the
  desired punctuation directly (e.g. `shift+!` or `ctrl+plus`).
  Dispatches **synthetic** keydown/keyup to the original element. Page keyboard
  handlers can implement widget behavior. Unprevented, unmodified Tab/Shift-Tab
  has bounded main-document focus traversal; Enter/Space activates native buttons
  and check/radio inputs (Space waits for uncancelled keyup); Enter uses a form's
  default submit button, or implicit submission when no button and at most one
  blocking field exist. Tab includes native summary controls and uses document
  position for negative-tabindex targets. Release events remain balanced if an
  emulated default fails. Other native
  editing defaults are not emulated: use `fill` or `setValue` to change text/values.
  Returns `dispatched`, `defaultPrevented`, `defaultAction` and `synthetic:true`, not
  a claim that arbitrary editor commands or trusted-user-gesture APIs succeeded.
- **check:** strict Boolean `checked`, native checkbox/radio inputs only. Repeated
  desired state is a no-op. Uses activation and verifies retained checked state;
  cancellation/reversion/indeterminate state fails. To clear a radio, select
  another member of its group; `checked:false` on a radio is rejected.
- **setValue:** bounded canonical string `value` (up to 4096 UTF-8 bytes), for
  number, date, time, datetime-local and range inputs only. Month/week controls
  and input types that WebKit exposes as fallback text fields are not supported.
  Validates
  sanitization and input constraints on a detached clone before changing the real
  input; readonly, noncanonical, out-of-range and step-invalid values fail. Emits
  input/change and verifies retained value. Readback can fail after page handlers
  run; this is not a rollback guarantee. Existing `fill` retains text-only behavior.

Snapshot input entries include `type` and bounded declared `min/max/step` attributes.
All new methods are generated under `workspace.web` and available to services.
Browser compatibility aliases are unchanged; use canonical `web.*` for these additions.
No hover/drag, frame/shadow traversal, uploads, canvas interaction, clipboard approval,
or arbitrary plugin evaluation is added.

## Warning preferences

```sh
slate-term warnings close --suppressed true
slate-term warnings type --suppressed false
```

Shared `command.run` IDs `warnings.close.set` and `warnings.type.set` require a
strict Boolean `suppressed`. Existing `.reset` commands remain aliases for false.
Only `expectedInstanceId` is supported; preference writes are workspace-independent.
Page helpers are `workspace.warnings.close(suppressed, options)` and `.type(...)`.

Writes reuse the existing private stores and native checkbox writers; repeated
unchanged values do not rewrite a healthy store. `config.get.closeWarning` and
`.typeWarning` report state. Failed persistence does not publish successful state.
These stores remain outside TOML/configuration revisions and settings events.

Suppressing warnings does **not** grant consent to an individual API operation:
busy-process destructive operations still require explicit `force`. Terminal
clipboard confirmation and macOS notification authorization are unchanged.

## Verification

Core validation/guard tests: `ParityActionTests.swift`; CLI coverage is included in
`AutomationAliasesTests.swift`. `scripts/verify-api-parity.py` is a VM-only production
API/CLI/page gate registered in the shared verification inventory. Run:

```sh
python3 scripts/verify-vm.py api-parity web api-settings layout-api
```

See `api-extension-progress.md` for actual execution/review evidence. A runnable
gate is not a claim that it passed; no full-suite certification is implied.
