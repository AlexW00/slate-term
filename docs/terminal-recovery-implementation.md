# Saved terminal output and bounded shutdown

Status: simplified access paths implemented; 538 package tests and all six
selected VM gates passed.

## Previous-output simplification

Outcome: keep saved text only for inline restoration. Remove the separate viewer,
header button, Show/Clear commands, history reads/exports, and their public client
adapters. Keep terminal capture, Find/search, retention settings, and shutdown capture.

Acceptance: a restored pane shows saved text and a fresh prompt without a history
button; Find still searches it; repeated restores do not duplicate it; retention
limits still apply. Removed methods and commands disappear from discovery and
are rejected. No changes to the running release instance or shell startup behavior.

Verification: `artifacts/vm/20261020T105610Z-4e2437dc/receipt.json` reports
`completed: true`, `exitCode: 0`. Recovery, terminal history/search, workspace
restoration, API parity, plugin compatibility, and presence passed. The recovery
fixture checks the absent header action and retained inline text through two
relaunches. Follow-up service, response-audit, and visual-review evidence is
recorded in `artifacts/previous-output-removal-verification.md`.

## Inline restoration follow-up

Implemented: saved display text appears in the pane before its fresh shell starts,
with normal scrolling, selection and terminal search. Retention is in General,
visible only while workspace restoration is enabled.

Acceptance: saved `ls`-style output appears above the new prompt after relaunch;
printed commands and terminal controls have no side effects; repeated relaunches
do not duplicate saved text; retention and clearing still affect saved history;
General shows the field only with restoration enabled.
Live processes, terminal colors from earlier sessions, and command replay remain
outside this change. The separate history API and optional viewer were removed in the simplification above.

The engine inserts plain text before I/O begins, bypassing both shell input and
escape-sequence handling. Restored panes capture fresh PTY output in a separate
terminal model, with no effect callbacks, file-based image loading, or image storage.
Its scrollback is bounded to the configured engine limit or 32 MiB, whichever is
smaller. This adds parsing and bounded memory use for restored panes. Resize and
native clear operations update both models. Failed reads preserve the last successful
capture. The visible session separator is presentation, not a persistence boundary.

Follow-up verification: `artifacts/vm/20261020T093001Z-f8355474/receipt.json` reports
`completed: true`, `exitCode: 0`; `terminal-recovery`, `terminal-history`, and
`workspace-restoration` passed. The regression fixture covers visible `ls` output,
search, two relaunches without duplication, partial cursor rewrites, full-screen
clears, and forgetting saved output without re-saving the restored scrollback.
The final six pane/Settings screenshots passed fresh independent visual review.
Code review found no remaining concrete issues after the capture-failure fix.
All 536 package tests passed; 81 release-tooling tests passed, followed by 29
source-packaging tests after the final engine patch. The final native response
audit passed for 6 files, 102 responses, 12 methods and 12 command IDs.
These are selected development checks, not release or updater qualification.

## Scope

Preserve bounded terminal output across restart, including output received during orderly shutdown. Use generic terminal/session ownership for clean stopping. No command replay, shell-history replacement, per-application adapters, conversation tracking, tmux integration or daemon management.

`terminal.saved_output_lines` defaults to 10,000 per terminal, accepts 0...100,000, and uses 0 to disable retention. Additional byte limits bound unusually long lines and the workspace total. Previous output is clearly historical, selectable and searchable, through the terminal’s normal selection and Find controls.

## Milestones

1. Configuration, bounded snapshot model and unit checks.
2. Generic bounded terminal shutdown, output capture, private persistence and inline display.
3. VM qualification for relaunch, final output, forced shutdown, detached-process isolation, configuration, and visual review.

## Acceptance

- Periodic snapshots and orderly quit save received output; restored shells never execute saved text or commands.
- Line limits apply on capture and configuration changes; disabling removes retained text.
- Quit/update termination keeps the reader alive while concurrent bounded stop attempts finish, then captures and disposes.
- Pane removal and replacement stop only their retired terminal; other panes and detached daemons survive.
- A cooperative process can print its final marker before exit; an uncooperative process cannot stall shutdown indefinitely.
- Native Find and trusted CLI/plugin/service search share operations and reject stale targets.
- Verification uses owned processes and apps inside VMPal, never Alex's working Slate instance.

## Original 0.6.0 verification

Final VM run: `artifacts/vm/20261020T014717Z-b7f7ac38/receipt.json` reports `completed: true`, `exitCode: 0`. All four selected gates passed: `terminal-recovery`, `terminal-history`, `workspace-restoration`, and `terminal`.

- Normal app quit completed in 1.52 seconds with a cooperative foreground process, an attached background process ignoring HUP/TERM, and a second stubborn terminal. The retained snapshot contains all 128 lines of the approximately 128 KiB exit-handler burst and its final Unicode marker. The intentionally detached process survived and the fixture then cleaned it up.
- Pane removal stopped its attached process while a sibling and detached session survived. Alternate-screen content and subsequent final output both survived quit. Quitting with no panes completed.
- Relaunch created fresh shell identities without executing printed commands. Lowering the cap, zero retention, API clearing and the native clear button removed the expected historical text. Near-4 MiB Unicode input, API byte/line limits, and unchanged-snapshot write suppression passed.
- Settings accepted the configurable value and rejected a negative value. The history viewer opened through the shared command, remained read-only, handled Command-F, and reached both horizontal edges. Normal and compact Settings/viewer screenshots received fresh independent visual review with no findings requiring changes.
- Full Swift package suite: 478 tests passed. One intervening run failed the existing workspace-lock release test; an isolated retry and the complete replacement run both passed without changing that test.
- VM runner tests: 48 passed. Release-tooling tests: 59 passed. Pinned engine and native app builds passed. Final API response audit passed for 6 evidence files, 103 responses, 12 methods and 12 command IDs. `git diff --check` passed.

The VM exposed and verified fixes for main-queue termination-loop deadlock and premature ancestor shutdown. Output capture remains best effort for programs that do not finish within the stop budget; it is not an application-specific Quit protocol. Tests exercised the normal app termination delegate, not a production update installation. Selected gates are not a full-suite release certificate.

Process signals are restricted to revalidated members of the app-owned terminal session. Each terminal has a 1.8-second stop budget plus an 80 ms reader allowance; attempts run concurrently. Engine disposal has a separate 400 ms direct-child fallback. Output snapshots update only when text changes, with an additional save at orderly quit.
