# MVP foundations

> This file is the `feature/mvp-foundations` branch record. The work was ported
> onto main `b1bf8ca` without the branch's local Bash/fish slice; main's shell
> support replaces it. See [API extension progress](api-extension-progress.md#mvp-foundations-ported-onto-main-b1bf8ca--host-checks-pass-vm-gates-not-yet-run)
> for what changed in the port and what is verified on that source.

Implementation worktree: `feature/mvp-foundations`, initially based on main `1706a08`.
The previous carried-over working tree was verified against its baseline manifest
and archived in ignored `artifacts/mvp-baseline/carried-baseline.tar.gz` before
fast-forwarding. The original checkout is not edited.

## Packaging integration — verification in progress

After the request to continue, snapshot `ae1cb704` preserved main's current
packaging work without modifying its checkout/index. The unrelated website mockup
was excluded, and separate shell work is not being folded into this integration.
The snapshot is being reconciled with verified MVP integration `ab690f0`.

ZIP registration/validation now retain MVP compatibility checks before publication
and launch, while incompatible installed packages keep their enabled preference.
The shared catalog describes portable manifests separately from resolved runtime
registrations, unavailable installations and pending package cleanup. It covers
**111 methods, 95 built-ins, the contributed template and 225 definitions**.

Host checks passed **425 executed package tests** (one evidence test skipped),
**37 runner tests**, native app/CLI/helper build and **639 standard schemas**;
the representative description is **543,047 bytes**. Review found an unavailable
package enable crash and a stale persistence-failure fixture expectation. Both
were corrected, with a native/API regression added for the missing-package case.
Combined VM run `20261017T014445Z-f75132de` completed with **43/46 gates passing**;
saved-layouts reported owned-process teardown leakage, notifications observed an
automatic completion during an OSC-only assertion, and plugin-persistence assumed
status was empty before asynchronous package cleanup. The response audit checked
1,119 observations but found an undocumented `-32051` lifecycle admission error.
These are unresolved at this checkpoint, not a verification pass. A further main
build/test snapshot `f9850766` is preserved for reconciliation. Main has not been
advanced. No push or deployment.

## Earlier integration with committed main — verified, main update blocked

The requested local integration combines MVP checkpoint `55545b3` with main
`9e14da4` on `feature/mvp-foundations`. It retains main's API parity, agent
presence, plugin persistence, onboarding and documentation work. The catalog now
covers **110 public methods, 95 built-ins and the contributed-command template**,
with **217 definitions**. Main's removed `storage.*` API stays removed; shared
plugin data and per-panel state retain their separate guards and lifetimes.
Native window callbacks retain both presentation events and restoration saves.
Request metadata has a separate schema at `contracts.requestMetadata`.

Final selected VM run **`20261017T010343Z-f7eb7523` passed 21/21 gates**: the
17 original MVP gates below plus api-parity, presence, plugin-persistence and
welcome. Host checks passed **418 package tests** (the evidence test was skipped
in that ordinary suite), **37 runner tests**, three targeted model mutation
checks, native builds, and whitespace checking of the integration against main.
Independent standard validation passed **629 schemas**; the representative
description is **529,469 bytes** with one contribution.

The separately executed native audit passed **1,019 responses in 15 files**,
covering **73 methods and 40 command IDs** across socket, CLI, bridge and service
clients, with captured catalogs matching current source. Before final docs edits,
all **504 source hashes and 2,313 host-product hashes** matched the receipt;
implementation and binaries were not changed afterward.

Integration checks first caught private workspace data being used as a public
test sample, a saved-layout fixture exceeding main's new per-panel configuration
limit, and the mutation harness omitting the new test-support target. Review
caught web-action placement fields. The first 21-gate run
`20261017T005008Z-c56bc4c3` passed behavior checks, but its response audit found
missing web-input snapshot attributes and native window IDs incorrectly described
as bare UUIDs. Those schemas and regressions were corrected before the final run.

Evidence: `artifacts/vm/20261017T010343Z-f7eb7523/{receipt,results}.json`,
`artifacts/main-integration-shapes-{unit,schema,vm-driver,native-audit}.log`,
`artifacts/main-integration-runner.log`, and
`artifacts/main-integration-mutations-fixed.log`.

**Main was not advanced.** During verification its checkout accumulated extensive
overlapping, uncommitted plugin-packaging and terminal changes. A coordination
question received no answer, so those changes were neither stashed, committed,
overwritten nor folded into this verified integration. The integration is kept
as a local branch commit; updating main remains blocked until that concurrent
work is settled. No push, deployment, full 86-invocation suite or manual release
certification is claimed. Earlier counts below describe the original MVP phase.

## Approved scope

1. Native terminal Find and bounded retained-history retrieval/export, shared by
   CLI, registered pages and services.
2. Practical restoration: working directories, window geometry and browser
   starting locations. No process restoration, command replay or saved transcripts.
3. Local Bash/fish authenticated integration alongside zsh: safe submission,
   unfinished-draft refusal, prompt/context/completion reporting. No remote integration.
4. Session-owned long-running terminal operations: immediate handles, status/result
   lookup and repeatable waits surviving caller disconnect/timeout. Bounded retention;
   explicit tracking/session loss. Waiting cancellation is not process interruption.
5. Complete machine-readable public method/command contracts and plugin
   manifest/API/required-capability compatibility checks before execution and on launch.

No customization expansion, remote transport, multiplexer, durable cross-restart
job queue, marketplace, auto-update, or new privilege tiers. Manual release QA is
user-owned; automated native/UI checks run only through VMPal.

## Original MVP selected verification

**The approved MVP implementation and its original selected verification were complete before the integration above.**
VM run `20261016T180811Z-0b4f9e9a` passed **all 17 selected gates**: browser-data,
background-services, api-settings, plugin-settings-api, layout-api, plugin-lifecycle,
web, terminal-history, command-lifecycle, agent-skills, workspace-persistence,
events, context, local-shells, workspace-restoration, plugin-compatibility and
terminal-runs. This includes Bash/fish production/vi/draft/nested-reader checks,
reconnectable operations, restoration, complete discovery/client parity and used/
unused WebKit profile cleanup.

- **374 package tests** executed successfully; the separate native-evidence test
  was skipped in that ordinary run, then explicitly executed successfully below.
- **37 runner tests**, native app/CLI/helper and selected native-fixture builds,
  syntax checks and diff checks passed. Existing build warnings are recorded below
  in the chronology; no warning-free build claim is made.
- Independent Draft 2020-12 validation passed **561 schemas**, actual shared
  discovery encoders and command references. Custom formats/annotations are not
  independently enforced by that validator.
- The final native audit passed **709 captured responses**, covering **59 public
  methods and 31 command IDs** across socket, CLI, registered-page bridge and
  managed-service clients. Every captured client catalog matched the shared source.
  This is observed coverage, not execution of every method, command or failure state.
- Immediately before these final documentation edits, **459 source hashes and
  2,312 host-product hashes** matched the selected run receipt. No implementation
  changed afterward.

Evidence: `artifacts/vm/20261016T180811Z-0b4f9e9a/{receipt,results}.json`,
`artifacts/mvp-profile-cleanup-{unit,runner,vm-driver,native-audit}.log`, and
`artifacts/mvp-discovery-precision-standard-audit.log`.

The following sections retain the implementation/verification chronology. Earlier
failed runs and pending notes are superseded only where the final evidence above
actually supplies coverage. No full 83-invocation suite or release certificate is
claimed; manual release QA and remaining coverage limits are listed at the end.

## Terminal Find/history slice — implemented, selected verification passed

- **Find in Terminal…** (`terminal.find`, Cmd-F), Next/Previous (Cmd-G/Cmd-Shift-G)
  and Close Find are shared registered commands. They require a terminal target;
  opening native controls requires a visible terminal. Find state belongs to the
  terminal session and follows live pane moves.
- The native search field and `terminal.search` use the same pinned-engine search
  operations. Queries are literal, at most 4096 UTF-8 bytes without NUL. Search is
  asynchronous: count/selection can be null until the engine reports them. Selected
  indices are zero-based. Empty query clears matches while keeping Find open.
- `terminal.history` returns a tail of retained text including the active screen,
  limited to 128 KiB and 10,000 newline-delimited logical lines (default 2,000).
  Results include text, byteCount, lineCount, truncated, paneId and sessionId.
  This is neither a stable paginated snapshot nor command stdout. History lost to
  engine eviction, clearing, or session replacement cannot be recovered. The active
  alternate screen is read when a TUI uses it; no hidden primary-screen archive is promised.
- The pinned embedding API allocates its retained-text dump before Slate clips the
  returned UTF-8 tail. Response limits are not a promise that the engine allocation
  is that small; retention remains bounded by the engine's existing memory policy.
- `terminal.historyExport` accepts the same limits plus an explicit absolute path.
  It creates a private mode-0600 file without overwriting existing paths or following
  a final symlink. Failure during writing can leave a partial newly-created file.
  No implicit logging or transcript persistence is enabled.
- `terminal.capture` now actually reads the active screen, independently of the
  user's scroll position. The old implementation used Ghostty's `SCREEN` coordinate
  tag, which means **all retained rows**, contrary to Slate's documented contract.
  The explicit history API replaces that accidental behavior.

Examples:

```sh
slate-term terminal history --pane p1 --max-lines 1000 --max-bytes 65536
slate-term terminal historyExport --pane p1 --path /absolute/new-output.txt
slate-term terminal search --pane p1 --search-action set --query 'error'
slate-term terminal search --pane p1 --search-action next
slate-term terminal search --pane p1 --search-action get
slate-term terminal search --pane p1 --search-action end
slate-term command run terminal.find --pane p1
```

Registered pages have `workspace.terminal.history`, `.historyExport` and `.search`;
services use the same catalog and methods. All accept explicit pane/session routing
and normal host guards. Export is a trusted local-file operation. Discovery is under
`api.describe.terminalHistory` and `.terminalSearch`; see the API contracts section
below for the later complete-catalog implementation and its verification status.

## Verification

New package tests cover line/byte-limit validation and search-request invariants.
`scripts/verify-terminal-history.py` is registered in the shared VM gate inventory
for real engine history/active-screen separation, search, native commands, CLI/page
parity, safe export and replacement guards. The three-client service fixture also
covers history/search discovery and routing.

## Plugin compatibility slice — implemented, selected verification passed

Manifests now carry an optional format version, diagnostic release identifier and
API-generation/method/built-in-command requirements. Missing declarations mean the
original manifest/API generation, not all future generations. Registration and
enable reject unsupported requirements before side effects; panel/command/service
entry points also check. Launch filters incompatible stored registrations from the
active catalog without deleting them or changing the user's enable preference.
Listing and Settings expose a bounded incompatibility report. Offline validation
checks the CLI build; registration checks the actual host. See [plugins](plugins.md#version-and-compatibility-declarations).

Package tests verify requirement validation, public-only catalogs, API-generation
changes, lossless encoding, failed replacement preservation and launch revalidation.
The new `plugin-compatibility` VM gate exercises register/replace/offline validation
and restart with a newer stored requirement.

## Practical restoration slice — implemented, selected verification passed

The private workspace snapshot now stores validated directories, normal-browser
URLs and windowed frames alongside topology in one atomic write. Private-browser
URLs, commands, transcripts and process identities are excluded. Fresh terminals
use saved directories, falling back to home if unavailable; window frames fit
current screens. Runtime changes coalesce saves at 250 ms. Existing restoration
configuration, status and shared operations apply to all clients; semantics are
advertised by `api.describe.workspaceRestoration`.

Unit tests cover round trips, privacy/reference validation, failure preservation
and removed-screen geometry. The new `workspace-restoration` VM gate exercises
restart locations, privacy, fresh sessions/no replay, geometry, type replacement
and missing directories, including quitting from full-screen and a URL changed at page load. These checks passed in the selected VM run recorded below.

## Local shell slice — selected verification passed

The user approved Bash **5.3+** for authenticated automation; older Bash remains
ordinary terminal-only. Bash hooks are implemented behind that version guard,
using parent-shell prompt markers, Readline buffer checks, a conditional queued
accept-line binding, and Ghostty's original startup loader. CLI hook output supports
`shell integration --shell bash`.

VM `20261016T142122Z-10918b5c` passed the strengthened Bash and fish editor proofs
(draft side effects, exact editor-buffer barriers, continuation refusal, conditional
execution and queued typeahead). It also passed Bash production startup preservation,
Unicode/multiline/nonzero completion, cwd updates, draft/continuation refusal, and
ordinary-terminal fallback for old Bash and integration-off mode. The fixture now
restores its private HOME after macOS login instead of accidentally testing the
VM user's startup files. Bash builtin-declaration values are explicitly quoted.

The invalid `vi-insertion` keymap name was corrected to Readline's `vi-insert`.
VM `20261016T143847Z-3b2c2e1b` passed local-shells, including actual Bash vi
insert/command maps. Initial prompt telemetry now gets a five-second socket I/O
timeout; later reports and input claims retain one second, without replay. The
context gate failed an assertion that a one-second sleep was still running after
CLI round trips; that fixture now uses an explicit bounded release barrier.

Fish production hooks and session-specific command syntax are implemented. The hooks use the proven standard
chord, exact buffer checks and the interactive-read predicate (fish 4.0.1+).
Fresh-review fixes defer binding checks until user keybindings initialize and
require postexec/reader state before reporting completion. All 329 package tests
passed after those fixes. VM `20261016T150738Z-221a4d43` passed Bash again and
verified fish startup, Unicode/multiline/status, user prompt pipestatus, cwd and
first draft refusal, then failed cancellation recovery. Fish cancels by redrawing
cached prompt text; the hook now explicitly queues repaint to renew readiness.
That run's context gate timed out during startup; its startup allowance now
matches the local-shell fixtures and includes failure sampling.

**VM `20261016T152114Z-7f925247` passed context and local-shells**, including all
Bash/fish production checks, cancellation recovery, nested reads, late user-binding
conflicts and vi maps. All 329 package tests passed for that source. This is selected
gate evidence, not a full-suite or manual release-QA certificate.

Shell tests use an isolated, SHA-pinned fish archive and a copied Bash 5.3+ with
relocated dependencies, never system shell installation or host desktop input.
A pre-existing runner test's fixed-delay reparenting race was replaced with a
capture-ledger handshake; the subsequent runner suite passed before editor execution.

## Reconnectable operation slice — selected verification passed

`TerminalOperationStore` now defines session-owned handles and explicit input,
running, capture, completion, rejection, interruption, tracking-loss and session-loss
states. Admission shares 32 slots with startup reservations. At most 128 records
are retained; finished records expire after 15 minutes or are evicted first under
capacity pressure. Unfinished work is never silently evicted. Results are repeatable,
bounded screen observations, not isolated command stdout/stderr. No waiter/caller
lifetime is stored in this model.

Host tests cover stale sessions/reports, draft refusal, capture reentry, reservations,
result bounds and retention. A failed successor-reservation test exposed and fixed
an old-session callback consuming new preparation. Source review found no further
model defects; its suggested capture/expiry regressions were added. The initial
model snapshot passed 318 package tests and the native build. Eight focused tests
subsequently passed for additional model edges and the async coordinator: concurrent
waiters, cancellation/timeout without lost ownership, repeatable results, bounded
wait admission, synchronous reports, and pre-adoption cancellation.

Native `TerminalRuns` now adapts the shared coordinator. `terminal.start`,
`terminal.operations`, `terminal.operationStatus`, `terminal.operationResult` and
`terminal.operationWait` use the public catalog and shared dispatch, with CLI and
plugin SDK access. Handle reads intentionally do not inherit live-pane targets.
Legacy `terminal.run` still waits for a result, but timeout/disconnect no longer
retires tracking. The native adapter fixture and actual-shell context fixture now
assert these changed semantics. **All 326 package tests, the app build, and compile-only native adapter fixture
checks passed for this integration.** VM run `20261016T134818Z-4800edbb`
passed `terminal-runs`, `context`, and `background-services`, including real zsh
reconnects, all three trusted clients, plugin-document retirement, and service
retirement without losing terminal ownership. This is selected-gate evidence,
not full-suite certification. General discovery schema implementation and its
remaining checks are recorded separately below.

Shell runtime checks were blocked by the separately owned VM lock
`20261016T131215Z-c7760924` after run `20261016T131347Z-f2e15bb5`
failed to acquire it. A read-only check after host integration verification found
the VM unlocked. In `20261016T134818Z-4800edbb`, `local-shells` still failed:
Bash's isolated editor proof passed and production startup reached an authenticated
prompt, but the first automated command was classified as another command. Fish
preserved its continuation buffer, but fixture cancellation failed to clear it.
Subsequent focused runs recorded fixture-only helper arguments (never credentials)
and used a queued fish reader cancellation event instead of racing raw SIGINT
against a returning callback. The successful local-shell run above supersedes these
shell failures. No lock was removed or foreign job stopped.

## API contracts

Shared JSON Schema primitives and 26 terminal/workspace method contracts are
implemented in Core, with explicit results, supported guards, errors, availability
conditions and routing. Six focused tests passed against real model encoders and
parser branches, including legacy pane encoding, recursive layouts, conditional
search arguments, operation-handle isolation and native-window targeting. The
full regression for that slice passed 335 tests. Three further tests passed for
14 event, notification, welcome and service contracts.

Nine configuration, appearance, palette and plugin-settings contracts bring the
unpublished catalog to 49 methods. Tests compare configuration/appearance encoders
and both source-preserving patch writers against the schemas. Their first full
regression crashed in the test-only recursive schema evaluator at a 32-level
fixture; LLDB isolated stack exhaustion on a test worker. Recursive evaluation now
uses smaller frames. Fresh review also identified namespace-relative patch depth,
explicit-pane/tab polling and trailing-newline regex gaps. All 342 package tests,
diff checks and event-script syntax passed after the fixes
(`artifacts/mvp-reviewed-settings-contract-unit.log`). The added event polling
VM assertion was subsequently executed successfully in the final selected run.

Six contextual settings/storage/title/recipe contracts and three agent-skill
contracts bring the unpublished total to 58. All 346 package tests and diff checks
passed (`artifacts/mvp-contextual-skill-contract-unit.log`). Review then found that
a bare global storage instance ignores `tab`, including null/non-string values,
while pane/layout-guard routing and scoped owners validate it. The schema now
preserves that existing distinction; source behavior was not changed. The corrected
slice passed all 346 package tests, diff checks and fixture syntax
(`artifacts/mvp-reviewed-contextual-contract-unit.log`). New three-client VM
assertions cover this distinction and null storage versus deletion; they have
passed in the final selected run.

Eight plugin-management contracts bring the unpublished total to 66. Submitted
manifests and normalized registrations have separate schemas, including nullable
legacy defaults, compatibility, processes/commands, header contributions and
layout fields. Status distinguishes panel instances from retained command runs;
lifecycle replies include commit/persistence fields. Scoped independent review
found no actionable mismatches. The first build caught a missing delimiter in a
new test fixture; after correction, all **350 package tests** and diff checks
passed (`artifacts/mvp-plugin-contract-unit-reviewed.log`). Native runtime
status/restart/log contract checks remain outstanding.

Eleven saved-layout contracts bring the total to 77. They distinguish submitted
and normalized recipes, enforce topology/identity/depth/size rules, describe
file-content revision guards, preserve capture/open/startup semantics and reuse
plugin field schemas. Actual file-store and field-encoder checks passed with all
**355 package tests** and diff checks (`artifacts/mvp-saved-layout-contract-unit.log`).
Scoped review found no actionable mismatches. Native summary truncation,
private-browser capture and cross-session startup result checks remain outstanding.

Twenty browser/web contracts bring the unpublished total to 97. They preserve
legacy routing and permissiveness separately from canonical explicit-pane,
paired-identity/ref, renderability and attached-viewport screenshot rules.
DOM UTF-16 clipping differs from native inspection's Unicode-scalar clipping;
site-data deletion has explicit URL/pane targeting and WebKit site-group scope.
Scoped review found no actionable mismatches. All **359 package tests** and diff
checks passed (`artifacts/mvp-web-contract-unit.log`). Actual native response
conformance and eligibility/race checks against these schemas remain outstanding.

All **85 built-in commands** received machine-readable contracts
in `WorkspaceCommandContracts.swift` and `ApplicationCommandContracts.swift`.
They describe complete `command.run` inputs, legacy versus strict argument
handling, native availability, settings/UI acknowledgments and workspace commit
results. Inventory, reference closure, real model-result fields, title trimming
and settings parser checks passed with **365 package tests** and diff checks
(`artifacts/mvp-builtin-command-contract-unit.log`). Review found one semantic
mismatch: omitted `tab.move` index appends across groups but preserves order
within the current group. The metadata is corrected and a two-case model
regression added; follow-up verification passed **366 package tests** and diff
checks (`artifacts/mvp-reviewed-command-contract-unit.log`). Native result enrichment and
UI/settings handler responses still need VM conformance checks.

The native app/CLI/helper build passed after the 97-method slice
(`artifacts/mvp-method-contract-build.log` and `artifacts/app-build.log`), with
AppIntents/dependency-scan warnings and an existing unused `assumeIsolated` result
warning. It predates the built-in command schema additions.

The complete catalog is now **wired into shared native discovery** in source:
**100 public methods, 85 built-in commands, and a contributed-command template**.
Existing capability values moved to shared Core producers; old command-row fields
remain intact with an additive `contractRef`. `api.describe.contracts` holds the
schemas once, with shared command-input definitions avoiding duplicate payloads.
Contributed arguments preserve unknown `expected*` names while enforcing reserved
host guards, resolved-invocation bounds and successful process-result semantics.
Pane/tab/group ID formats now also describe signed-integer overflow rejection.

All **373 package tests** passed before and after wiring/reference deduplication
(`artifacts/mvp-complete-catalog-unit.log`, `artifacts/mvp-wired-catalog-unit.log`).
The actual shared producer emits **189 definitions and 467,932 bytes** with one
contribution. Tests cover complete inventories, reference closure/vocabulary,
actual description and command-row encoders, legacy decoding, conditional command
admission and ID bounds. Scoped static review found no actionable defects. Native
app/CLI/helper build and diff checks also passed
(`artifacts/mvp-wired-catalog-build.log`, `artifacts/app-build.log`); existing
AppIntents/dependency-scan and unused `assumeIsolated` warnings remain. The independent
Draft 2020-12 audit passed **561 schemas**, the actual shared description/command-list
encoders and all command references (`artifacts/mvp-independent-schema-validation-reviewed.log`).
It does not independently enforce custom formats/annotations or cover native responses.
The final selected verification above supplies native observations and three-client
parity. Discovery is still unpaginated: large active command lists can exceed
existing transport limits.

Existing owned VM fixtures now opt into bounded public-response evidence (32 MiB,
4,000 records per fixture, private files). Capture excludes non-public calls,
request arguments and error messages; only the command ID selects a command schema.
Three-client coverage now checks complete discovery/command references and actual
successful contributed-command results plus reserved-guard rejection. An opt-in
host package test audits retrieved responses against the current shared catalog;
it does not launch an app. The first regression stopped at a nested Swift Testing
`#require` macro in the new audit test; splitting the expression fixes that compile
issue. Fresh host checks passed 373 executed package tests (the native-evidence
check was explicitly skipped), 37 runner tests, Python syntax and diff checks.
The opt-in audit self-check passed using shared-producer data, not native evidence
(`artifacts/mvp-contract-capture-reviewed-*.log`, `artifacts/mvp-contract-audit-selftest.log`).

Selected VM run `20261016T175313Z-e645ce09` completed all 16 gates: **12 passed**;
background-services, api-settings and web failed discovery equality, and local-shells
failed the fish vi-map probe after its Bash checks passed. Retrieved evidence isolated
the discovery mismatch to two `Int.max` schema bounds rounded by JavaScript. These
now use a documented exact signed-64-bit annotation, preserving host input limits;
a regression checks all discovery numbers are JavaScript-safe. The fish probe sent
another escape-prefixed key immediately after bare Escape, without observing the
reader's mode transition. It now waits for the actual `fish_bind_mode` change before
probing, rather than relying on escape-sequence timing. The final local-shells gate
passed with this barrier.

The first response audit passed 363 observations across 48 methods and 26 command
IDs in 12 capture files (`artifacts/mvp-native-contract-audit-first.log`). That audit
checked result shapes, not equality of every client's nested catalog; it now checks
that too. The three-client gate stopped at bridge discovery, so service parity and
contributed-command assertions were not reached. This run is not an integrated pass.

The corrected run `20261016T180120Z-f0cac96e` passed **14/16 gates**, including all
three discovery-parity failures, contributed commands through CLI/page/service,
context and session-owned operations. Host checks passed **374 executed package
tests** (one native-evidence test skipped), 37 runner tests, syntax/diff checks,
561 standard schemas and the audit self-check. The updated discovery sample is
468,108 bytes. Its stricter actual-response audit passed **714 responses across
59 methods and 31 command IDs**, covering socket, CLI, bridge and service clients
(`artifacts/mvp-discovery-precision-*.log`). This is observed coverage, not every
method/state or complete release QA.

The two failures were teardown errors: WebKit reported `Failed to delete files on
disk` for agent-skills and Bash-vi fixture cleanup. Their action assertions completed,
but local-shells stopped before reaching fish. The test-only cleanup helper was
creating the unused named store immediately before deleting it. It now initializes
WebKit with an ephemeral store, enumerates existing identifiers and removes only
an existing fixture-owned profile. The browser-data gate adds repeated cleanup of
an unused profile and verifies used-profile enumeration/removal. This correction
passed the final browser-data gate and all fixture teardowns; failed-run fixture
ownership metadata remains preserved by the runner.

The schema fragments use catalog-root `#/$defs/…` references; `x-*` annotations
identify host constraints such as UTF-8 bytes that ordinary JSON Schema keywords
do not express. The Swift test evaluator checks the emitted subset only. An
isolated test-only Python environment was used for the independent Draft
2020-12 audit, not as an application dependency. Its first audit hit a 120-second
timeout from redundantly meta-validating all definitions for every descriptor;
the audit now checks shared definitions once. That was an audit-script inefficiency,
not a demonstrated schema or production failure.

## Earlier slice evidence

- Find/compatibility host checks: **308 package tests**, **35 runner tests**, native
  build and syntax/whitespace passed (`artifacts/mvp-focus-*.log`).
- Find/history passed in selected VM run `20261016T074848Z-7e6f22b9`, including
  repeat queries, focus attribution, Find/PTY focus through moves, safe export,
  CLI/page routing and replacement. Independent source review had no remaining
  findings; independent rendered review found no issues in wide/compact screenshots.
- Plugin compatibility, terminal lifecycle, context and background services passed
  in `20261016T074215Z-8e8eb329`. That run's history setup failed because the initial
  shell telemetry RPC timed out before Find was exercised. The focused test now
  waits for telemetry before dismissing welcome chrome and retains startup diagnostics.
- Earlier VM attempts were blocked by another run's lock; it was left untouched.
- Restoration plus workspace-persistence, settings, browser-navigation and Find/history
  passed in `20261016T080512Z-8a1805ba`. All **311 package tests** and **35 runner
  tests** passed (`artifacts/mvp-restoration-reviewed-*.log`); the VM runner built
  the native app and browser-navigation executable on the host.
- These selected results are not a full-suite certificate for subsequent changes.
  Bash/fish production and vi-mode checks and reconnectable operations passed
  in `20261016T152114Z-7f925247` (context/local-shells); 329 package tests passed.
  The later 17-gate integrated pass and response audit are recorded above.

## Remaining coverage and manual release QA

- The full 83-invocation inventory was not run for this change. The final receipt
  is a selected pass, not `artifacts/verification.json` full-suite certification.
- Native response observations cover 59/100 methods and 31 command IDs, not every
  declared handler, UI acknowledgment, capacity failure, race or filesystem edge.
  Saved-layout summary truncation/private capture/cross-session startup and broader
  native dialogs remain outside the final response-audit sample.
- Discovery is complete structurally but unpaginated; sufficiently large active
  command lists can exceed the existing 1 MiB transport/queue budget. Pagination
  would be a separate improvement, not an added feature in this scope.
- Manual release QA is user-owned: normal plugin/shell customizations and vi maps;
  Find/shortcut/IME/accessibility behavior; multi-display/fullscreen/sleep-wake
  restoration; real long-running programs and interruption behavior; and ordinary
  notification/clipboard permission flows. Automated selected cases do not certify
  these broader platform/user-environment combinations.
- No host desktop testing, app deployment, push or publication was performed.
  The later authorized integration uses local commits; the original checkout and
  carried baseline remain preserved. Updating main is blocked as described above.
