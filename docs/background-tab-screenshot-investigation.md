# Background-tab screenshot investigation

> Historical investigation at base `e2e5ece`, before the implementation follow-up in this worktree. The findings below explain the design choice; current canonical API behavior is documented in [automation](automation.md#shared-web-panes), with follow-up verification tracked in [API progress](api-extension-progress.md). Statements below about unchanged production code describe the investigation, not the later implementation.

## Conclusion

Capturing an existing, attached WKWebView in an inactive native tab is feasible on the tested system. The unchanged `WebPaneAutomation.screenshot` implementation returned fresh CSS, text and 2D-canvas content without selecting the target tab, changing the key window or changing first responders. No offscreen host, reparenting, page duplication or custom snapshot configuration was needed.

This is a bounded rendering probe, **not a shipped API capability**. Canonical `web.screenshot` still rejects inactive tabs. No production source was changed.

## Reproduction and evidence

Worktree: `~/.worktrees/<owner>/<repo>/background-tab-screenshot-probe`

Branch: `investigate/background-tab-screenshots`

Base: `e2e5ecee1bef74027458acc52f124b36e0947ca4`

Run from the worktree:

```sh
bash scripts/probe-background-snapshots.sh
```

The script compiles Core and the unchanged `Native/BrowserAutomation.swift` / `Native/WebPaneAutomation.swift`, then runs `Tests/BackgroundSnapshotProbe/BackgroundSnapshotProbe.swift`. It opens two owned native tabs, briefly activates the probe, and closes its windows on completion. The process has a 90-second runtime limit. It does not launch Slate, touch its state, or run the window-heavy integration suite. The script is investigation-only and is deliberately not added to `verify-all.sh`.

Final artifacts (gitignored):

- `artifacts/background-snapshot-probe/results.json`: per-capture DOM/native state, RGB samples, dimensions, timing and focus checks.
- `artifacts/background-snapshot-probe/*.png`: eight screenshots.
- `artifacts/background-snapshot-probe/build-manifest.txt`: revision, toolchain, OS and compiled source hashes.
- `artifacts/background-snapshot-probe/run.log`: final successful run.

Test system: Apple Silicon, macOS **27.0 (26A428)**, Swift **6.4**. This is evidence for this OS/WebKit build, not a compatibility guarantee for other supported macOS versions.

### Fixture and results

Two fixtures use the same shared capture implementation:

1. Browser-like: `loadHTMLString` with an HTTPS base URL and an ephemeral data store. No real HTTP/network load is exercised.
2. Plugin-like: a custom `plugin://probe/index.html` scheme handler and an ephemeral data store. This exercises a local-scheme document, **not** the actual `PluginPane`, registered bridge, origin admission or plugin process lifecycle.

For each fixture: capture a visible red page; select the other native tab and focus its text field; change the hidden document to green; capture immediately; wait two seconds, change it to blue and capture again; finally select the target and capture a visible blue reference.

| Fixture | Visible red | Inactive green | Inactive blue | Visible blue reference |
| --- | --- | --- | --- | --- |
| Browser-like | Pass | Pass | Pass | Pass |
| Plugin scheme | Pass | Pass | Pass | Pass |

All eight PNGs were **1280 × 888** pixels, from **640 × 444** point web-view bounds. All **40 sampled patches** matched the intended RGB values exactly: four background locations plus the canvas center per image. Representative green/blue PNGs were also opened and visually inspected; their text showed the new hidden phase.

All four background captures recorded:

- Target attached to its original window, with nonzero unchanged bounds.
- Target native tab unselected before and after capture.
- `document.visibilityState == "hidden"` and no visible occlusion state before and after capture.
- Another tab actually key, with a first responder, in the final run.
- Selected native window, app key window, key-window first responder and selected-window first responder unchanged across capture.
- The existing automation document identity remained unchanged across the hidden captures.

Background capture plus PNG conversion/write took approximately **12–18 ms** in this fixture. This is not a performance benchmark.

### Probe corrections

The first build needed a Swift fixture access-control fix. Early runs then exposed problems in the test assertions, not stale screenshots: `NSBitmapImageRep.colorAt` returned calibrated RGB values despite an sRGB PNG, so converting those values again changed the expected RGB numbers. The final probe checks the encoded 8-bit RGB samples directly. A separate strict key-window admission assertion was also unreliable during tab activation; the final probe lets AppKit settle, records actual key state, and checks both selected-window and key-window responder identity across each capture. Every final capture did have a key selected window.

Earlier artifacts remain under `artifacts/background-snapshot-probe-initial/` and `artifacts/background-snapshot-probe-focus-attempt/`; they are not the final passing evidence.

## Connection to production code

- `Native/WorkspaceHost.swift`: retains browser/plugin leaf controllers and native windows for all live tabs, and builds their layouts. Switching native tab selection does not normally recreate the WKWebView. Zoom is different: it may detach non-zoomed pane containers.
- `Native/WorkspaceAPI.swift`, `inspectPane`: an unselected native tab is reported `visible: false`, and its geometry is unavailable.
- `Native/WebAPI.swift`, `webRenderable` / `callWeb`: canonical screenshot admission requires visible, sampled geometry plus ready document/origin state. The same validation is called before asynchronous work and before writing the PNG. This blocks background capture before WebKit is asked to render.
- `Native/WebPaneAutomation.swift`, `screenshot`: calls `web.takeSnapshot(with: nil)`, converts to PNG and writes atomically, retaining the existing bounded operation/cancellation accounting. This exact implementation was compiled into the probe.
- Both browser and registered-plugin adapters compose this shared implementation.

An important compatibility distinction: legacy `browser.screenshot` dispatch in `WorkspaceHost.swift` checks caller/target guards but does **not** call the canonical `webRenderable` gate. The previous blanket statement that every browser screenshot route rejects inactive tabs was too broad. Its rendering path looks capable of the tested behavior, but the legacy RPC itself was not exercised here. It does not provide a plugin screenshot route.

## Smallest production follow-up

1. Add screenshot-specific eligibility in the shared host path, separate from `webRenderable`. Allow a ready, retained, attached web view in an inactive native tab, with valid nonzero bounds and a settled owner-tab layout. Preserve plugin-origin/readiness, caller liveness and target/document guards. Do not loosen DOM mutation admission.
2. Keep `pane.inspect.visible` and on-screen geometry truthful. A screenshot-capable background view is still not visible. If readiness is exposed, distinguish capture eligibility from display visibility rather than fabricating geometry.
3. Initially restrict support to attached, laid-out panes. Continue rejecting zoom-detached panes, invalid/pending layout, closed/replaced views and unsupported window states. Do not add hidden membership or hide/show APIs.
4. Preserve the current snapshot implementation first. Define capture viewport metadata and behavior when bounds, layout, ownership or document change during the asynchronous operation; revalidate before output. Preserve cancellation, deadlines and submission limits. No silent tab activation or stale cached-image fallback.
5. Update shared discovery/docs and add actual host integration coverage through CLI/socket and registered-plugin/service clients, including lifecycle/resize races and unchanged foreground focus. Explicitly reconcile/document the legacy browser screenshot semantics.

## Unverified boundaries

No full Slate host/plugin bridge integration, network-loaded browser document, never-rendered tab, hidden navigation, detached/zoomed pane, minimized window, long suspension, animation scheduling, video/WebGL, protected content, full-page capture, terminal/native-panel capture, or older-OS coverage was performed. Synchronous CSS/text/canvas mutations while hidden were tested; this does not make throttled timers or requestAnimationFrame run as if visible.

All edits are confined to this worktree's probe, runner and report. Production `Native/` and `Sources/` remain identical to its base. The original checkout was only inspected; it was concurrently receiving unrelated changes, so its changing aggregate diff hash is not an isolation assertion. No original files were edited, no commits were made, and nothing was pushed or published.
