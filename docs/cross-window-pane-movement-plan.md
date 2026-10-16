# Cross-window pane movement — implementation plan

Status: proposed; no feature implementation. Independently reviewed; verified finding incorporated (see review record below).

## Outcome and decisions

Move an existing pane into another Slate Terminal window and insert it beside a destination pane, either by native grip dragging **or through the shared public API**. Both paths retain live content subject to the tab-scoped plugin exception below. Extend the existing move operation, not a separate drag-only transfer implementation. API/CLI/registered-page/service support ships with native support, not as a follow-up.

- Scope: windows owned by the **same WorkspaceHost/app instance**. Each model tab has its own `WorkspaceWindow`; a `TabGroup` represents native grouped tabs, not a second pane owner. Therefore the model operation must support cross-tab movement, including tabs in the same native group.
- Drop on the outer quarter of a destination pane: left/right/above/below, new split 50/50. Preserve the center dead zone, nearest-normalized-edge corner rule, target-local half-pane highlight, 80-point minimum and reduced-motion/transparency behavior.
- Direct dragging targets displayed pane content. No drop on desktop, tab strip, tab overview, title bar or empty space; no new window creation, cross-process transfer, copy, spring-loaded tab switching or general layout redesign.
- Support moving the source tab's **only pane**. Remove the empty source tab and its group if empty; do not create a replacement terminal or destroy the transferred pane. A source tab with remaining panes stays open.
- Successful moves focus/select the moved pane in its destination tab/window. Repair source focus using remaining terminal recency, otherwise the first spatial leaf. Moving a terminal removes it from source history and makes it the destination's most recent terminal; moving nonterminal content preserves the remaining histories. Preserve unrelated panes, fractions, IDs, native window frames and groups.
- Reject source or destination zoom for cross-tab moves; never silently unzoom. Keep current same-tab command behavior and model-level zoom semantics unchanged.
- **User-selected plugin policy:** a tab-scoped plugin joins the destination tab's logical instance/storage/backend. Its moved page is recreated and unsaved DOM state may reset. No storage merge/copy. Pane/global-scoped plugins retain their view/document and logical instance. Explain this exception in the destination menu/drag feedback and docs; it is not a promise of lossless tab-scoped page transfer.
- Hidden pane headers remain hidden; programmatic movement still works. No hidden/detached pane membership feature.

## Current architecture and constraints

| Location | Current behavior / required change |
| --- | --- |
| `Sources/SlateTermCore/Workspace.swift`, `move` | Rejects different owning tabs. `close`/`closeTab` delete pane records and cannot be composed into a transfer. `restore` checks exact ownership, focus, zoom, histories and identity counters. |
| `Sources/SlateTermCore/WorkspaceMutationCommand.swift` | Shared `pane.move` adapter assumes one source tab; result `tabId` is currently that tab. Checks only source zoom. |
| `Native/PaneDragging.swift` | AppKit drag operation already permits `.withinApplication`; private pasteboard type plus recognized live `PaneDragHandle`, not serialized pane IDs, supplies authority. Keep this boundary. |
| `Native/WorkspaceHost.swift`, `proposedMove` / `movePane` / `makeMoveMenu` | Explicit same-tab gate; grip/menu also require more than one pane. Preview and native commit use model candidate plus `command.run`. |
| `Native/LayoutAPI.swift` | `validateMutationGeometry` projects the source tab, which is wrong for a destination split in another tab and fails if the source tab disappears. |
| `Native/WorkspaceHost.swift`, `reconcile` | Retains leaves/containers by PaneID, but closes removed windows before rebuilding remaining tab roots, and rebuilds tab-by-tab. Needs an explicit multi-root detach/attach phase for transfers. Plugin preparation currently recognizes only new panes/type replacements. |
| `Native/PluginInstance.swift`, `Native/PluginPane.swift` | Instances keyed by registration + pane/tab/global scope. `PluginPane.instance` and its WebKit store are fixed. `PluginInstance.tab` is immutable and pane-scoped instances capture launch tab, so blind reparenting leaves stale metadata. |
| `Sources/SlateTermCore/APIFoundation.swift`, `WorkspaceTransition.swift` | Layout revisions already track each changed/removed tab. Semantic `host.pane.moved` currently describes only destination-relative same-tab movement. |
| `Native/WorkspaceHost.swift`, `callFromPlugin`; `Native/EventControl.swift`, `EventHub.swift` | New calls use live owning tab, but admitted calls/polls freeze defaults. Pending default-tab polls must not remain on the old tab and scan past new destination events. |
| `Sources/SlateTermCLI/LayoutCLI.swift`, `APITarget.resolve` | Existing typed move alias and page helper already dispatch the shared command. CLI chooses a pane over inherited tab; environment is launch context, not live membership. |

Working-tree note: unrelated tab-overview work is present, including extraction of `WorkspaceWindow` into `Native/WorkspaceWindow.swift`. Preserve it; do not restore the embedded class or overwrite those changes.

## 1. Authoritative model transfer

Extend `Workspace.move(_:beside:direction:)` using a complete value candidate:

1. Resolve both pane owners before mutation; invalid/missing identities fail without changes. Self-move remains a no-op.
2. Same-tab branch retains current remove/collapse/insert behavior.
3. Cross-tab branch removes the source leaf only from the source layout, then inserts that **existing PaneID** beside the target in the destination layout. Do not use `close`, `closeTab`, `split`, type replacement or identity allocation to implement this.
4. If the source layout is empty, remove its Tab and its group membership, dropping an empty group. Keep the global Pane record and its title/header/type. Re-resolve tab indices by ID after removal, rather than using invalidated array offsets.
5. Repair source focus, zoom reference and terminal history; update destination history/focus/key tab as above. Other tabs and pane records remain equal.
6. Validate both replacement trees and cross-workspace invariants before assignment, including depth limits and exact membership. Failure leaves counters, focus, groups and pane metadata untouched. Use a shared pure invariant validator if needed; do not rely on persistence to discover invalid state.

Keep registration/scope and native geometry out of the core topology model. At shared command admission reject either zoomed tab for cross-tab movement. The existing same-tab model test that exits zoom remains valid; production commands continue to reject zoomed source tabs.

## 2. Shared command, guards, results and events

Keep `command.run {id:"pane.move", pane:SOURCE, target:DESTINATION, direction:...}` as the public capability for socket/CLI, registered pages and services. Native drag/drop and destination menus invoke this same authoritative host/model operation. API callers do not synthesize a drag, supply a drag handle/token, open the destination chooser or require a visible source grip.

- `pane` and optional `tab` always refer to the **source**; `target` is an explicit destination pane ID. Reject contradictory pane/tab pairs and stale inherited identity; never fall back to key focus.
- Retain required `expectedLayoutRevision` for the source. **Cross-tab moves additionally require `expectedWorkspaceRevision`**, covering destination membership/layout and removal of an empty source tab. This intentionally uses the existing coarse guard instead of inventing a second layout token. Same-tab callers need no additional guard.
- Update conditional admission, `CommandContract` parameter/discovery metadata, `api.describe` movement metadata, docs and parity tests together. Advertise cross-tab support, the conditional workspace guard and tab-plugin recreation. Do not silently accept unknown `expected*` guards.
- After native group/divider/layout settlement, validate caller, supplied revisions, both owners, zoom, registration, geometry and provisional resources; immediately before model/journal commit revalidate the prepared transition base and caller. No suspension or modal confirmation inside the commit path.
- Return `paneId`, **destination** `tabId`, resulting destination `layoutRevision`/path and normal commit fields. Also return `sourceTabId`, `sourceTabClosed` and nullable `sourceLayoutRevision`, plus `contentRecreated` for the tab-plugin exception. This fixes the current source-tab result assumption in `WorkspaceMutationCommand`/`mutationResponse`.
- Advance the workspace revision once; advance both surviving changed layouts, remove the source layout revision if its tab closes. Same-layout/no-op semantics emit no fabricated revision/event.
- Extend `host.pane.moved` with source/destination tab IDs, both pre/post layout revisions (null after source closure), destination pane/direction and whether content was recreated. For a cross-tab transfer publish one **broadcast** moved fact (`tab:nil`, `pane:SOURCE`, IDs in payload), so both tab observers can receive it; preserve same-tab routing/fields.
- Order transfer before source-tab closure, then surviving layout/focus/tab-group invalidations and broadcast workspace invalidation, all under one operation/origin and atomic journal preflight. Never emit pane closed/created or pane type changed for an identity-preserving transfer, even when a tab-plugin view is recreated. A source tab may legitimately emit `host.tab.closed`.
- Provisional preparation or journal rejection leaves the old workspace/native content intact. After commit, persistence or backend readiness failures do **not** roll back the accepted move; report normal persistence/readiness status and never retry automatically.

## 3. Geometry and live native reconciliation

### Geometry admission

Refactor the existing geometry validator to resolve the destination from `target` for `pane.move` and project its **candidate destination layout** in that window's content bounds, including divider thickness. For same-tab moves retain removal-aware projection. Validate the inserted source/target leaves against 80 points; source collapse only expands remaining space. Reject unavailable/pending/invalid geometry or an active divider gesture on either affected tab. Drain native layout observations first and settle active gestures through existing dispatch policy, not nested rendering from drag callbacks.

Native drag candidates require real, displayed, non-minimized source/destination windows and attached destination containers; reject obsolete roots and detached/zoomed targets. Parameterized APIs/menu may address an inactive native tab if its owning group has valid geometry, following existing geometry policy, then select it only on successful commit. Do not implicitly expose minimized/ordered-out windows to make geometry available.

### Two-root rendering sequence

Augment `reconcile` with the set of panes whose owning TabID changes and a prepared content-rebinding set; not merely type replacements.

1. Prepare fallible resources before commit. Retain strong references to transferred containers/leaves and the active drag source, including the only-pane case. No terminal creation/closure for a transfer.
2. Commit the model/revisions/semantic batch once, using existing reentrancy guards. Native effects follow without suspension; callbacks cannot initiate nested mutations.
3. Before closing **any** removed source window or replacing **either** affected root, detach retained containers from all affected old parents as a batch, then clear old roots. Preserve browser focus memory and cancel rename drafts using existing behavior. Clear/invalidate old native layout observations and divider callbacks so queued callbacks from retired roots cannot mutate the new trees.
4. Install any prepared tab-plugin replacement content (see below); rebuild both surviving tab roots from retained containers. Do not accidentally close the moved leaf in the retired-pane cleanup, even when the source tab is gone. Either model tab order must produce the same result.
5. Only after transfer detachment/attachment retire empty source windows and reconcile native groups. Suppress native close/focus/tab-group callbacks while reconciling; keep destination frame and group identity. No busy-process warning: no terminal is terminated.
6. Apply fractions/layout, focus destination and its moved content, synchronize terminal focus/secure-input state and per-display scale/occlusion, then persist once. Existing `TerminalView.viewDidMoveToWindow` already resynchronizes Ghostty geometry; verify it across display scale factors.

Retain terminal surface/session IDs, shell report credentials, startup tracking, runs/waits and process bindings; retain browser/private-browser web view, data store, DOM/history and automation identities. Reparenting alone is not document retirement. Existing screenshot/layout checks may reject an in-flight geometry-sensitive capture; do not write a capture of mismatched geometry or retarget another pane. Requests frozen to an explicit old pane/tab pair must fail validation rather than acquire the destination context implicitly.

## 4. Plugin ownership and admitted-work lifetime

### Pane and global scope: retain

- Retain logical instance, controller, WebKit store/document, storage and origin/main-frame bridge binding. Update pane-scoped instance **live owner tab metadata** after commit; distinguish it from immutable backend launch context. Global instance tab remains nil.
- `SLATE_TERM_TAB_ID` in a running terminal/backend cannot be rewritten. Normal pane-anchored CLI routing already ignores that inherited tab and resolves current membership; add regressions proving this. Explicit stale pane/tab pairs fail. Do not restart pane backends simply to change environment, or infer current topology from their launch variables.
- Audit `instance.tab` consumers: plugin state-event routing, storage tab checks and pruning must use live pane ownership for pane scope. Tab scope remains fixed to its tab and global state remains app-wide. New bridge calls continue to derive defaults from `workspace.resolvedTab(pane:)`.
- Already-admitted operations keep their frozen pane/session/document/explicit target. Live content-owned terminal work survives transfer; it does not switch to the destination's active terminal mid-wait. Admitted actions whose captured source pane/tab assumptions no longer hold must reject before their next unperformed side effect. Audit each adapter rather than assuming caller liveness proves topology validity.
- **Deferred contributed-command launch needs a new explicit barrier.** `preparePluginCommand` captures pane/tab, but its returned closure and `PluginCommands.execute` currently recheck registration/caller liveness, not that captured pair. Validate the captured pane still belongs to the captured tab and recheck applicable guards immediately before entering execution and at the actual process-spawn boundary (including after lifecycle callbacks). Pass a dedicated pre-launch target-validation closure if necessary; do not fold this into ongoing caller liveness, which would wrongly cancel an already-running independent command after movement. A stale prepared launch fails without redirecting to destination context. Already-running independent commands remain alive, and their later intentionally pane-anchored CLI calls follow normal live routing. Do not restart services on a move.

### Tab scope: prepare destination instance and fresh page

- Acquire the destination logical instance before commit (reuse it if present), then stage a new `PluginPane` configured with its data store/origin/bridge/theme. Treat same-type owner-tab changes as content rebindings, not pane type changes.
- Provisional instance acquisition changes membership bookkeeping: track precisely what was acquired. Rollback must release **only** provisional membership/views and prune only provisional empty unactivated instances, without releasing source membership or destroying a preexisting destination instance/backend. Do not activate a new backend or load a new page before commit.
- On commit retire the old page via normal document/automation/request/subscription cancellation, release its membership, replace its content inside the existing Pane slot/container, then activate the destination instance/view. Wire all callbacks exactly as normal plugin construction does. Audit `PaneContainer` for content replacement support; add a focused replacement operation rather than replacing unrelated chrome/state.
- Source tab-scoped instance survives while that tab survives, even if it now has no views; close it if its source tab was removed. Destination views share only the destination instance; do not migrate source storage or orphan a source process. Backend startup failure leaves an accepted moved pane with normal reload/recovery behavior.
- A plugin moving its own tab-scoped page can lose its RPC reply when the old caller document retires. Document that commit may have succeeded and require inspection, not automatic replay, like self-reload.

### Default event polls must follow retained panes

New calls obtain current owner defaults, but `EventHub.PendingPoll.filter` currently freezes a TabID and advances its cursor across nonmatching events. Merely updating `PluginInstance.tab` or waiting for timeout is insufficient.

Add internal ownership tracking for **inherited tab filters** (owning pane/view), distinguishing explicit `tab`/`pane`, `scope:global` and explicit recipients. At a successful cross-tab commit, complete affected pending inherited-tab polls with an empty batch at a safe **pre-transfer cursor**, before journal readers scan the committed transfer batch. The next SDK poll resolves the pane's destination and replays from that cursor; it must not skip destination events. Do not terminate the subscription as an error or rebind explicit queries. Integrate this non-failing wake-up with the event commit barrier, not provisional preparation; publication rejection must leave existing polls untouched. Preserve cursor-expiry/resnapshot behavior. Tab-plugin old-document subscriptions instead retire normally.

Test the race where a poll was already resumed before transfer: a previously scanned source batch may complete as historical delivery, but its cursor cannot have scanned post-transfer destination traffic; the subsequent request uses the new owner. Keep cancellation and poll-capacity limits unchanged.

## 5. Native drag, menu and command picker

- Permit grip initiation for a single-pane unzoomed source. Keep a host-owned drag context with source PaneID, source TabID, container/handle identity and session identity captured at threshold crossing. Validate live recognized handle + session on every preview/drop, not pasteboard text. A removed/replaced/reowned source invalidates that drag rather than transferring a different current occupant.
- Replace the same-tab `proposedMove` check with shared candidate/admission logic for both owners. Preview is pure, clears previous feedback across windows, and never reparents content. Recheck owners, live handles, revisions and final geometry on release. Resize/navigation/type replacement/tab-group changes during a drag cannot bypass admission.
- Native drop freezes the explicit source/target and uses freshly settled guarded `pane.move`; do not turn a stale failed operation into a fresh focused-pane mutation. Clear all previews on exit, center/dead-zone, failure, window closure, Escape and drag end; release retained drag references once the session ends, even if the source window closed on success.
- Destination menu groups tabs under window groups, with pane title + stable IDs to disambiguate duplicate titles. Include other windows/tabs, and allow only-pane sources. Disable unavailable/zoomed/too-small destinations with a useful reason; mark tab-plugin moves as recreating the page. Revalidate captured menu targets at invocation.
- Add a presentation command `pane.move.chooseDestination` (“Move Pane…”) that opens the same accessible anchored destination menu (or equivalent keyboard-navigable chooser) for a frozen source. Expose it in the shared catalog, Workspace menu, Cmd-K and configurable shortcuts without a default binding. Keep argument-requiring `pane.move` out of the parameterless picker. Presentation requires a visible pane bar; programmatic `pane.move` does not.
- Update grip accessibility help/tooltips from “in this tab” to available Slate windows. Preserve existing feedback appearance; no animation/new visual system needed.

## 6. API/CLI/page parity and documentation

### Public movement contract (required in the same implementation)

The following examples describe **planned support**, not currently available cross-tab behavior.

- Discover the app epoch/capability with `api.describe`, native windows with `window.list`, and their panes/layouts with `workspace.snapshot` / `pane.inspect` (follow pagination). `pane.inspect.windowId` and `tabId` associate a pane with a discovered window. Choose a destination pane in the intended window; pane IDs are unique within the guarded app instance, so movement does not need an ambiguous destination-window/focused-pane fallback or a separate `windowId` argument.
- Inputs: source `pane` (or validated existing caller default), optional source `tab`, explicit `target` pane, `direction: left|right|up|down`, required source `expectedLayoutRevision`, and additionally required `expectedWorkspaceRevision` for different tabs. Support existing `expectedInstanceId` and source-only `expectedAnchorSessionId`; never apply the source session guard to the destination. Unsupported guards fail closed. Freeze resolved targets before preparation; both owners are revalidated at commit.
- Typed result: `paneId:string`, destination `tabId:string`, destination `layoutRevision:string` and `path:array<first|second>`, `sourceTabId:string`, `sourceTabClosed:boolean`, `sourceLayoutRevision:string|null`, `contentRecreated:boolean`, plus `operationId:string`, `outcome:committed|unchanged`, `workspaceRevision:string` and the existing `workspacePersistence` enum. `sourceLayoutRevision` is null only when that source tab was removed. `contentRecreated` is true only for a committed cross-tab tab-scoped-plugin rebinding; false for retained content/no-ops. Success means accepted placement, not plugin document/backend readiness.
- Match native insertion, focus, only-pane source closure, plugin policy, minimum geometry and lifecycle events. An API call works without a visible header, but does not bypass zoom/geometry/resource safeguards (§3). No modal confirmation, automatic retry, alternate client allowlist or drag-only transfer branch.

| Failure | Shared public error contract |
| --- | --- |
| Missing/malformed destination/direction/required guard, contradictory source pane/tab, unknown fields or unsupported guards | `-32602` invalid parameters |
| Stale app/session/workspace/source-layout precondition or changed prepared base | `-32050` conflict; inspect before deciding on a new operation |
| A well-formed source/destination no longer exists, either tab is zoomed, geometry cannot be obtained, panes cannot fit, or preparation is unavailable | `-32051` unavailable; normalize move admission failures consistently across clients |
| Bound caller/document/service resource retired during preparation | Existing closed/canceled caller contract (`-32022` where an RPC reply remains deliverable); no focus fallback |

Admission/rate/causation failures keep their existing public codes. Failed precommit admission leaves both layouts/content unchanged. Disconnect, timeout or a self-moving tab-plugin's retired document can make the result unknown after commit; inspect placement rather than replaying. A returned `workspacePersistence:failed` still means the live move committed.

### Equivalent socket, CLI and registered-page usage

Assume discovered `p2` is in source tab `t1` and `p9` is in another window's tab. Tokens below must come from fresh inspection of the same app instance; do not invent them or fetch new guards automatically to retry a failed mutation.

After the normal `hello` handshake, a socket or trusted service sends this JSON-RPC request (substitute the uppercase token placeholders):

```json
{"jsonrpc":"2.0","id":2,"method":"command.run","params":{"id":"pane.move","pane":"p2","tab":"t1","target":"p9","direction":"right","expectedInstanceId":"APP_INSTANCE_ID","expectedLayoutRevision":"SOURCE_LAYOUT_REVISION","expectedWorkspaceRevision":"WORKSPACE_REVISION"}}
```

Typed CLI equivalent, using the selected app's socket and captured guard variables:

```sh
slate-term panes move --socket "$SLATE_TERM_SOCKET" \
  --pane p2 --tab t1 --destination p9 --right \
  --expected-instance-id "$APP_INSTANCE_ID" \
  --expected-layout-revision "$SOURCE_LAYOUT_REVISION" \
  --expected-workspace-revision "$WORKSPACE_REVISION"
```

Registered page equivalent (the trusted page may intentionally move another pane):

```js
// p2/p9 have already been selected from window/pane discovery.
const snapshot = await workspace.inspect({scope: 'global'});
const source = await workspace.panes.inspect({pane: 'p2'});
const result = await workspace.panes.move('p9', 'right', {
  pane: source.paneId,
  tab: source.tabId,
  expectedInstanceId: snapshot.appInstanceId,
  expectedLayoutRevision: source.layoutRevision,
  expectedWorkspaceRevision: snapshot.workspaceRevision
});
// result.tabId/path/layoutRevision describe placement in the destination.
```

An intervening change between those reads is a conflict, not permission to redirect/retry. Services and pages may instead use the same raw `command.run` payload through their existing shared dispatch adapters; ordinary browser pages and subframes still receive no bridge.

### Client adapters and documentation

- CLI: extend `panes move` help and conditional guard validation; existing `Target` already supports `--expected-workspace-revision`. Keep direction/destination validation and inherited session guards intact.
- Page: retain `workspace.panes.move(target,direction,params,options)` and generic `workspace.command`/`call`/generated adapters. The existing params object carries both guards; do not introduce a bridge-only operation. Services use the same shared catalog/command validation.
- Document result destination semantics, source closure, retained identities, scope-recreation exception, coarse guard conflicts, event routing and uncertain self-move replies in `docs/pane-movement.md`, `docs/layout-api.md`, `docs/plugins.md`, `docs/events.md` and the shipped agent skill references. Update command-picker docs for Move Pane….
- Track implementation/test/deferred status in `docs/api-extension-progress.md`; add applicable new verification gates to `scripts/verify-all.sh` and `docs/verification.md` rather than claiming planning as shipped support.

## 7. Implementation order and verification

1. **Model + contract tests first.** All directions, nested collapse, source/destination order in `workspace.tabs`, only-pane source, same/different native groups, nonterminal-only tabs, terminal recency/focus, hidden headers/manual titles, no new IDs, exact-once ownership and snapshot round trip. Invalid IDs/self/no-op/depth failures remain atomic; retain same-tab regressions. Extend `Tests/SlateTermCoreTests/PaneMovementTests.swift`, `WorkspaceMutationTests.swift`, `WorkspaceTransitionTests.swift` and invariant tests.
2. **Shared host admission/results/events.** Cross-tab workspace guard required; stale source/destination/layout/workspace and malformed/unsupported guards fail unchanged. Test destination geometry, active divider/native-layout settlement, both zooms, source closure revisions, one broadcast move fact, no false pane close/create/resize, truthful native/plugin/service origins and publication rejection. Same-tab guard/result compatibility remains tested.
3. **Native transfer and plugin rebinding.** Deterministic tests before GUI loops: both tab iteration orders; source-only window retained until detach; callback/reentrancy rejection; injected preparation/publication failures; source instance/member cleanup versus reused destination instances. Test pane/tab/global plugins, retained document sentinel vs tab-scope reset, storage isolation, process/instance IDs, old document/cause/ref invalidation and accepted backend failure.
4. **Lifecycle races.** Inherited CLI routing after terminal and pane-plugin movement; explicit old pane/tab fails; ongoing terminal run/wait and recipe startup retain session. Deterministically exercise contributed-command prepare → pane transfer → launch, including sole-pane source closure: reject stale pre-launch topology/guards with no process spawn, while a command launched before transfer remains running. Exercise the lifecycle-callback-to-spawn validation boundary too. Retained plugin pending calls/polls follow defined frozen/default semantics; explicit/global event filters stay fixed; no missed destination event when moving during a long poll, including restrictive topic filters and publication rejection. In-flight screenshot must fail safely if layout changes. Source/target closure, type change, move, zoom, resize, unregister and tab reordering during drag must be rejected or freshly validated without lost panes, leaked resources or focus fallback.
5. **Focused owned-app integration.** Extend `scripts/verify-pane-movement.py` and native helpers (update the old cross-tab-rejection assertion). Use production API for commit/parity tests; keep debug preview callbacks integration-only. Assert surface/session/WebKit identities, live terminal output, browser DOM/history/private store, frame stability, focus/secure-input, persistence and same-tab regressions. Run an explicit matrix against equivalent independently reset fixtures: native callbacks/menu, socket `command.run`, typed CLI, registered-page helper and trusted service. For each, cover successful cross-window insertion, sole-pane source closure, retained terminal/browser content and tab-plugin recreation; compare topology/focus, result fields where applicable, revisions and semantic event payloads (allow truthful origin/operation IDs to differ). Cover missing/stale guards, stale target, zoom/size rejection and preparation/publication rejection with identical no-partial-mutation guarantees. Verify hidden-header programmatic movement and that no API client needs a native drag session. Contract-check catalog discovery and adapter parameters, including the chooser's availability; parser-only tests do not establish parity.
6. **Real drag/manual and visual checks.** Existing integration explicitly does not prove a native AppKit drag session. Perform one focused actual cross-window drag sequence over terminal/browser/plugin content, all edges, sole source pane, cancel/outside/center, grouped tabs, differing screen scales and fullscreen/Space transitions where macOS permits dragging. Verify no premature source closure/focus theft, feedback cleanup, VoiceOver/keyboard menu and reduced-motion/transparency/contrast. Capture neutral rendered evidence and obtain visual review of changed menu/exception feedback; do not treat debug callback invocation as hardware drag coverage. Keep unsupported OS-space behavior explicit, not a claimed pass.

Suggested gates during implementation: `bash scripts/verify-model.sh`, `bash scripts/verify-pane-movement-native.sh`, `bash scripts/build-app.sh`, targeted updated model-mutation/semantic-event/CLI/plugin/service gates, then `python3 scripts/verify-pane-movement.py`. Register any new poll/transfer-specific gate. Run GUI gates sequentially with owned fixtures; ask before a long window-heavy suite. No suites have been run for this documentation-only plan.

## Review and remaining release checks

Independent review record: [cross-window-pane-movement-plan-review.md](cross-window-pane-movement-plan-review.md). The subsequent API-explicitness update adds the §6 request/result/error contract, concrete client examples and the §7 parity matrix; it preserves the reviewed architecture and has been coordinator-checked, not independently re-reviewed. The reviewer identified one P2 gap: missing pre-launch topology validation for deferred contributed commands. It was verified against `preparePluginCommand`, `runUserCommand`, `PluginCommands.execute` and `APITarget.resolve`, and incorporated into §4 and §7. No other actionable plan defects were reported; this is a review of the proposal, not implementation certification. Implementation is not complete until shared client parity, lifecycle/atomicity and real native drag checks above have actual results; this document does not certify AppKit behavior.
