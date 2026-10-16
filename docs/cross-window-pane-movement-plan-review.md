# Cross-window pane movement — independent plan review

Scope: independent read-only review by the user-level `reviewer` agent of `docs/cross-window-pane-movement-plan.md` against the current model, host, plugin, drag, event and client architecture. No implementation, builds, tests or GUI checks were performed. Unrelated working-tree changes were excluded and preserved.

## Finding: P2 — deferred contributed commands need pre-launch topology validation

**Trigger:** a native contributed command is prepared for pane `p1` in tab `t1`; the pane moves to `t2` before the deferred launch task executes.

**Evidence verified by coordinator:**

- `Native/WorkspaceHost.swift:432–457`: `preparePluginCommand` captures pane/tab, but its returned closure checks registration/socket/caller liveness, not captured membership.
- `Native/WorkspaceHost.swift:2724–2731`: `runUserCommand` invokes the prepared closure from a later `Task`.
- `Native/PluginCommands.swift:71–116`: execution rechecks caller liveness before spawning, without revalidating the captured pane/tab pair.
- `Sources/SlateTermCore/APIFoundation.swift:131–145`: `APITarget.resolve` deliberately prefers inherited pane identity over an inherited tab.

**Consequence:** a stale prepared command can launch with `p1/t1` environment, while ordinary pane-anchored CLI operations resolve into `t2`. The original plan incorrectly assumed an existing final validation barrier would reject this stale prepared launch.

**Disposition: accepted and incorporated.** Plan §4 now explicitly requires a dedicated pre-launch membership/applicable-guard check both before execution and at process spawn, after lifecycle callbacks. It is not ongoing caller-liveness validation: independent commands already running must not be canceled merely because their pane moves. Plan §7 adds deterministic prepare → transfer → launch coverage, including sole-pane source-tab closure and the pre-spawn callback boundary.

## Other review conclusions

The reviewer reported no additional actionable plan defects in model transfer, two-root reconciliation, provisional plugin membership handling, the default event-poll wake-up strategy or API parity provisions.

## Residual risks / unexecuted checks

- AppKit must be verified with a real drag, especially when the source's only pane moves and its window closes.
- Live terminal/browser/plugin retention and tab-scoped plugin page recreation require implementation-time identity/lifecycle checks.
- Event-poll completion must occur at the successful commit barrier without scanning past new destination events; explicit filters, already-resumed polls, restrictive topics, rejection and cursor expiry require tests.
- No code was changed or behavior certified by this planning review. The incorporated plan revision was checked by the coordinator; the reviewer assessed the preceding draft.
