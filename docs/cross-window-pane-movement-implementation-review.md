# Cross-window pane movement — implementation and review record

- Worktree: `~/.worktrees/local/slate-term-a42fd7a1/cross-window-pane-movement`
- Branch: `feature/cross-window-pane-movement`
- Base: `f5638ec`

## Implementation

- Native dragging/menu and all trusted clients use shared guarded `pane.move`.
- Two-tab topology retains pane identity and repairs histories/focus; empty source tabs/groups retire without closing transferred content.
- Native reconciliation detaches affected old roots before replacement/retirement, retaining live terminal/browser/pane/global-plugin content and chrome/drag identity.
- Tab-scoped plugins prepare a destination instance/page before commit, release provisional membership on rejection, then recreate only moved content in destination scope after acceptance.
- Retained pane-plugin live tab ownership updates without restarting backends. Pending inherited-tab polls wake at a pre-transfer cursor; explicit filters stay fixed.
- Deferred contributed commands revalidate captured topology/guards before process launch, including after start-publication callbacks. Already-running commands survive movement.
- Discovery, typed command arguments/results/errors, CLI help, page/service parity, native chooser/picker/shortcuts, documentation and verification gates are included.

## Independent code review

The user-level `reviewer` inspected the implementation diff, surrounding callers and new tests read-only. It reported one actionable finding:

**P2 — stale app identity must be checked before pane availability.** With a stale `expectedInstanceId` and a missing pane, the early movement-specific existence check returned unavailable (`-32051`) instead of epoch conflict (`-32050`). Verified in `Native/WorkspaceAPI.swift`. Corrected by parsing movement IDs first, enforcing the app guard, then checking existence. The owned-app gate includes the combined stale-epoch/missing-pane regression.

The follow-up reviewer verified the epoch correction and reported one additional P2 finding: an active native drag could keep its captured pane/tab/leaf identity after its source native tab became inactive, then borrow selected-sibling geometry. Corrected by requiring the actual native source view to remain attached to its owning visible, selected, nonminimized window during preview/drop. Inactive-tab API/menu moves remain supported. Integration-only source-session admission plus a source-tab-switch regression exercise this guard; this does not claim hardware event injection. Native helper tests cover start rejection, duplicate admission and completion cleanup.

A final independent bounded follow-up inspected the actual source-visibility guard, session admission/end callbacks, debug fixture wiring, reconciliation callers and the new regression. It reported **no actionable findings** and confirmed inactive-source API/menu support remains intact. The reviewers did not execute tests. A successful active-session callback drop was also added to the six-client gate; hardware drag delivery remains outside automated coverage.

## Verification status

Targeted verification is in progress. The initial package/model, native pane-geometry and event-hub gates passed; the new event-poll barrier check passed. Window-free deferred-command tests passed, including stale prepare, lifecycle-callback-to-spawn rejection and already-running survival.

The first owned-app gate passed terminal transfers through socket/CLI/page/service/native callbacks/menu and browser retention, then exposed a JavaScript expression syntax error in the test fixture. Corrected before rerunning. A later verification attempt hit a transient missing Swift frontend during an external Xcode replacement; compiler availability was verified before restarting the affected checks.

Final unchanged-input targeted verification passed on **2026-10-16 at 00:33:38 UTC**:

- **283 package tests:** 182 core, 75 settings, 22 IPC, 4 CLI, including all directions, sole-pane/group closure, atomic depth failure, terminal histories, metadata, transfer facts and 100 cross-tab invariant/round-trip iterations.
- Event-hub lifecycle, including inherited-poll barrier, restrictive topics, explicit-filter isolation and failed-publication preservation.
- Native pane helper geometry and source-session admission/rejection/cleanup.
- Window-free service/deferred-command lifecycle, including post-callback pre-spawn rejection and already-running survival.
- Fresh native app/CLI build; only existing SDK/dependency/AppIntents warnings, including a simulator-version diagnostic unrelated to the macOS target.
- Six-client terminal transfer parity: socket, typed CLI, registered-page helper, trusted service, active native callbacks and native menu. Covers sole-pane source closure, hidden-header API movement, retained surface/session, inherited CLI routing, truthful event origins and guards.
- Representative private-browser/plugin transfers, all insertion edges, grouped-tab/frame retention, source-tab switching during an active callback session, inherited plugin polls, a frozen terminal wait, new/reused destination plugin instances/storage, publication rejection and accepted destination backend failure.
- Same-tab/native-menu regression, cross-tab round trip, retained content/focus/persistence and light/dark previews; diff whitespace checks.

Evidence: `artifacts/cross-window-{model,event-hub,native-geometry,service-commands,build,integration,same-tab-regression}.log`. `artifacts/cross-window-verification.json` records **316 unchanged verification-input hashes**, the seven gate log hashes and three app/CLI/launcher binary hashes. This is a targeted manifest, not `verify-all.sh` certification. The full browser/plugin-by-client Cartesian matrix was not run; parity uses the common authoritative operation plus representative kind/lifecycle checks.

## Independent visual review

The first user-level `visual-critic` review found a minor orphan window-group heading with no destination entries. The menu now omits groups with no eligible destination pane. After recapture, a fresh independent review inspected the root menu, destination-pane submenu and tab-plugin preview, with light/dark same-tab references, and reported **no visual issues**. Evidence: `artifacts/cross-window-move-menu.png`, `cross-window-destination-panes.png`, `cross-window-tab-plugin-preview.png`. Final insertion submenus, dark cross-window state and runtime interaction were outside still-image coverage.

## Remaining manual checks

Real AppKit hardware drag delivery (particularly a sole-pane source window closing during the drag session), cross-display scale/secure-input details, fullscreen/Spaces and full VoiceOver/reduced-motion/transparency/contrast auditing remain manual. Debug callbacks/menu and API tests do not certify hardware drag delivery. No production data, unrelated working-tree state, user's clipboard, push or deployment is involved.
