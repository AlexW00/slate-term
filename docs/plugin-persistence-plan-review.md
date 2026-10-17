# Plugin persistence — independent plan review

Status: initial independent review completed; all four findings addressed; fresh follow-up reported **no actionable findings**. **No persistence implementation or runtime verification has occurred.** See the [implementation plan](plugin-persistence-plan.md).

## Scope and method

The user requested a concrete plan, an independent reviewer before implementation, and coverage of the related skill/documentation work. Breaking changes are allowed for this unreleased app. Resumable Spotlight workspace identity and unrelated features remain out of scope.

A fresh user-level `reviewer` subagent inspected the draft and relevant Core, Settings, Native, CLI and fixture code in read-only mode. It did not edit files, run tests/builds, or delegate. The coordinator verified the findings against source before revising the plan. Unrelated working-tree changes were excluded from review and preserved.

The initial verdict was: **feasible, but not ready to implement unchanged**. Four actionable findings follow. Section references are stable; line numbers changed during revision.

## Findings and resolutions

### R1 — P1: invalid panel-state event topic

- **Trigger/consequence:** the proposed `host.plugin.panelState.changed` contains an uppercase `S`. `Sources/SlateTermCore/EventJournal.swift` rejects uppercase characters in both publication topics and subscription filters. Event preflight would reject effective panel mutations before commit.
- **Evidence:** `EventTopic`/`TopicPattern` validation in `EventJournal.swift`; `Native/EventHub.swift` prepares by calling `appendBatch`.
- **Resolution:** §5 now uses `host.plugin.panel-state.changed`, explicitly distinguished from camelCase RPC names. No journal grammar changes.
- **Required regression:** prepare actual panel-state transition publications, append them to the journal and read them with the exact documented filter, including the scoped workspace invalidation.
- **Status:** addressed in the plan; implementation/test remains pending.

### R2 — P2: empty reset did not invalidate queued writes

- **Trigger/consequence:** a reader observes empty revision R and queues a write. Treating reset of empty state as a no-op retains R, allowing that stale write to recreate data immediately after the user's reset. Empty panel reset would also emit no notification for clearing a cooperating view's unsaved presentation.
- **Evidence:** draft §§3–5 contradicted themselves about no-op reset versus stale-write protection; current `PluginInstance.storageSet` and `WorkspaceRevisions.observe` skip equal values/models.
- **Resolution:** explicit reset is a generation barrier, even for empty state or an absent data file. It advances the relevant revision, reports `changed:true`, and emits a reset invalidation. Data reset saves an empty versioned envelope; panel reset changes the state revision, not content identity/configuration. Ordinary equal patches remain semantic no-ops.
- **Required regression:** read empty R → reset → submit queued old set, for missing data, persisted empty data and empty panel state. All old writes conflict; fresh reads/writes work.
- **Status:** addressed in the plan; implementation/test remains pending.

### R3 — P2: host reset command used contributed-plugin dispatch

- **Trigger/consequence:** `plugin.panelState.reset` enters the reserved `plugin.<id>.<command>` dispatcher and fails as an unknown contributed executable command. Changing only the prefix is insufficient because the current command catalog broadly treats `plugins.*` as workspace-independent.
- **Evidence:** `Native/WorkspaceHost.swift` contributed-command dispatch in API/native paths; `AutomationAPI.swift` command defaults; `CommandContract.swift` global/independent classification.
- **Resolution:** use `plugins.panelState.reset`, explicitly mark it pane-dependent, and route its native/command/API forms through the same guarded host operation. Preserve `plugin.*` for contributed executables.
- **Required regression:** native, CLI, self-page and explicitly pane-targeted service command parity, no contributed process launch, and rejection for a service without a pane. Enforce required panel/revision guards through `command.run`, not only direct RPC.
- **Status:** addressed in the plan; implementation/test remains pending.

### R4 — P2: no-op I/O prohibition contradicted workspace-save recovery

- **Trigger/consequence:** a panel-state commit succeeds in memory but its snapshot save fails. The blanket no-op/no-filesystem-write rule would prevent the plan's stated equal-write save recovery and leave the meaning of `workspacePersistence` ambiguous.
- **Evidence:** `WorkspaceHost.swift` saves unchanged workspace operations; `scripts/verify-workspace-persistence.py` explicitly tests equal setters repairing a save without advancing revisions/emitting events.
- **Resolution:** distinguish durable-data no-op patches (no write) from panel no-op patches (may attempt snapshot save with actual persistence result, no semantic mutation/events). Resets are explicit generation changes, not equal patches.
- **Required regression:** failed panel save → restore write access → equal guarded patch → snapshot saved with unchanged semantic revisions and no new events. Separately verify no disk I/O for equal durable-data patch.
- **Status:** addressed in the plan; implementation/test remains pending.

## Additional acceptance gaps made explicit

1. **Creation timing:** defaults/records/budgets must be resolved into the complete candidate before final `WorkspaceTransition` construction. `reconcile` rejects a different candidate and must not mutate a prepared transition's records. Test both plain and template creation, resource/publication failure and unchanged identity counters.
2. **Required starting fields:** the plan now explicitly recommends failing plain opening before commit when required layout fields lack defaults, with an error directing users to a configured saved layout. Optional fields support plugin-owned setup flows. This is a deliberate breaking behavior; no new configuration prompt/setter. Persisted opaque configuration is not revalidated against changed manifest field schemas on restart.
3. **Breaking snapshot fixtures:** update `verify-window-recovery.py`'s schema-1 fixture for normal current-format recovery, keeping separate legacy-rejection coverage. Verify changed defaults across restart and preservation/non-consumption of old scoped files.

## Verification and residual limits

- Performed: source/document/fixture inspection by the coordinator and independent reviewer; plan revisions.
- Not performed: implementation, package tests, builds, native/VM gates, visual review, runtime storage/launcher experiments, or power-loss certification.
- The detailed test matrix and file/API/skill deliverables are in the plan. Tests described here are **requirements**, not passing results.
- Existing legacy storage remains the running behavior until implementation. The skill must not advertise the proposed helpers before they ship; updating the skill, public docs and packaged resource verification is an implementation acceptance condition.
- Atomic file replacement is not power-loss durability. Panel persistence remains subject to existing workspace save status. The host cannot restore arbitrary DOM/process state, clear external plugin databases or guarantee an author correctly handles events/conflicts.

## Follow-up review

A second isolated read-only reviewer invocation examined the corrected plan/review record and relevant source. Verdict: **“No actionable findings”**, with no remaining implementation blocker or contract contradiction found. It verified R1–R4, complete candidate preparation, required-field rejection, opaque configuration restoration, schema-fixture coverage, and the synchronous event/file commit ordering.

The follow-up identified implementation checks, not unresolved design findings:

- Preserve required guards through generic `command.run` validation/stripping and CLI target resolution.
- The existing Cmd-K filter excludes commands with required arguments (`WorkspaceHost.swift`, `pickerEntries`). Make a context-supplied native reset action visible without weakening the external API guards. This explicit instruction and a picker visibility regression were added to §5.
- Reset rehydration must cancel pending pre-reset debounces rather than rebasing obsolete edits onto the new revision, while preserving subsequent intentional edits. This was made explicit in scenario 6.
- Execute the planned file/journal failure, cross-tab event, restart/configuration and equal-patch save recovery regressions during implementation.

No tests/builds/VM or visual checks were run by either review. Plan review is complete; implementation and its verification remain pending.
