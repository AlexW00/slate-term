# Rename-tab gate depends on uncontrolled desktop focus

## Disposition

At the user's request, removed the automatic “Cancelled on deactivate” case from `scripts/verify-tab-titles.py` and its now-unused `debug.tabRename` deactivation hook. Kept the remaining title/API/editor coverage and the production `didResignActiveNotification` cancellation behavior. No suite or build was rerun. The later key-window timeout described below is a separate remaining focus dependency, not certified fixed by this removal.

The following records the investigation before removal; file line numbers refer to that version.

## Report and evidence

The supplied screenshot (`pi-clipboard-660a23ae-03ce-48cb-9e4d-f9c302710769.png`, desktop clock 09:38 on 2026-10-16) shows the owned `API_TEST>` app with the Rename Tab sheet and draft **“Cancelled on deactivate”**. The user observed that moving focus away lets the test continue.

This identifies `scripts/verify-tab-titles.py:157–161`:

1. `debug.activate` selects/activates `t1`.
2. `tab.rename` presents its sheet.
3. `editor(draft='Cancelled on deactivate', deactivate=True)` calls `debug.tabRename`.
4. The gate waits until the sheet reports `editing:false`, then activates the app again.

Before removal, `Native/WorkspaceHost.swift`'s `debug.tabRename` called `NSApp.deactivate()` before applying the draft. `Native/TabRenameController.swift:92–100` observes `NSApplication.didResignActiveNotification` and invokes `cancelForLifecycle`; `finish` ends the sheet. Thus a real focus change can deliver exactly the lifecycle event needed for progress.

The same main-checkout run's existing `artifacts/tab-title-main-integration.log` does **not** show a deactivation timeout. It proceeds farther and fails at `scripts/verify-tab-titles.py:228`:

```text
AssertionError: Timed out: target selected before minimizing
```

That step requests `window.focus(..., activate:true)` and waits for `native()['key'] and native()['selected']`. Both stages depend on external macOS focus state. The empty `tab-titles-process.log` contains no lifecycle trace. No matching live app/test process remained when inspected, so no stalled-thread sample was available.

## Diagnosis and confidence

**Confirmed harness weakness:** the automatic gate repeatedly requests real desktop activation/deactivation, rather than testing only its owned model/UI state. Its deactivation case does not control an owned recipient application or separately confirm that macOS actually delivered a resignation event. Its repeated activation requests can also disturb the user's foreground work. The screenshot's draft is an exact match for this case, and the later recorded failure independently demonstrates focus-sensitive behavior in the same gate.

**Likely explanation for the reported pause:** the test is waiting on an actual application-focus transition, and the user's app switch supplies it. Do not interpret a request to deactivate/activate as proof that the intended OS focus state has settled. Apple's documentation says activation can be delayed, and `didResignActiveNotification` follows actual relinquishing of active status to another app:

- https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:)
- https://developer.apple.com/documentation/appkit/nsapplication/didresignactivenotification
- https://developer.apple.com/documentation/appkit/nsapplication/deactivate()

**Not established:** whether this particular pause blocked inside `NSApp.deactivate()`/the RPC, waited for a notification after the reply, or involved another native focus/event-loop race. The screenshot and existing log cannot distinguish those paths. No general app deadlock or pane-movement regression is proven. `eventually` has a 15-second deadline, but its condition performs an RPC with a separate 35-second socket timeout, so the polling deadline is not a strict end-to-end step bound.

## Recommended correction and bounded next check

1. Separate deterministic lifecycle-handler coverage from real OS-focus integration. Drive the actual resignation observer/cancellation path in an owned native fixture (a synthetic notification proves handler behavior, **not** OS deactivation). Keep one optional real-focus test, using an explicitly owned helper app as the receiver; do not activate arbitrary user apps.
2. In that optional test, confirm the starting active/key/selected state, request the transition, then confirm the actual notification and resulting state. Do not hide focus failure by calling `cancelForLifecycle` as a fallback or repeatedly stealing focus until a test passes.
3. Log each focus-sensitive step, elapsed time, `NSApp.isActive`, owner/sheet key state, selected tab, attached sheet and will/did-resign notification counts. Bound RPC deadlines by the remaining step deadline. A stalled test should produce diagnostics rather than look like it is awaiting human input.
4. The next useful reproducer is only **open sheet → deactivate → observe cancellation → reactivate/confirm key state**, not the entire tab-title or desktop suite. If it stalls, capture a short sample of the owned app's main thread before changing focus, and compare with the event trace after the app switch. This distinguishes an in-call block from a missing focus event or delayed activation.

Investigation was read-only apart from this note. No test suite, build, new GUI run, focus manipulation or process termination was performed. The concurrent tab-renaming implementation/test files were preserved; the cross-window integration was checked separately without rerunning its suite.
