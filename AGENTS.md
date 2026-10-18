# Slate Terminal engineering contracts

## Development status

- This app is in active development and has published releases. Use the release ledger and published artifacts to establish compatibility and upgrade baselines.
- Data migrations and backward-compatibility machinery for unreleased development formats are not required.

## Capability parity is part of completion

- Implement behavior once in the authoritative model/host operation. Trusted CLI, registered-plugin bridge and service clients use one public API catalog, validation and dispatch path; native controls and command helpers reuse its operations. Do not maintain separate capability allowlists.
- For every added or changed action/capability—not just new API work—ask: “Should an agent be able to do this too?” Default to yes for meaningful application behavior, including commands, settings and pane/plugin operations. Expose it through the shared public API and applicable CLI, registered-plugin bridge and service clients in the same change; update existing adapters when behavior changes. Do not leave useful behavior UI-only without a concrete reason.
- Independently consider native controls, configurable shortcuts and the Cmd-K command picker. Add useful one-click actions to Cmd-K with appropriate contextual availability. Reads and operations requiring arguments still belong in the API/clients but need not be parameterless picker actions; purely presentational gestures and internal implementation details need not become public capabilities.
- Make routine exposure decisions automatically using these defaults and existing project patterns. Record the decision and any intentional exclusions briefly in the change summary or relevant documentation. Ask the user only when genuine uncertainty materially affects behavior, scope, safety or security; do not ask for routine API/client parity. Preserve the resource/security boundaries below.
- Include discovery metadata, typed inputs/results/errors, documentation and parity tests for added or changed public capabilities in the same change. Check that native and agent-facing paths reuse the authoritative operation rather than implementing divergent behavior.
- Registered plugins and native services are trusted controllers, not permission tiers. Preserve registered-origin/main-frame/document bridge binding: ordinary web pages/subframes never receive a bridge. Reserve `plugin.<id>.<command>` for contributed commands; use `plugins.*` for host management. Keep host-bound ownership, caller liveness and target guards regardless of client.
- Public discovery and capabilities must agree across trusted clients. Differences are transport, caller context/defaults, cancellation and resource availability—not hidden privilege exclusions. Generate or contract-check client aliases against the shared catalog; keep shell/debug internals explicitly non-public for every client.

## Identity and consistency

- Environment identifies a launching/captured context, not live topology. Resolve current pane membership from the host; distinguish app epoch, pane slot, terminal session, logical plugin instance, web view/document and command invocation.
- Freeze targets before asynchronous work/confirmation, then revalidate. Never recover stale or invalid explicit/inherited identity by targeting the currently focused pane. Session guards must not leak onto sibling targets. Unsupported safety guards must fail closed, not be silently ignored.
- Revisions cover native gestures and legacy APIs as well as new commands. Validate complete model changes before committing; no-op mutations do not increment revisions. Do not describe filesystem/native/process side effects as a rollbackable model transaction.
- Publish bounded post-commit semantic lifecycle events with native attribution and revisions. Preserve replay-expiry/resnapshot behavior. Hooks are notifications, not vetoes; avoid implicit automatic process activation and unbounded feedback loops.

## Resource and security boundaries

- Reuse the shared WebKit automation implementation, but preserve separate browser/plugin navigation, data-store and bridge privileges. Keep automation identities separate from bridge credentials. Never expose credentials or entire environments in inspection/events.
- Commands, panel HTTP services and background services have distinct lifetimes. Bound concurrency, waits, logs, restarts and process ownership; cleanup on cancellation, replacement, unregister and shutdown.
- Preserve existing pane zoom/maximize/restore behavior and ordinary visibility safeguards. The separate hidden-pane feature is canceled; do not add detached hidden membership or hide/show APIs. Never silently evict a live pane session.
- Settings edits preserve unrelated supported TOML/comments and conflict with stale sources. All writers must understand grammar another writer emits. JSON null is not a TOML value; deletion must be explicit.

## Tests and verification

- Start with high-value failing tests where practical: model invariants, invalid/stale routing, atomic failure, destructive consent, bridge denials, lifetime races and compatibility. Include successful native/CLI/plugin parity, not only parser/unit coverage.
- Integration-only `debug.*` is not a production capability. Test through production APIs wherever possible; use isolated fixture roots, owned processes/windows and private clipboards.
- Run desktop/native UI integration tests in VMPal, not on the host Mac, unless the user explicitly authorizes host GUI testing. Discover/select gates with `python3 scripts/verify-vm.py --list` and `python3 scripts/verify-vm.py terminal text-checking browser`. Builds stay on the host; all native tests, test windows, input and screenshots stay in the VM. No guest compilation or host GUI fallback.
- `bash scripts/verify-all.sh` (equivalently `python3 scripts/verify-vm.py --all`) uses that same runner for the complete inventory, including three app iterations. Only the seven explicitly host-classified build/unit/static gates run locally. See [VM testing](docs/vm-testing.md) for prerequisites, artifacts and failure recovery.
- Register new gates in `scripts/verification_gates.py`; unregistered verification scripts fail validation. Run VM gates sequentially. A baseline pass does not verify changed source; inspect actual gate statuses and source/binary receipts. Only complete successful stable-source full runs publish `artifacts/verification.json`.
- Read relevant `docs/control.md`, `docs/automation.md`, `docs/events.md`, `docs/plugins.md` and configuration documentation before changing their contracts. Track broad work in `docs/api-extension-progress.md`; distinguish implemented, tested, deferred and blocked work honestly.
- Preserve unrelated changes. No push/deploy or destructive operations without explicit authorization.

## Plugins and plugin UI

- When building or changing a plugin, an example plugin, or any plugin pane UI in this repository, read `skills/slate-terminal/SKILL.md` first and follow its references: `references/building-plugins.md` for plugin structure and `references/ui/INDEX.md` for the UI design system.
- Plugin pages use the design system by default: `slate.css` and `slate-theme.js` from `references/ui/`, recipes from its components, and palette tokens instead of hard-coded colors. Explicit user design instructions take precedence.
- When a plugin needs a component the design system lacks, add it as a recipe in `references/ui/components/` and run `python3 design-system/build.py`, rather than styling it only inside the plugin.

## Changelog and releases

- For meaningful completed changes, read `.agents/skills/slate-changelog/SKILL.md` and update `CHANGELOG.md` in the same task-owned commit. If committing is not authorized, leave the entry with the implementation changes for review. Preserve unrelated entries from other worktrees; record actual outcomes and distinguish verified behavior from checks still needed.
- For release preparation, signed draft builds, or publication, read `.agents/skills/slate-release/SKILL.md` and `docs/releasing.md`. Curate `docs/releases/vX.Y.Z.md` from the ledger and actual release diff. Preparing notes does not authorize a tag, push, or publication; carry explicit authorization for those operations forward without asking again.
- Keep these maintenance skills repository-local. `skills/slate-terminal` remains the app-consumer and plugin skill; do not install the maintenance skills globally or add release instructions to that consumer skill.
