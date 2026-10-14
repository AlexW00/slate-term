# API extension implementation progress

Authorized scope: implement the reviewed API-extension plan iteratively with high-value tests, including post-operation lifecycle hooks (not veto hooks). Checkpoint before implementation: `2763ce9`; working tree was clean after that commit. Future capability-parity requirements live in `AGENTS.md`.

## Work queue

- [x] Shared capability/exposure contracts, revision and identity foundations; test-first core coverage.
- [x] Agent environment/routing, self/workspace/pane inspection and JSON CLI errors.
- [x] Appearance/application configuration and palette commands with safe persistence.
- [ ] Nested own-plugin settings writer/API and compatibility tests.
- [ ] Atomic layout operations, pane titles, native tab/window parity.
- [ ] Semantic post-commit lifecycle notifications and replay/recovery.
- [ ] Shared browser/plugin WebKit automation and bridge wrappers.
- [ ] Explicit/user-enabled background services, lifecycle protocol review, supervision tests.
- [ ] Session-preserving hidden panes, lifecycle review, restoration/close tests.
- [ ] Remaining window/storage commands, complete parameter/result discovery schemas and availability metadata, and documentation/examples. Application-font commands are already implemented.
- [ ] Independent code/security/visual reviews where applicable; resolve findings.
- [ ] Sequential complete verification suite and final source/binary manifest check.

No proposed capability should be treated as implemented until its entry records implementation and actual checks. No veto/interception hooks are planned.

## First slice: foundations, context and application settings

Implemented common app/session/workspace/layout guards; live pane-to-tab routing; terminal environment additions; app-epoch revisions across native/legacy mutations (including zoom); paginated snapshots; pane/self metadata and page wrappers; CLI JSON errors; appearance/palette/application-font/warning commands; source-preserving config writes with opaque source/applied revisions and partial-failure reporting. Added shared method exposure policy and command contracts, plus structured page errors. Existing bridge `command.run config.reload` is deliberately preserved as a compatibility exception; new administrative writes are denied.

Tests were written before the initial foundation/config implementations and observed failing, then passing. Independent review found background-tab misrouting, dropped guards, async WebKit guard loss, bridge guard bypasses and zoom revision gaps; fixes have regression coverage, including a queued WebKit click that must not execute after a layout change. Three bounded review passes ended with no actionable findings in the final corrections review. This is not a review of later stages.

Actual latest checks: **132 Swift tests passed** (80 core, 8 IPC, 44 settings); native app/CLI build; production `verify-api-context.py`, `verify-api-settings.py`, and legacy `verify-plugins.py` passed sequentially. Earlier in this slice, legacy context/browser/plugin-command gates also passed. Both new gates are included in `verify-all.sh`. The full suite has not yet been rerun for the extension work.

Evidence: `artifacts/api-foundation-unit.log`, `api-foundation-reviewed-build.log`, `api-context-reviewed.log`, `api-settings-reviewed.log`, `api-bridge-regression.log`, and earlier `api-legacy-{context,browser,plugins,commands}.log`. New public interface documentation: `docs/agent-api.md`.

Residual checks include full sequential verification, visual review of changed menus/picker contents, and more fault injection around post-write runtime-apply/rollback failures. Do not confuse the successful write-permission-failure gate with coverage of every rollback scenario.
