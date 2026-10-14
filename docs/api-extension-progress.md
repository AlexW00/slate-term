# API extension implementation progress

Authorized scope: implement the reviewed API-extension plan iteratively with high-value tests, including post-operation lifecycle hooks (not veto hooks). Checkpoint before implementation: `2763ce9`; working tree was clean after that commit. Future capability-parity requirements live in `AGENTS.md`.

## Work queue

- [x] Shared capability/exposure contracts, revision and identity foundations; test-first core coverage.
- [x] Agent environment/routing, self/workspace/pane inspection and JSON CLI errors.
- [x] Appearance/application configuration and palette commands with safe persistence.
- [x] Nested own-plugin settings writer/API and compatibility tests.
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

Residual checks include full sequential verification and visual review of changed menus/picker contents. First-slice permission failures alone did not cover every rollback scenario; Phase 2b adds post-write failure injection below.

## Second slice: own-plugin settings

Implemented `plugins.settings.get/patch`, typed `plugins settings get/patch` CLI and own-namespace `workspace.pluginSettings` page wrappers. Patches use bounded literal paths, explicit delete, subtree replacement, whole-source optimistic revisions and shared save/apply/error handling. All writers now share the same source lexer, accept nested/array tables, preserve unrelated semantics/comments, and fail closed on unsupported grammar. Batch insertion and a 1 MiB source/output bound prevent pathological repeated dotted-key expansion. Own-page failures omit raw diagnostics from unrelated namespaces; directed value-free settings notifications retain their existing isolation.

Test-first editor cases were observed red then green. Independent review confirmed three issues, now fixed with regressions: multiline strings nested in arrays masquerading as application assignments; deletion of the last dotted child losing its empty parent; and overly broad old-host rejection during new guard negotiation. The CLI now uses explicit guard advertisements with a narrowly defined fallback for the first versioned API's five existing guards—never for new guards. A read-only follow-up review found no actionable findings, while requesting fresh runtime checks and more page-bridge failure coverage.

Added unit coverage for wide/nested-array settings, plus real CLI/bridge gates for conflict/no-write behavior, subsequent native Settings edits, namespace/event isolation, source removal, and typed/private errors. An integration-only, one-shot prepared-save fault injects an apply rejection after persistence, optionally simulating an external edit that rollback must preserve. Both administrative and own-page cases are covered by fixtures. This does not claim atomic rollback of arbitrary external renderer/process side effects.

Actual checks: **141 Swift tests passed** (81 core, 8 IPC, 52 settings); fresh native app/CLI build; guard-negotiation, plugin-settings, API-context and application-settings production gates passed sequentially, including administrative and page post-write rollback/external-edit cases; `git diff --check` passed. Legacy guard negotiation uses a simulated exact v1 descriptor, not an archived older app binary. The complete extension suite remains outstanding. Evidence paths: `artifacts/plugin-settings-{unit,build,api-green,context-regression,app-regression}.log`, `api-negotiation.log`, `plugin-settings-review-{red,green}.log`, and `plugin-settings-bounded.log`.
