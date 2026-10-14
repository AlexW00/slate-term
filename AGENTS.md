# Slate Terminal engineering contracts

## Capability parity is part of completion

- Implement behavior once in the authoritative model/host operation. Native controls, registry commands, CLI and approved plugin bridge adapters must reuse it, not fork its behavior.
- For every new capability, explicitly decide native, command-picker/shortcut, CLI/socket and plugin exposure. Add discovery metadata, typed inputs/results/errors, documentation and parity tests in the same change. Reads and parameter-dependent operations need not be one-click picker actions.
- Administrative methods must be denied at invocation, including indirect `command.run`, not merely hidden in menus. Reserve `plugin.<id>.<command>` for contributed commands; use `plugins.*` for host administration. Ordinary web pages/subframes never receive the plugin bridge.
- Maintain an explicit exposure matrix. Intentional exclusions (filesystem writes, credentials, arbitrary eval, application administration) are policy, not accidental missing adapters. Do not claim full parity when an exclusion exists.

## Identity and consistency

- Environment identifies a launching/captured context, not live topology. Resolve current pane membership from the host; distinguish app epoch, pane slot, terminal session, logical plugin instance, web view/document and command invocation.
- Freeze targets before asynchronous work/confirmation, then revalidate. Never recover stale or invalid explicit/inherited identity by targeting the currently focused pane. Session guards must not leak onto sibling targets. Unsupported safety guards must fail closed, not be silently ignored.
- Revisions cover native gestures and legacy APIs as well as new commands. Validate complete model changes before committing; no-op mutations do not increment revisions. Do not describe filesystem/native/process side effects as a rollbackable model transaction.
- Publish bounded post-commit semantic lifecycle events with native attribution and revisions. Preserve replay-expiry/resnapshot behavior. Hooks are notifications, not vetoes; avoid implicit automatic process activation and unbounded feedback loops.

## Resource and security boundaries

- Reuse the shared WebKit automation implementation, but preserve separate browser/plugin navigation, data-store and bridge privileges. Keep automation identities separate from bridge credentials. Never expose credentials or entire environments in inspection/events.
- Commands, panel HTTP services and background services have distinct lifetimes. Bound concurrency, waits, logs, restarts and process ownership; cleanup on cancellation, replacement, unregister and shutdown.
- Hiding a pane is not closing it. Hidden running resources count toward termination consent and resource limits. Never silently evict a live session or replay an old tree over newer layout changes.
- Settings edits preserve unrelated supported TOML/comments and conflict with stale sources. All writers must understand grammar another writer emits. JSON null is not a TOML value; deletion must be explicit.

## Tests and verification

- Start with high-value failing tests where practical: model invariants, invalid/stale routing, atomic failure, destructive consent, bridge denials, lifetime races and compatibility. Include successful native/CLI/plugin parity, not only parser/unit coverage.
- Integration-only `debug.*` is not a production capability. Test through production APIs wherever possible; use isolated fixture roots, owned processes/windows and private clipboards.
- Add applicable integration gates to `scripts/verify-all.sh` and its verification manifest. Run GUI gates sequentially. A baseline pass does not verify changed source; inspect actual outputs and the source/binary manifest.
- Read relevant `docs/control.md`, `docs/automation.md`, `docs/events.md`, `docs/plugins.md` and configuration documentation before changing their contracts. Track broad work in `docs/api-extension-progress.md`; distinguish implemented, tested, deferred and blocked work honestly.
- Preserve unrelated changes. No push/deploy or destructive operations without explicit authorization.
