# Stable layout apps implementation

Status: implemented in the isolated `feature/stable-layout-apps` worktree. Qualification results and limitations are recorded separately in `artifacts/layout-apps-verification.md`; implementation alone is not a release pass.

Outcome: each saved layout can create an independent native app with a stable signed shell and a private signed runtime. Runtime refresh preserves the shell signature and occurs before loading runtime code, under maintenance and state ownership. Running apps keep their existing runtime.

Milestones:
1. Extract and package the real runtime with private helpers, frameworks, and resources; build Debug and Release.
2. Implement app creation, isolated startup/restoration, shared config with local overrides, private plugin copies/data, management and refresh through native and trusted API paths.
3. Verify release builds end to end in the VM: parent and two apps, real terminals/browser/plugins, independent lifecycle, runtime update and signature/permission continuity, refusal/recovery controls, and regression gates.

Non-goals: publishing, production installation, modifying existing user apps, or sharing a mutable parent runtime. No commit/push requested.

The previous whole-app replacement handoff is superseded: the stable bootstrap has no loaded runtime when it refreshes, so it can atomically exchange only the private framework, validate it, then load it in the same process. A state lease remains held across this boundary.

## Verification boundaries

The VM runner accepts signed Release bundles with original build receipts and a separate local-signing hash chain. The `layout-apps` gate checks lifecycle and trusted-client parity, `layout-app-upgrades` uses separate builds plus a signed incompatible-ABI fixture, and `layout-apps-ui` captures native UI evidence for independent review. Upgrade recovery fixtures model states immediately before and after the atomic swap; they do not claim power-loss durability.

The shipped Sparkle 2.10.0 integration is now included in the private runtime for the standard parent. Generated apps use local parent checks and never start Sparkle or fetch an update feed. Their update window and shared API offer a guarded restart after a compatible signed runtime is available. Private Developer ID signing and notarization use the existing release credential references; their results remain separate from native launch and permission qualification.

Creation retains `layouts.launcher` as the public API/CLI name but changes its behavior to create an independent app. `layoutApps.list`, guarded `layoutApps.refresh`, and `config.resetOverrides` share native/CLI/registered-plugin/service dispatch. Management availability is explicit in discovery. These operations require arguments and are not new parameterless Cmd-K actions; native creation continues through the existing discoverable command. Existing URL shortcut apps remain supported.

## Follow-up completion scope

User requested closing the original-plan gaps on 2026-10-20. Work remains in this worktree.

1. Integrate the shipped signed Sparkle updater and implement generated-app local update checks, shared API/window/actions, guarded restart, and activation-driven status.
2. Validate and stage creation dependencies before publication; list unavailable plugins; complete event-driven synchronization and application-name checks. Keep the first release scoped to the current bootstrap; defer shell replacement and development-installation migration.
3. Build behavior-changing signed Release fixtures and complete lifecycle, native launch, permission, updater, visual, and full regression checks. Qualify Developer ID/notarization when existing release credentials are available; record concrete external blockers rather than substituting local signatures.

Observable checks: original updater contracts work through native/CLI/page/service clients; generated apps make no update-network request; current/ready/unavailable states and restart retain state; creation refuses invalid required dependencies before publication; partial publication reports its actual outcome; installed app/runtime identity and provenance are read back.

Non-goals remain public release, push, production installation, and changing unrelated user apps/data. New tests supersede earlier receipts only after their source/build provenance matches.

## Follow-up implementation checks

Creation stages and validates plugin inventory and selected private data before publishing the app. Its native dialog lists unavailable plugins. The result reports synchronized plugins, unavailable plugins, copied data and LaunchServices registration separately.

Plugin synchronization observes the parent tree through a read-only recursive filesystem stream. Live synchronization prepares archives on a bounded background worker, then rechecks parent records, catalog revision and open panes before publication. Closing a plugin’s last pane applies deferred replacement/removal. Cancellation retains preparation ownership through cleanup; abrupt process exit relies on the existing exclusive-startup staging cleanup. Configuration observation follows missing or replaced parent directories without creating them. New layout-app tabs use the app name unless the user supplies a title; that fallback does not change the persisted snapshot format.

Runtime update status refreshes on file changes, application activation and explicit reads/checks. Restart freezes the verified parent revision, revalidates after normal quit confirmation, and requires the installed bootstrap to acknowledge readiness before quitting. Startup rechecks the selected source. The user explicitly deferred shell replacement and old-installation compatibility because the feature is unreleased. Required shell metadata is validated without legacy defaults; ordinary runtime-refresh recovery remains.

The focused watcher tests exposed and fixed an unbounded root traversal and the `/var` versus `/private/var` FSEvents path mismatch. Package/native/release tooling and VM qualification remain distinct evidence; the follow-up report supersedes the earlier receipts only after final-source checks finish.

Normal generated-app state paths exceed Darwin’s Unix socket address limit. The transport now uses an exclusive private temporary endpoint for long paths and publishes an atomic reference in the app’s own control directory. Terminals and plugin services receive the actual short path. IPC checks reproduce the original failure and verify connection, publication refusal and independent cleanup.

Local restart waits until the initiating RPC response is fully written, or the registered page acknowledges delivery after settling its Promise. A bounded five-second drain disconnects a nonreading socket caller before the helper expires. Real-socket regression tests cover large replies and blocked readers; the upgrade fixture also records the real page callback before its app restarts.

The restart helper waits through the interval where an exited process remains unreaped. It still requires confirmed process disappearance or a changed start identity before relaunching. The native upgrade regression holds a real parent unreaped, verifies that the helper waits, then checks relaunch and private-workspace preservation after reaping.

## Independent-review corrections

The independent Fable review identified main-thread stalls during signature inspection, creation and refresh. These operations now prepare and inspect files on background workers. The main actor retains mutation serialization, caller and revision checks, publication and event delivery. Cancellation waits for worker cleanup; a launched bootstrap retains its maintenance ownership until exit. Native controls and every trusted client await the same operations.

Periodic management reads use filesystem-invalidated inspection results and fresh running-state checks. Explicit API inspection and refresh always verify current files. Automatic catch-up skips running or launching apps and waits ten seconds after an observed termination so a restart helper can relaunch. Ordinary startup waits up to sixty seconds for maintenance ownership; explicit refresh still refuses contention immediately. The integration-only creation barrier tests concurrent reads, serialization, stale recipes and disconnected callers before publication; it is not a public capability.

A changed-runtime Debug probe reproduced rejection of a valid replacement because the shell recorded a hash-specific nested requirement. Newly built ad-hoc development runtimes now use an explicit identifier requirement. Developer ID Release signing, publisher validation and runtime library constraints are unchanged. Existing development shells remain outside the compatibility scope.

Discovery now marks network download unavailable in generated apps. Their ordinary saved-layout library remains private and writable, while fresh startup reads the selected source recipe from the parent. Ancestor configuration observation remains deliberate so replacement and missing-directory recovery continue to work. The review's suggested lifecycle deletion policy remains outside this task.
