# API parity TODOs

Follow-ups selected from the UI/API capability audit. These are pending tasks,
not implemented capabilities. This document records work to plan; it does not
change application behavior.

Terminal mouse/selection/scrollback/clipboard API additions were declined and are
not part of this backlog. Keep terminal clipboard consent and macOS notification
authorization boundaries unchanged.

## 1. Native window controls

- [ ] Expose native window frame changes, minimize/restore, and explicit fullscreen
  state through the shared public API and applicable CLI/page/service adapters.

**Why:** agents can inspect and focus windows today, but cannot arrange or enlarge
one before a layout operation, or control its presentation state.

### Acceptance

- Target a stable app-owned `windowId`, with app-instance validation; reject closed
  or stale targets without falling back to the active window.
- Define frame coordinates using the existing screen-global bottom-left point
  convention. Validate finite dimensions, native minimum sizes, display changes,
  and offscreen placement. Document behavior for tabs sharing a native group.
- Make application activation explicit rather than an incidental side effect.
- Report asynchronous fullscreen transitions honestly: distinguish request
  acceptance from settled state, and reject unsupported/conflicting transitions.
- Preserve terminal sessions, plugin documents, pane zoom, and split fractions.
  Do not describe native window effects as rollbackable model transactions.
- Cover stale targets, invalid geometry, minimize/restore, grouped tabs, and
  fullscreen completion/failure. Run native UI checks in VMPal per `AGENTS.md`.
- Update discovery, typed contracts, documentation, and client parity tests.
  Consider useful parameterless controls for native menus, shortcuts, and Cmd-K.

**Starting points:** [current window contract](layout-api.md#native-windows),
[`LayoutAPI.swift`](../Native/LayoutAPI.swift),
[`WorkspaceHost.swift`](../Native/WorkspaceHost.swift),
[`LayoutCLI.swift`](../Sources/SlateTermCLI/LayoutCLI.swift).

Native tab-overview control is lower priority than geometry and window state;
only add it if a concrete automation workflow needs it.

## 2. High-value web/plugin interaction additions

Extend the shared browser/registered-plugin `web.*` implementation rather than
adding a separate browser-only automation path.

### First additions

- [ ] Add targeted focus and bounded key/chord input for keyboard-driven plugin
  widgets, editors, form submission, and Escape/Tab/arrow-key interactions.
- [ ] Add explicit desired-state checkbox/radio operations with verified resulting
  state, rather than requiring callers to infer state and blindly toggle.
- [ ] Extend typed input editing to useful non-text controls, starting with number,
  date/time, and range inputs. Define supported types, validation, and readback;
  do not silently broaden `fill` to arbitrary elements or file inputs.

### Next additions, validated against real workflows

- [ ] Add targeted hover and bounded drag operations for menus, sliders, and
  reorderable plugin widgets. Define coordinates, hit testing, event semantics,
  and cancellation cleanup before exposing them.
- [ ] Evaluate open-shadow-root and frame targeting for actual plugin/browser
  content that needs it. Define frame/document identity and lifecycle invalidation
  before expanding beyond the current main-document contract.

### Acceptance for each addition

- Use existing pane/view/document identity guards, stale-reference rejection,
  caller-liveness checks, renderability rules, and operation bounds.
- Expose the same capability through API, CLI, registered-plugin bridge, and
  managed-service clients; include discovery and typed inputs/results/errors.
- Verify the chosen WebKit interaction mechanism. Document synthetic-event and
  user-gesture limitations; do not claim trusted hardware input unless proven.
- Test meaningful widget behavior, not just dispatched events: focus, key-driven
  state changes, controlled inputs, disabled/covered targets, navigation during
  input, and target replacement as applicable.
- Preserve browser/plugin origins, data-store separation, and bridge binding.
  Do not introduce arbitrary plugin evaluation or automatic permission approval.

File upload/native chooser control and canvas-coordinate automation are not
first-pass requirements; scope them separately if a real workflow justifies them.

**Starting points:** [automation contracts](automation.md),
[`BrowserAutomation.swift`](../Native/BrowserAutomation.swift),
[`WebAPI.swift`](../Native/WebAPI.swift),
[`WebPaneAutomation.swift`](../Native/WebPaneAutomation.swift),
[`WebCLI.swift`](../Sources/SlateTermCLI/WebCLI.swift).

## 3. Warning-suppression preference parity

- [ ] Add explicit Boolean setters for close-warning and pane-type-warning
  suppression, using the same authoritative preference writers as native
  confirmation checkboxes. Final public command names remain to be chosen.

### Acceptance

- Support both suppression and re-enabling through the shared API and applicable
  CLI/page/service adapters; retain existing reset commands as re-enable aliases.
- Reuse `setSuppressCloseWarning` / `setSuppressTypeWarning` and their existing
  stores. Do not invent a parallel TOML setting or duplicate persisted state.
- Validate Boolean inputs strictly, report current state through `config.get`,
  refresh native status, and surface persistence failures accurately.
- Keep preference changes separate from consent to an individual operation:
  setting suppression must not terminate processes, replace panes, waive API
  `force` requirements, or bypass terminal clipboard/OS permission prompts.
- Test native/API parity, setting both values, repeated/no-op writes, persistence
  across restart, invalid input, and write failure. Update discovery and docs.

**Starting points:** [`SettingsAPI.swift`](../Native/SettingsAPI.swift),
[`ApplicationSettings.swift`](../Native/ApplicationSettings.swift),
[`CommandRegistry.swift`](../Sources/SlateTermCore/CommandRegistry.swift),
[`CommandContract.swift`](../Sources/SlateTermCore/CommandContract.swift).
