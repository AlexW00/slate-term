# Slate Terminal engineering contracts

## Capability parity is part of completion

- Implement behavior once in the authoritative model/host operation. Trusted CLI, registered-plugin bridge and service clients use one public API catalog, validation and dispatch path; native controls and command helpers reuse its operations. Do not maintain separate capability allowlists.
- For every new capability, explicitly decide native, command-picker/shortcut, CLI/socket and plugin exposure. Add discovery metadata, typed inputs/results/errors, documentation and parity tests in the same change. Reads and parameter-dependent operations need not be one-click picker actions.
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
- Keep desktop integration tests sparse while the user is working on the Mac. Prefer unit/static checks and reuse owned fixtures for focused GUI verification; do not repeatedly launch/activate apps for broad regression loops. Check with the user before a long, window-heavy suite. Necessary behavioral verification must not be replaced by assumptions.
- Add applicable integration gates to `scripts/verify-all.sh` and its verification manifest. Run GUI gates sequentially. A baseline pass does not verify changed source; inspect actual outputs and the source/binary manifest.
- Read relevant `docs/control.md`, `docs/automation.md`, `docs/events.md`, `docs/plugins.md` and configuration documentation before changing their contracts. Track broad work in `docs/api-extension-progress.md`; distinguish implemented, tested, deferred and blocked work honestly.
- Preserve unrelated changes. No push/deploy or destructive operations without explicit authorization.

## Plugins and plugin UI

- When building or changing a plugin, an example plugin, or any plugin pane UI in this repository, read `skills/slate-terminal/SKILL.md` first and follow its references: `references/building-plugins.md` for plugin structure and `references/ui/INDEX.md` for the UI design system.
- Plugin pages use the design system by default: `slate.css` and `slate-theme.js` from `references/ui/`, recipes from its components, and palette tokens instead of hard-coded colors. Explicit user design instructions take precedence.
- When a plugin needs a component the design system lacks, add it as a recipe in `references/ui/components/` and run `python3 design-system/build.py`, rather than styling it only inside the plugin.
