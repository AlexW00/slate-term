# Intermittent full-suite failures

Status: **Partially investigated — browser callback-ordering defect fixed locally; header failure unresolved**. No clean end-to-end verification run has been obtained.

Observed after saved layouts were integrated into main at `f99e670`. Fixture repairs and failure diagnostics were committed in `4f922cd`; no browser or command-runtime fix was made. The failures are not established as saved-layout regressions.

## First browser navigation incorrectly reports supersession

### Observed behavior

During a user-authorized idle-desktop run of `bash scripts/verify-all.sh`, `scripts/verify-browser.py:104` failed on its first `browser.navigate` request after switching a terminal pane to a browser through the native pane-type menu:

```json
{"error":{"code":-32022,"outcome":"unknown","data":null,"message":"Navigation was superseded"}}
```

The fixture had not deliberately submitted a competing navigation. Picker, menu, saved-layout and preceding gates passed in that run. The browser gate passed in an earlier full-suite attempt, so reproduction is intermittent.

Expected: the requested local fixture page loads and the response reports title `Slate Browser Fixture`. A genuinely newer navigation must still supersede an older request.

### Reproduction and evidence

With the native app built using `bash scripts/build-app.sh`:

```sh
python3 scripts/verify-browser.py
# Full sequence in which the failure was observed:
bash scripts/verify-all.sh
```

These are reproduction entry points, not a deterministic reproducer. The fixture starts an owned local HTTP server and app, switches pane `p1` to browser, waits for the old shell to terminate, checks layout preservation, then navigates to its local server.

Local evidence: `artifacts/main-saved-layouts-full-suite-v5.log`. Artifacts are not committed.

### Targeted investigation — callback-ordering defect confirmed

`Tests/WebOperations/BrowserNavigation.swift` captures real `WKNavigation` delegate callbacks for the welcome load, submits an explicit navigation, then delivers the retained welcome callbacks. Before the fix this fails at the welcome `didStartProvisionalNavigation`: the explicit request is cancelled despite being newer. This is controlled callback delay, not a reproduction of the historical full-suite timing; that run did not capture callback identities.

The cause in `Native/BrowserPane.swift` was that only RPC navigation identities were tracked. Welcome, recipe and native-control loads were not all recorded at submission, so their delayed starts could be mistaken for new page-initiated navigation. A delayed commit could also overwrite the current navigation.

The local fix remembers host-submitted navigation identities, including those without an RPC operation. Starts from known older loads and commits from noncurrent loads cannot replace the current navigation. Unknown page-initiated starts still supersede pending RPC work. The identity set is weak: WebKit can omit terminal callbacks for loads replaced before they start, so native loads must not be retained indefinitely. RPC submissions retain their existing strong tracking and platform reservations until callback or teardown. No sleeps, retries or public API changes were added.

Focused entry point (no app windows or Ghostty build needed):

```sh
swift build --product slate-term --jobs 4
bash scripts/verify-browser-navigation.sh
bash scripts/verify-web-operations.sh
```

The regression checks delayed welcome/recipe starts, commits and finishes; genuine RPC/page successors; cancellation; platform-slot retention; real first HTTP navigation; document replacement and history restoration. Additional server-held HTTP requests verify real in-flight supersession/cancellation and failure-callback cleanup, waiting for server receipt before interruption. History navigation is checked, but this window-free fixture does not assert a BFCache hit. Local evidence in the investigation worktree: `artifacts/browser-navigation-red.log`, `artifacts/browser-navigation-final.log`, and `artifacts/web-operations-final.log`.

## Header buttons remain disabled after a short command

During full-suite attempt v3, 58 gates passed before `scripts/verify-plugin-header-buttons.py` timed out waiting for header actions to re-enable. The failing invocation was `click('p1', 'terminal')` on an unfocused sibling after a split. Its command writes the clicked tab/pane to a marker and sleeps for one second; the fixture allows 15 seconds for completion/re-enabling.

Expected: the command completes, its header actions re-enable, and clicking the disabled action does not launch a duplicate or change focus/layout.

An earlier sweep and a subsequent diagnostic run both passed. Root cause remains unknown; neither a runtime defect nor a fixture race has been established. Later full-suite attempts stopped before this gate.

Reproduction entry point:

```sh
python3 scripts/verify-plugin-header-buttons.py
```

Local evidence:

- `artifacts/main-saved-layouts-full-suite-v3.log`: timeout.
- `artifacts/completion-plugin-header-buttons.log`: diagnostic run passed.

Commit `4f922cd` retains failure-only `HEADER_COMPLETION_DIAGNOSTIC` output containing header state, command lifecycle status and workspace inspection. On reproduction, distinguish an unfinished command from stale header presentation before changing deadlines or runtime code. No fix is claimed.

The worktree investigation added six bounded, window-free executions of the same one-second shell command to `Tests/ServiceCommands/ServiceCommands.swift`. All six produced `t1/p1`, exit code zero, exactly one running/succeeded lifecycle pair, and running/idle `onChange` notifications. Existing service-command ownership/retirement checks and `verify-plugin-process.sh` also passed. Evidence: `artifacts/header-command-completion.log` and `artifacts/plugin-process.log`.

This exercises the supervisor and command-state notifications, not native header rendering, unfocused-sibling dispatch or the full-suite desktop sequence. The historical timeout remains unconfirmed; no command-runtime fix or longer deadline was introduced.

## Verification boundaries

At the original report, all 245 package tests passed and every suite gate had a passing result across separate runs. This does **not** constitute an uninterrupted passing full suite or a fresh full-suite verification manifest. The worktree investigation ran only the focused checks above, not the package suite, native app integration gates or `verify-all.sh`.

Another attempt (v4) failed the picker focus-stability assertion with the app inactive and picker dismissed. The later idle-desktop run passed that gate. The assertion was not weakened or retried automatically; the reason for that focus loss was not established.

See [API extension progress](../api-extension-progress.md) for the integration history, fixture repairs and remaining manual-verification limits. The header failure, historical callback ordering and full-suite certification remain unresolved. Passing targeted regressions do not certify the full desktop sequence.
