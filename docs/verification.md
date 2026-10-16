# Verification

The complete gate is `bash scripts/verify-all.sh`, equivalent to `python3 scripts/verify-vm.py --all`. The shared inventory in `scripts/verification_gates.py` contains **79 invocations**: six host build/unit/static checks and 73 sequential VM checks, including all 19 native recipes and three app iterations. Select individual gates with `python3 scripts/verify-vm.py --list` and `python3 scripts/verify-vm.py terminal browser`. Compile on the host; never execute GUI gates there or compile in the guest. See [VM testing](vm-testing.md) for setup and commands.

Per-run source/binary receipts and gate statuses are retained under `artifacts/vm/`. `artifacts/verification.json` and `verification-checks.txt` are published **only after the entire inventory passes**, artifacts are retrieved, teardown is confirmed and sources/binaries still match. A stale manifest or historical evidence below does not certify newer edits.

## Tab renaming worktree

`scripts/verify-tab-titles.py` is a focused owned-app production-API gate, registered in `verify-all.sh` and automatically included in the source manifest. It checks native Rename/Reset discovery and editor interaction, shared CLI/page/service set/clear and attribution, validation/stale targets/guards, title-only facts, no-op failed-save recovery, actual `NSWindow.title`, background focus/session retention, saved-layout capture/open and restart restoration. `TabTitleTests` and `TabTitleCLITests` cover model/schema/command invariants and typed CLI routing. Final selected batch `bg_ce66195101cfbf33` exited 0: **282 package tests**, Debug app/CLI/helper build, Python syntax/whitespace, the tab-title integration gate and existing workspace-persistence gate. Actual outputs are `artifacts/tab-title-final-{unit-tests,build,integration,persistence}.log`; `artifacts/verification.json` binds these five checks to unchanged sources and binaries. The manifest now includes shipped skill Markdown. No new full-suite certification is claimed.

Independent code review's repeat-native-menu finding was fixed and re-reviewed. Independent rendered review found no issues in light/dark sheets, overlength validation, long Japanese labels and a single-tab window. Manual clipboard/IME, VoiceOver, fullscreen/multi-display, physical tab dragging and native overview remain unverified. The original checkout's pending overview fixture is not part of this isolated baseline. The final editor-active guard after native synchronization was reviewed and rebuilt; its rare late-import cancellation path was not independently reproduced.

The automatic tab-rename deactivation case was subsequently removed at the user's request because it depended on uncontrolled desktop focus; its unused debug deactivation hook was removed too. Production lifecycle cancellation and the rest of the gate remain. No suite/build was rerun for this removal, and the separate later key-window timeout is not claimed fixed. See [investigation](bugs/tab-rename-focus-test-stall.md).

## Notifications v1 — focused worktree verification

Main integration against `60118b5` preserves the newer tab-title, cross-window pane, overview and Settings-close changes. Native tab badges now compose with manual names and rename updates; tab-scoped plugin recreation retires notification identity but retained cross-window moves do not. Explicit source navigation releases an active tab-rename sheet before focusing the source. The notification gate now also checks rename/badge composition. The combined main native app, CLI and layout helper compile successfully in task-owned build directories. Diff/conflict/whitespace, Python AST/shell syntax and preservation checks also passed: 343 non-notification files stayed unchanged, and removing the notification additions/adapters recovers the original main contents of all 22 overlapping tracked files exactly. Evidence: `artifacts/notifications-main-{cli-build,app-build}.log`, `notifications-main-integration.json` and `.git/integration-backups/notifications-k1f1w9ju/preservation.json`. The full test suite and owned notification fixture were not rerun on main, per the integration request; no new runtime/visual certification is implied. All historical evidence paths in this subsection refer to the notification feature worktree, not main's artifacts or binary.

Implemented in `~/.worktrees/local/slate-term-a42fd7a1/notifications` on `feature/notifications`, based on `6fca12b`; the original checkout was not edited. Final selected checks passed: **282 package tests** (179 core, 22 IPC, 76 settings, 5 CLI), native app/CLI/helper build and local signing, the owned notification fixture, and whitespace. `artifacts/verification.json` records exactly these four checks and unchanged source/binary hashes. This is **not** a full `verify-all.sh` result or a fresh Ghostty engine build; the existing framework/resources were copied into the isolated worktree.

Evidence: `artifacts/notifications-unit-tests.log`, `notifications-build.log`, `app-build.log`, `notifications-integration.log`, `notifications-toolchain.txt` and `verification.json`. The fixture covers API validation/coalescing, CLI launching-session guards, registered-page/service parity and native provenance, real Ghostty duration/failure completion and OSC 9/777 callbacks, no duplicate shell-report notification, permission/submission failure states, 40 concurrent status requests sharing one authorization inspection, source replacement during an authorization wait, unread indicators (including hidden pane bars), source open/next and stale-source rejection. Permission UI captures cover Allowed and Not requested without prompting the user's OS.

Independent code review identified status-query concurrency and tab/app rate-bucket collisions; both were fixed, with follow-up static review finding no actionable issues in the fixes or state-root/epoch cleanup isolation. Independent visual review identified a contradictory permission request action while already authorized; the action now appears only for Not requested. Fresh retained-view captures show the corrected states. Cached renders also show native sidebar-selection/tab-corner artifacts that were absent in an earlier full compositor capture of the unchanged sidebar/tab styling; no production style workaround was applied to compensate for the cache renderer.

**Native/visual limits:** integration uses a deterministic notification-delivery adapter, not real Notification Center. Actual OS permission interaction, banners, sounds, delegate callback/late-add ordering, lock screen and Focus behavior remain unverified. macOS did not reliably activate the owned source window, so real foreground suppression is explicitly unverified despite passing pure policy checks and model source navigation. Final composited captures were thumbnails; full-size AppKit view evidence is saved separately as `notifications-{tabs,settings-light,settings-dark,settings-permission-request}-view.png`. The final live compositor/sidebar/tab appearance is not certified. Earlier full-size compositor images were inspected during the session but are not the final capture artifacts. Physical mouse/VoiceOver/shortcut and broader desktop regression checks were not run.

One intermediate build failed while Xcode/SDK files were being replaced. After confirming the headers were present, only this task's derived data was moved to `artifacts/notifications-derived-before-sdk-refresh`, and a fresh Xcode 27.1 build passed. Existing AppIntents/dependency-scan/AppearanceAPI warnings and CoreSimulator-version diagnostics remain; this is not a warning-free build claim. No merge, push, publish or deployment was performed.

## Build diagnostics and literal text checking

The warning-cleanup worktree records its native build and Swift test results in `artifacts/warnings-verified-build-driver.log`, `artifacts/app-build.log`, and `artifacts/warnings-verified-swift-tests.log`; these focused checks do not certify the full suite.

Eight captured Hang Risk reports share UUID-matched system frames through `NSConditionLock`, AppKit's data-detector scanner, pending text checking, and `NSTextView.resignFirstResponder`. The command query, pane rename, and browser address fields now disable automatic text checking while setting up their shared field editor. No global preferences or WebKit page editors are changed. Old app-frame UUIDs no longer match the current binary, so the exact originating controls remain unconfirmed; the mitigation is not a long-use hang-free guarantee.

`bash scripts/verify-text-checking.sh` exercises actual editing and focus resignation without showing windows. It explicitly enables inherited data/link detection first, then requires the literal field/search controls to disable checking before editing and commit Unicode input unchanged. Removing the policy makes this regression fail. The native pane-title fixture also waits for real queued outside-click dispatch rather than assuming immediate popover dismissal.

## Latest picker and header-button revision

The complete sequential suite passed on **2026-10-14 at 13:36:08 UTC**: **37 gates**, including **120 Swift tests** (70 core, 8 IPC, 42 settings). Evidence: `artifacts/header-buttons-full-suite.log`, `artifacts/header-buttons-final-targeted.log`, and `artifacts/verification.json`. All recorded source and executable hashes matched the working tree/binaries when rechecked after completion.

The native picker gate covers window attachment, centered placement and compact resizing, tiny-owner dismissal, owner-close observer cleanup, two-click execution (including ordinary delayed clicks and double clicks), keyboard execution, hidden unavailable actions, captured targets, title-edit cancellation, and copy-ID. The menu gate verifies Copy Pane ID's intentionally empty default binding and actual custom-shortcut dispatch without changing layout/focus or using the user's clipboard.

Header-button checks cover all/built-in/widget type selectors, clicked-pane routing across focus/window changes, direct and overflow dispatch, disabled busy actions, persistence, live replacement/removal, unregister cancellation, and no hidden service. The native header fixture also verifies that unchanged/unrelated refreshes preserve valid menu actions while registration replacement invalidates stale ones.

Independent rendered review found no visible issues in the inspected regular/compact light/dark picker states or normal/narrow contributed headers. Full manual VoiceOver/IME, multi-display/offscreen-window and soak testing remain release limitations. Concurrent unrelated work was preserved.

## Command-plugin and picker follow-ups

Before the subsequent picker-interaction/header-button revision, the complete sequential suite passed on **2026-10-14 at 12:19:53 UTC**: **36 gates**, including **118 Swift tests** (68 core, 8 IPC, 42 settings). Evidence: `artifacts/followups-full-suite.log` and `artifacts/verification.json`. The recorded source hashes and both executable hashes were rechecked after completion; all matched. The whole-project checkpoint before the picker/audits is `1f80bde`; the verification manifest records the tested source and binary contents independently of commit boundaries.

Native checks cover command-only/mixed plugins, command supervision/routing/settings, and the real Liquid Glass picker, including text input, keyboard/mouse execution, live catalog/busy states, frozen and windowless context, original editor cancellation, shortcut alternatives, and light/dark/context captures. Independent code reviews led to routing, lifetime, and focus corrections. Final independent visual review of all nine picker captures found no visible issues; it did not independently execute the full test suite.

The first complete run exposed an existing pane-title fixture expecting trailing spaces even though `Workspace.setManualTitle` trims them. The assertion now checks that established normalization contract; the focused pane-title gate and subsequent complete run passed. No product title behavior was changed for that test correction.

Full manual accessibility/IME, multi-display, and soak verification remain release limitations, not checks claimed by this run.

## Earlier verification

**Earlier full-suite checkpoint:** the expanded combined run passed on **2026-10-14 at 07:41:31 UTC** (`artifacts/complete-verification.log`), all **25 gates**, including **77 Swift tests** (53 core, 8 IPC, 16 settings) and three regression mutants. All **94 source hashes and 2 executable hashes** were rechecked against the working tree, including by an independent reviewer. This establishes the automated coverage below, not release certification or manual/platform coverage. [Historical evidence](verification-history.md) retains the earlier terminal/configuration slice.

## Subsequent menu and close-warning changes

The menu/close-warning work has its own native gate, `python3 scripts/verify-menu-ui.py`, now included in `verify-all.sh`. It verifies submenu organization, visible shortcuts, actual key dispatch, removal of the disabled switching note, native alert cancellation/consent, restart persistence, reset, quit checks, and unchanged CLI `--force` safeguards. It captures the actual menus and alert in `artifacts/*-menu.png` and `artifacts/close-warning.png`.

`menu-shortcuts-red.log` records the missing-default-shortcuts regression. Model/build/native gate and affected regression logs use the `menu-` prefix. Subsequent menu and Settings work changes source hashes; the earlier combined manifest does **not** certify the current working tree. Cursor rectangles use AppKit's pointing-hand cursor; the native gate does not move the user's physical mouse to verify hovering.

## Automated checks

| Gate | Actual coverage |
| --- | --- |
| `build-ghostty.sh` | Pinned full Ghostty engine and checksum-verified local Zig toolchain |
| `verify-model.sh` | Workspace topology/IDs/focus/zoom/equalization, protocol, actual sockets, shell/event/browser input contracts, TOML/watchers, private state/catalog/storage |
| `verify-model-mutations.py` | Deliberate regressions rejected by assertions |
| `verify-notifications.py` | Owned notification policy/API/CLI/page/service, real engine completion and OSC, authorization-query coalescing, lifetime race, unread/navigation and Settings captures; deterministic delivery backend, not real OS delivery |
| `verify-text-checking.sh` | Headless shared field-editor reuse, inherited detector flags disabled before editing, Unicode input preserved on focus resignation |
| `verify-tab-overview.sh` | Production WorkspaceWindow with two owned native tabs: actual Show All Tabs context-menu dispatch, toggle close, Escape, reopen and thumbnail selection without changing membership |
| `verify-terminal-keys.sh` | 74 physical SDK mappings × 8 modifier sets, parsing and byte bounds |
| `verify-terminal-runs.sh` | Unique command markers, quoting, one-shot shell input claims, draft refusal, sequences, UTF-8 output bounds, deadlines/cancellation/replacement/capacity |
| `verify-event-hub.sh` | Real suspension, replay/filtering, cursor advancement, cancellation, close, overload and deadline races |
| `verify-event-efficiency.sh` | Window-free real storage/configuration/libghostty metadata checks; no-op suppression, completion preservation, engine rollback/custom palette reload; Node theme single-flight/trailing refresh and failure recovery |
| `verify-plugin-process.sh` | Actual executable/cwd/environment, bounded logs, exit/reaping, TERM/KILL and owned-group cleanup |
| `verify-plugin-listener.sh` | Real socket/process-group ownership and rejection of unrelated listeners |
| `verify-process-titles.sh` | Kernel-only process attribution against real owned PTYs and foreground jobs |
| `verify-terminal.sh` | Real Metal/libghostty PTY output, resize/reparent/native tabs without shell replacement, IME commit, clipboard consent, secure-input ownership, mouse, Kitty key press/release, application-cursor keys, Ctrl-C and child cleanup |
| `build-app.sh` | Explicit SlateTermApp target, bundled CLI/resources/terminfo and development-only ad hoc signature |
| `verify-plugin-worker.py` | Actual bundled group supervisor and cleanup after GUI death |
| `verify-app.py` ×3 | CLI drives actual native tabs/splits/focus/dividers, layout geometry, stable surfaces, terminfo, isolated tmux compatibility and shell closure |
| `verify-config-cli.py` | Offline configuration validation |
| `verify-settings.py` | Live reload, native shortcuts, last-valid retention, tab reorder persistence, writer lease, restart and corruption recovery |
| `verify-settings-window.py` | Native Settings navigation, shortcut recording/reset/conflicts, persistence, validation and captures |
| `verify-settings-layout-close.py` | One owned app: Settings close/⌘W, all-selection Cancel/Discard/Save All, failure recovery, no stale draft prompts, no layout quit prompt and retained running-process quit protection |
| `verify-saved-layouts.py` | Settings-embedded recipe editor, library repair/drafts/conflicts, tab model/drop operations and renumbering, per-template palette refresh/execution, focused plugin reload across CLI/page/service, new-window-only opening, startup/session ownership, launcher packaging and light/dark/narrow/AI Agents captures |
| `verify-command-picker.py` | Centered native Liquid Glass, search/text input, keyboard/two-click execution, shortcut dismissal with frozen targets, rename command, contextual maximize/restore labels, Settings Cmd-W, hidden unavailable actions, stock copy-ID command, live catalog, focus/routing, shortcuts, windowless use and light/dark/context captures |
| `verify-plugin-header-buttons.py` | Manifest all/built-in/widget selectors, clicked-pane routing, direct/overflow actions, busy state, no hidden service, persistence, replacement/removal and light/dark/narrow renders |
| `verify-window-recovery.py` | Empty saved workspace opens a terminal without resetting IDs, windowless ⌘N/⌘T, creation from Settings, and idempotent Dock reopening |
| `verify-appearance.py` | Light/dark/auto, original palette choices, rendering-option translation, Settings/TOML persistence, invalid-edit retention, unchanged live PTY, and native settings/terminal captures |
| `verify-palettes.py` | All 25 bundled palettes in both modes, names-only custom imports, collision-safe copies, path rejection, custom rendering/snapshots, CLI/UI validation, explicit reload, and safe startup fallback |
| `verify-shell.py` | Production zsh with isolated startup/history, executable quoting, PATH, Unicode and OSC 133 integration |
| `verify-browser-navigation.sh` | WebKit (one non-activating window per browser mode for media source selection): delayed welcome/recipe callbacks, RPC/page supersession, cancellation and platform capacity, immediate HTTP navigation, document identity/history restoration; local HTML with relative CSS/JS/PNG/H.264 MP4, standalone PNG/MP4 decoding, local links/popups, native address/recipe loading and bridge absence in Browser and Private Browser (requires a fresh CLI/package build) |
| `verify-service-commands.sh` | Window-free command ownership/environment, retirement and descendant cleanup; deferred pane-transfer launch and post-lifecycle/pre-spawn validation; already-running survival; repeated header-equivalent commands with balanced lifecycle/busy-state notifications |
| `verify-cross-window-pane-movement.py` | One owned app: socket/CLI/page/service/native callbacks/menu cross-window parity, empty source closure, terminal/session/browser identity, inherited CLI routing, plugin scope/reused destination storage, atomic publication rejection and inherited event-poll transfer. Captures changed menu/preview; does not synthesize a hardware drag session. |
| `verify-browser.py` | Actual owned HTTP fixture, WebKit navigation/evaluation/screenshots, isolated stores, DOM actions, stale/BFCache references, clipping, refusal paths and absence of plugin privileges |
| `verify-web.py` | Shared browser/plugin CLI/page API; inactive-native-tab PNG pixel freshness and unchanged selection/focus; DOM visibility; invalid-layout/zoom/unready/replaced/closed capture rejection; navigation/ref/cancellation/capacity checks |
| `verify-web-operations.sh` | Window-free operation accounting and controlled snapshot callbacks: revalidation before output, cancellation/navigation/closure suppress late writes, existing output preserved on failure |
| `verify-background-services.py` / `trusted_api_fixture.py` | Shared CLI/page/service discovery and dispatch, including inactive-tab browser/plugin screenshots and zoom/DOM visibility rejection, alongside owned service lifecycle checks |
| `verify-context.py` | Authenticated zsh prompt/running/cwd/status, pane headers, generic run/wait, unfinished-draft refusal, disconnect cleanup, scoped targeting, replacement and unknown-state refusal |
| `verify-plugins.py` | Actual ES modules, isolated bridge and frame/document boundaries, scoped storage/events/input, aborts, registration/unregister transactions, restoration and header controls |
| `verify-plugin-services.py` | Real readiness/listener ownership, restart coalescing, bounded restart/logging, process death, scopes and cached-history bridge recovery |
| `verify-plugin-commands.py` | Headless/mixed manifests, discovery, CLI and page commands, scoped routing, shortcuts/settings, exit reports, bounded output, timeouts, duplicate rejection, disconnect/unregister cleanup, persistence and app-crash supervision |
| `verify-events.py` | Public IPC replay/streaming/filtering, native provenance, bounded payloads, disconnect cancellation and explicit restart resynchronization |
| `verify-extension-interop.py` | Managed backend discovery/environment, real engine key input, extension-owned private tmux inspection, screen capture, directed context and stale-session rejection |

## Recent red → green evidence

Earlier feature logs remain under ignored `artifacts/`. Representative regressions include:

- `extension-interop-red.log`, `extension-session-red.log`: missing backend discovery/session guards, followed by working public CLI/IPC extension interoperability.
- `browser-actions-red.log`: missing DOM API. `browser-actions-green.log`: named content worlds were not retained between calls; retaining the world made the native DOM actions pass.
- `browser-truncation-unit-red.log`: the production snapshot script failed to flag a clipped single text node; the native browser gate also checks this case.
- `terminal-run-native-red.log`: missing run/wait commands, followed by real-zsh completion/exit status/timeout tests.
- `run-draft-red.log`: a nonempty ZLE draft was submitted by the original run implementation. Delivery now goes through an authenticated, one-shot shell widget which checks the editing buffer before accepting a command. `run-continuation-red.log` additionally reproduced execution of earlier continuation lines; `PREBUFFER` and primary-prompt checks now refuse that case, verified by `run-continuation-green.log` and the final context gate.
- `terminal-keys-native-red.log`: missing named-key CLI; real extension interoperability subsequently passed. `terminal-keys-protocol-isolated.log` proves exact PTY bytes for Kitty press/release and legacy application-cursor/control keys.
- Plugin screenshot-size failures exposed transformed thumbnail captures. Tests activate/restore only their owned window and require stable full-sized pixels rather than accepting the thumbnail.
- Secure-input fixture checks now establish an explicit baseline: `stty -echo` can itself make Ghostty request secure input. Tests inspect successfully balanced process-owned Carbon calls, not an unstable global baseline shared with other apps.

Independent automation review identified unfinished-draft submission (including continuation prompts), inherited pane IDs overriding an explicit CLI scope, and omitted empty/plaintext contenteditable controls. Corrections have dedicated regressions. Fresh independent read-only verification found no remaining actionable defects in those changes and verified the final source/binary hashes. That reviewer inspected outputs; it did not independently rerun the suite.

Independent visual review of the final `plugin-workspace.png` and `browser-workspace.png` found no visible issues in hierarchy, typography, spacing, pane headers, right-edge close controls, clipping or rendering. This covers those desktop states, not all layouts or live behavior.

One pre-final first-start context check timed out before diagnostic capture was added; its cause remains unconfirmed. The diagnostic rerun, continuation regression and expanded final suite passed. The later passes are not a claimed root-cause fix for that isolated timeout.

## Ownership and environment

Apple Silicon, macOS 27 and Xcode/Swift 6.2+ with the Metal toolchain. The app's existing macOS 27 target, user bundle ID and signing configuration are preserved. Nothing is globally installed, pushed, published, deployed or notarized.

GUI checks own their windows, temporary state/configuration, shell startup/history, Unix sockets, HTTP fixtures and process groups. Tmux checks use private test servers, never user sessions. Test-mode application windows ignore physical keyboard input; scripted input still follows the tested dispatch path. They may activate their windows, so concurrent mouse/focus interaction can still interfere. Native captures fail if permission or a usable GUI session is unavailable. Tests use real readiness conditions and hard failure deadlines, not sleep-based success.

## Remaining release/manual verification

These are explicit coverage/support limits, not placeholders replacing implemented features:

- Manual Japanese/Korean/dead-key IME behavior, trackpad/pressure behavior, keyboard-layout variety and a full VoiceOver/accessibility audit.
- Extended daily-use/soak, sustained hostile/slow-reader load, and an actual different-UID peer rejection test.
- Older macOS versions and Intel are not supported by this verification; the current project targets macOS 27.
- Workspace restoration restores topology/types/identity/focus, not PTY continuity, output, cwd, web history or window geometry. Atomic file replacement is not power-loss durability.
- Trusted plugin process groups do not contain deliberate daemonization; static asset containment is not a sandbox against a trusted owner concurrently replacing filesystem paths.
- Browser automation limitations and terminal output/completion semantics are documented in [automation](automation.md). Neither unknown shell state nor synthetic DOM input is presented as a stronger guarantee.
- Distribution signing/notarization/release publishing is not performed without separate authorization.
