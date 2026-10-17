# Plugin persistence implementation review and verification

Worktree: `~/.worktrees/local/slate-term-a42fd7a1/plugin-persistence`  
Branch: `feature/plugin-persistence`, based on `d6240e5`.  
Implementation is uncommitted; no merge/push/deploy or legacy-data migration. Original-checkout changes were not edited. See [contract](plugin-persistence.md), [plan](plugin-persistence-plan.md) and [independent plan review](plugin-persistence-plan-review.md).

## Independent source review

A read-only reviewer inspected the tracked diff and relevant new source/tests/docs against the base, including model/store ownership, guards, event publication, lifecycle/configuration, native operations and authoring guidance.

One actionable finding: the nonvisual notes example could discard its only reset snapshot when a stale save invalidated an in-flight read and then conflicted. Corrected by scheduling a trailing read for superseded results and resnapshotting after failed writes **without retrying mutations**. Added a deferred-read/reset/stale-save regression and explicit data-write attempt counting. Fresh bounded follow-up found no actionable findings. These were source reviews, not reviewer-executed tests.

A subsequent actual VM movement run crashed in `PluginInstance.start`, with `NSGenericException: Task created in a session that has been invalidated`. Source inspection identified external session invalidation during the suspension inside `URLSession.data(for:)`. Each readiness poller now exclusively owns and invalidates its session in `defer`, after awaits settle; close/restart/exit cancel the poller instead. The movement fixture repeats six immediate-exit backend moves/closes, also checking panel identity/state retention. A fresh focused independent review found no actionable findings in this correction. It did not execute tests or certify every readiness interleaving.

**The readiness correction has not yet run in the VM.** Its attempted verification was blocked by a different active test owner, not a test pass. Stalled-HEAD cancellation and every backoff/restart interleaving remain additional coverage limits.

## Executed host and VM evidence

All paths below are relative to the worktree. Receipts and artifacts are ignored local verification output, not shipped source.

- Initial host checkpoint: **323 package tests** (199 core, 84 settings, 22 IPC, 18 CLI) and app/CLI/helper build passed.
- `artifacts/vm/20261016T153351Z-f72cbde3/receipt.json`: host model (323 tests), VM runner (35 tests), app build and whitespace passed. **plugin-persistence passed** in the VM, including shared data without runtime activation, independent panels, CAS/reset barriers, atomic failure handling, failed workspace-save recovery, native confirmations, reload/restart/configuration, fresh templates, unregister retention and restoration disabled/suspended. The authoring-example race regression passed too.
- `artifacts/vm/20261016T154945Z-64fa36f6/receipt.json`: host mutation checks passed. Eleven VM gates passed: **plugin-lifecycle, storage-causation, api-settings, workspace-persistence, window-recovery, agent-skills, command-picker, settings-window, background-services, event-efficiency, event-hub**. Six failed: plugin-persistence/plugins app-readiness timeouts; plugin-services backend-readiness timeout; saved-layouts startup execution; cross-window movement menu capture; API-parity shell readiness after restart.
- Diagnostic evidence: timed-out app processes were alive, not ready; API-parity shell reports included `Resource temporarily unavailable`. A read-only guest check observed load averages `6.47 14.15 12.92` and substantial memory compression. These support investigation of resource pressure but **do not establish the cause** or excuse the failures.
- One bounded unchanged-source diagnostic rerun, `artifacts/vm/20261016T161341Z-cfc0cba6/receipt.json`: **plugin-persistence, plugins, plugin-services and saved-layouts passed**. Cross-window movement progressed past its earlier menu failure but crashed in the readiness-session race described above. API-parity again failed at restart readiness; its gate reported two leaked owned descendants, which the runner cleaned up. No successful API-parity result is claimed.
- `artifacts/vm/20261016T162052Z-32f97ce9/receipt.json`: the post-fix plugin-persistence/plugin-services/cross-window movement run **did not execute**. The VM lock belonged to another active verification run (`20261016T161938Z-7712f42f`). That lock/process was not interrupted or removed.

Thus 15 selected VM gates have passing results across prior implementation checkpoints, **not** one uninterrupted green run, and **not** native verification of the final readiness correction. Sources and binaries are bound by each individual receipt. No `--all` run or full-suite certificate is claimed. Final host-only revalidation passed on the readiness correction: **323 package tests**, app/CLI/helper build and whitespace, receipt `artifacts/vm/20261016T162327Z-35f4db04/receipt.json`. Only final documentation status updates follow that receipt; no implementation changes followed it.

## Independent rendered review

The user-level visual critic inspected five actual VM PNGs in
`artifacts/vm/20261016T153351Z-f72cbde3/gates/plugin-persistence/`:

- `plugin-persistence-reset.png`
- `plugin-persistence-delete-data.png`
- `plugin-persistence-menu.png`
- `plugin-persistence-picker.png`
- `plugin-persistence-settings.png`

No visual issues were found. Confirmation copy distinguishes panel state from shared data, retained preferences/configuration and external files. The Workspace menu and expanded Settings action menu were not separately captured. Static captures cannot establish keyboard defaults, functionality or accessibility; native source adds Cancel first, and the fixture tested cancel/confirm/stale-target outcomes. No host GUI testing was used. The later readiness correction makes no UI changes.

## Remaining verification work

After the other VM owner finishes, run the current-source readiness/movement checks through `verify-vm.py` (plugin-persistence, plugin-services, cross-window-pane-movement). Do not break the lock or substitute host GUI tests. Investigate API-parity's restart/shell-readiness failures separately; do not label them fixed by the HTTP readiness correction. Broader full-suite, exhaustive size/envelope combinations and manual keyboard/accessibility testing are not certified.
