# Intermittent full-suite failures

Status: **Open — investigation deferred**. No clean end-to-end verification run has been obtained.

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

### Investigation hypothesis — unconfirmed

In `Native/BrowserPane.swift`:

- `loadView()` starts a welcome page with `web.loadHTMLString(...)` without recording its returned navigation in `trackedNavigations`.
- `navigate(...)` assigns an operation and records the navigation returned by `web.load(...)`.
- `didStartProvisionalNavigation` cancels the active operation when the callback's navigation does not map to that operation.

A delayed callback from the initial welcome-page load could therefore be mistaken for a successor to the requested navigation. Callback identity/order was not captured, so this is a hypothesis, not a confirmed cause.

Next investigation: record navigation identities and callback ordering around initial loading and explicit navigation, obtain a bounded reproduction, and add a regression before changing cancellation logic. Preserve genuine supersession, cancellation, document identity and platform-operation capacity behavior. Do not hide the failure with sleeps or automatic request replay; the error reports an unknown outcome.

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

## Verification boundaries

All 245 package tests pass. Every suite gate has a passing result across separate runs, but this does **not** constitute an uninterrupted passing full suite or a fresh full-suite verification manifest.

Another attempt (v4) failed the picker focus-stability assertion with the app inactive and picker dismissed. The later idle-desktop run passed that gate. The assertion was not weakened or retried automatically; the reason for that focus loss was not established.

See [API extension progress](../api-extension-progress.md) for the integration history, fixture repairs and remaining manual-verification limits. Further runtime investigation and full-suite certification are deferred; no background verification remains running.
