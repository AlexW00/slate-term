# Changelog

Detailed change record for agents and maintainers. Public release notes live in `docs/releases/`.

## Unreleased

### Added

### Changed

### Fixed

### Internal

## 0.9.0 — Pending publication

### Added

- Add New Window to the Dock context menu, including when all workspace windows are closed.

### Changed

- Replace the website’s pane-type bento with concrete custom-view examples: a live dashboard, release notes, and a review queue.

### Fixed

- Fade the blurred hero preview at its bottom edge and match gallery artwork scaling to its responsive frame.

- Restore all four pane-move drop targets over plugin and browser content; embedded WebKit views no longer intercept pane drags.

- Give the original foreground terminal job a bounded Ctrl-C exit opportunity before hangup and forced shutdown. Preserve its final recovery output without repeating overlapping transcript snapshots.

### Internal

- Retain the browser authentication investigation as a dated source snapshot, identifying popup findings superseded by 0.8.0. Password AutoFill, passkey eligibility and live provider compatibility remain unverified.
- Save Xcode project serialization updates for the private runtime targets and build phase.

- Integrated committed development through `b12cd46`, including Dock New Window, pane drag targets, graceful terminal shutdown, website refinements, authentication documentation and Xcode project serialization. Preserved the public updater, signing, source packaging and release tooling.

- Release preflight passed the full-history secret scan, 120 release-tooling tests (four optional official-tool tests skipped), 72 VM-runner tests and workflow validation. Committed development passed 549 package tests and a native build. Pane movement and terminal recovery VM gates passed; the menu gate encountered a locked display and awaits an unlocked rerun. Candidate installation and production upgrade evidence remain pending.

## 0.8.0 — 2026-10-20

### Added

- Browser downloads use native save panels with progress and cancellation, a Downloads toolbar control and command, and shared trusted API/CLI operations. Transfers retain WebKit session handling and never overwrite existing destinations.
- Browser and registered-plugin pages support native JavaScript alert, confirm and prompt dialogs. Shared dialog inspection and single-use response APIs complete the same native requests.
- Browser popup windows preserve their opener and WebKit configuration, including private sessions. Trusted clients list, inspect, operate and close popup views using an owning pane and explicit popup ID; closure cleans up descendants.

- Native file upload pickers in browser and registered-plugin panes, with shared inspect/select/cancel APIs and CLI helpers.

### Changed

- Name the Cmd-R browser action “Refresh Browser” so it is discoverable by refresh in Cmd-K.

- Keep previous terminal output in restored scrollback; remove its separate viewer, pane-header button, Show/Clear commands, and history-read/export APIs.

### Fixed

### Internal

- Browser integration passed 547 package tests, 72 VM-runner tests, selected native VM gates, and a 2,486-response shared API audit. Native input verified upload selection/cancellation, download saving and popup login completion. Independent source and native-control visual reviews found no actionable issues. The VM's pre-existing WebKit IOSurface issue still prevents default native page-content visual verification; CPU snapshots are separate evidence.
- Integrated development through `6deac80`, including removal of the separate previous-output viewer. Preserved public updater, signing and release tooling. Candidate DMG installation and production upgrade verification are recorded separately below.
- The integrated public candidate passed 548 package tests, release preflight (120 release-tooling tests, four optional tool tests skipped), 72 VM-runner tests, the history secret scan and workflow validation. A process-only software drawing diagnostic restored visible popup content in the affected VM; native mouse completion and independent rendered review passed without changing application source or persistent preferences.

- Published build 9 from `f25b00c` after successful tag CI and Release workflows. Signed artifact and anonymous public checks passed for source, checksums, feed/archive/notes signatures, Apple signatures, notarization and installer alias equality. The actual DMG-installed app passed web, browser and command-picker gates; its 826 captured responses passed the shared catalog audit. Independent native-control visual review found no defects within the documented VM rendering limitation. A real 0.7.0 production Sparkle upgrade accepted native download/install clicks, relaunched the exact signed 0.8.0 app, and preserved workspace structure, configuration and saved terminal output. Temporary VM launch settings were restored and the owned fixture cleaned up.

## 0.7.0 — 2026-10-20

### Added

- Restore Original Layout in layout apps through the command picker, CLI, and shared API, with guarded replacement of the current workspace.

### Changed

- Rename Create Layout App to Create App, preview the chosen icon, and choose the app name and destination in a native save dialog.
- Let layout apps enable or disable inherited plugins independently, preserving local choices through parent synchronization.
- Replace stored-site selection with a trash button per row and a Clear All Site Data action.

- Restore saved terminal output directly into each pane's scrollback above the new shell prompt. Move output retention to General and show it only when workspace restoration is enabled.

### Fixed

- Disable layout mutation controls in layout-app Settings while retaining tab and pane inspection.
- Place browser agent indicators closer to the status strip.

- Prevent sideways page scrolling on the website by clipping the scaled hero glow at its section. WebKit checks passed at nine widths from 320 to 1440 pixels in both themes and five scroll positions; sticky navigation and gallery scrolling remain functional. Physical mobile touch behavior was not tested.

- Release finalization discovers draft candidates through authenticated release listings, including later pages, because GitHub’s tag endpoint excludes drafts. Verified by 23 helper tests and the completed 0.6.0 publication.

### Internal

- Clarify agent identity flag placement and require verified presence holds for multi-step pane work in the bundled Slate skill.
- Qualify layout-app polish with 540 package tests, 72 VM-runner tests, selected native gates and shared API response audits. Real VMPal input verifies save-panel acceptance, stale-source rejection and destination collisions.

- Integrated committed development through `4ba65db`, including inline terminal-output restoration and layout-app polish. Preserved public updater, signing, source-packaging and release tooling. Selected development native checks are recorded separately from candidate installation and production upgrade checks.
- The integrated public candidate passed 541 package tests, a native build, the full-history secret scan, workflow validation, and 72 VM-runner tests. Release preflight ran 120 tooling tests with four optional official-tool tests skipped; actual artifact signing and verification remain pipeline checks.

- Published build 8 from `7b9ac7a` after successful tag CI and Release workflows. Downloaded and anonymous public verification passed checksums, matching source, signed feed/archive/notes, Apple signatures, notarization tickets, and installer alias equality. The actual DMG-installed app passed the native layout-app UI gate. A real production Sparkle upgrade from 0.6.0 displayed the signed notes, accepted native download/install actions, relaunched as 0.7.0, and preserved workspace structure and saved terminal output. Evidence is retained in the release finalizer receipts and native release artifacts; this is selected verification, not a full native-suite certificate.

## 0.6.0 — 2026-10-20

### Added

- Saved layouts can create independent macOS apps with their own sessions, browser profiles, and plugin data. Settings and installed plugins follow Slate, with local setting overrides.
- Layout app management is available in Settings and through `layout-apps list` and guarded `layout-apps refresh`.

- Configure agent accent colors in AI Agents settings and through `agents.colors`, including custom actor families, reset/remove controls, and live updates to existing indicators.
- Save configurable previous terminal output across relaunch, with a read-only history viewer and bounded attached-process shutdown.

### Changed

- Native implementation, helpers, and resources now live in a private signed runtime. Generated apps keep a stable shell while stopped-app runtime updates preserve its signing identity.

- Remove pane-dimming slider ticks and its Apply guidance.
- Use a GitHub navigation button while retaining the website’s Star on GitHub text links; swap the panel-type and agent-activity bento cards.


### Fixed

- Generated-app creation and updates run expensive work away from the UI thread. Runtime refresh and restart preserve shell identity, wait for verified process cleanup, and retain private workspace data.
- Plugin synchronization coalesces changes, rejects stale preparation, retries transient writes, and retires only packages with safe cleanup evidence.
- Resumed update offers require a fresh check and explicit installation consent. Compact layout editing and child Settings explain additional controls and local overrides.

- Ordinary agent activity on panels now uses the same breathing diamond as explicit holds, replacing the static dot. Reduce Motion keeps the diamond static.

### Internal

- Qualified stable layout apps with independent source and visual review, focused native VM gates, and signed/notarized runtime-upgrade fixtures. Full final-source inventory certification, native Spotlight launch, and a real remote Sparkle install were not established.

- Made changelog rollover an explicit release completion and next-release preparation check, including reconciliation back to a separate development checkout so shipped entries are not reused.

- Added a reusable release finalizer for workflow monitoring, downloaded artifact verification, authorized publication, resumable anonymous delivery checks and narrow ledger reconciliation. Batched local preflight checks and shortened the release skill; native evidence and explicit waivers remain distinct.

- Integrated candidate passed 536 Swift tests, 119 release-tooling tests (four official-tool tests exercised separately), 72 VM-runner tests, workflow validation, native syntax checks, and the full-history secret scan. The actual nested-signing test now covers Sparkle inside the private runtime.
- Integrated development through `4d81a03`, including stable layout apps, terminal-output recovery, and agent colors. Preserved the public signing, source, update-feed, and release workflows.
- Maintainer requested immediate release after declining additional qualification. Existing layout-app native and signed-upgrade evidence predates this integration; final-candidate native regression, DMG installation, Spotlight, and production Sparkle upgrade checks are waived, not passes.

- Published build 7 from `bd0282b` after successful tag-triggered CI and Release runs. Downloaded verification passed checksums, matching source, signed feed/archive/notes, app and DMG signatures, stapled notarization tickets, and installer alias equality. Anonymous public downloads matched all verified assets. Additional native qualification was waived by the maintainer as recorded above.

## 0.5.0 — 2026-10-19

### Added

- Added configurable unfocused-pane dimming in Settings → Appearance and `appearance.unfocused_pane_dim` through the shared configuration API/CLI. The default is 8%; 0 disables dimming, and applying changes updates existing panes without restarting sessions.

### Changed

- Structural automation preserves focus by default when splitting or moving panes, creating tabs/windows, or opening saved layouts. Explicit creation `new` and movement `target` focus policies remain available; native user controls continue selecting their results.
- Agent labels stay stable without pane-ID suffixes. Holds use a centered breathing diamond without a text suffix, with a static diamond for Reduce Motion. Success checkmarks use the neutral label color.
- Bundled agent guidance requires actor identity in every fresh-shell command block, preserves user focus, and prefers Slate's browser unless the task requires another integration.
- Slowed prompt typing in the website showcase.

### Fixed

- Agent activity frames follow outer window corners while retaining smaller corners at pane splits.
- Background layout reconciliation no longer raises workspace windows or takes keyboard focus from Settings and existing editors. Explicit navigation still reasserts the requested focus.

### Internal

- Integrated committed development main through `239ab7f`, after `892ed26`, preserving public updater, signing and release tooling. Uncommitted development files and unmerged branches are excluded.
- Added focus-policy, responder, presence-animation and dimming regression coverage. Integrated public source passed 487 package tests, release-tooling checks, VM-runner tests, workflow validation with ShellCheck, and the full-history security scan. Native regression, candidate-DMG installation and production upgrade checks were deferred at the maintainer’s explicit request because another task owns the VM.
- Published build 6 from `33bf709` after successful tag-triggered CI and Release workflows. Verified downloaded checksums, app/DMG signatures and notarization tickets, signed feed/archive/notes, complete corresponding source, and stable/versioned installer equality. Native regression, candidate-DMG installation and the production 0.4.0-to-0.5.0 upgrade were skipped at the maintainer’s explicit request.

## 0.4.0 — 2026-10-19

### Added

- Added Show All Tabs (`tab.showAll`) to the command picker, Workspace/Window menus, configurable shortcuts, and shared CLI/page/service command API. It opens the targeted native window group's overview without toggling an already-open overview closed; single-tab windows and sheets reject it.
- Browser Settings lists sites with stored shared browsing data and supports removing a selected stored site, including sites no longer open. Shared `browser.listData` and `browser.removeSiteData` methods support the CLI and trusted clients.

### Changed

- Unnamed tabs display New Tab; clearing a manual title restores that label.
- Working-directory settings use a native folder chooser and a clearer inheritance control.
- Agent focus frames blend when agents target the same element.
- Updated the website mockups with a revised demo sequence, hero presentation, and plugin gallery examples.

### Fixed

- Agent indicators now cover asynchronous terminal starts, terminal history/export/search, plugin automatic-title and panel-state edits, and browser site-data clearing. A started command retains its activity until completion, rejection, or session loss, independently of the submitting client.
- Shell reports preserve unknown command text, prioritize Slate hooks, and stop detached retries when the app or reporting shell is gone. Older Bash with strict unset-variable checks loads only the compatible preexec hooks.
- Terminal CLI `start --shell` accepts the same shell-language assertion as `run`.

### Internal

- Integrated committed VM-owner lock recovery/waiting and generated-shell syntax coverage; preserved public strict-mode, updater, and structured-error checks.
- Integrated committed development main through `892ed26`, preserving the public signing, updater, and release pipeline. Uncommitted development documentation and unmerged branches are excluded.
- Added command contract, native overview, picker, shortcut, explicit target, sheet rejection, and trusted-client regression coverage. Verification results are recorded with the release evidence.
- Published build 5 from `06f2e9a` after successful tag-triggered CI and Release workflows. Verified checksums, signatures, corresponding source, reviewed notes, notarization tickets, and installer alias equality. Ten selected native gates passed; this is not full-suite certification. Candidate-DMG installation and the production 0.3.0-to-0.4.0 upgrade were not run.

## 0.3.0 — 2026-10-19

Integrated committed local main `17162fa` after the previous integration at `11861a7`, preserving the public updater and release pipeline.

### Added

- New terminal splits inherit the targeted terminal's current directory by default. Settings and the shared API expose `terminal.inherit_working_directory` and `terminal.working_directory`; unavailable directories fall back to the configured default, then home.
- Added Rename Tab to the native tab context menu, using the existing rename sheet and shared title operation.
- Added all-site and selected-site browser data clearing to Settings, retaining confirmation and separate shared, private-pane, and plugin stores.
- Added a Restore Pane Size button to maximized pane headers.

### Changed

- Agent activity and result indicators remain visible for five seconds; newly split panes show the initiating agent activity.
- Updated the website's terminal previews, product wording, and download presentation. Canonical and sharing links use `slate.weichart.de`.

### Fixed

- Preserve command-picker scroll position during background availability refreshes.
- Keep saved-layout preview geometry stable when editing or reverting pane-bar visibility.
- Limit pane-title renaming to the title text instead of empty header space.

### Internal

- Expanded configuration, split-directory, tab-menu, presence, browser-settings, picker-scroll, pane-header, and saved-layout regression checks. Release verification is recorded separately from implementation coverage.
- Published build 4 from `77c7aca` after successful tag-triggered CI and Release workflows. Verified public assets, signatures, source, notes, and installer alias. The signed DMG passed installation, launch, terminal, and browser DOM/snapshot checks in VMPal. The production 0.2.1 build 3 → 0.3.0 build 4 update passed native Download and Install and Relaunch, preserving settings and the saved workspace. Nine selected native gates passed, including a successful tab-overview rerun; this is not full-suite certification. The VM's known WebKit display-compositing limitation remains distinct from browser DOM and snapshot checks.

## 0.2.1 — 2026-10-18

Integrated from local main `11861a7` into the public release lineage; existing updater, signing, and source-distribution behavior is retained.

### Added

- Added native terminal Find, bounded retained-history retrieval/export, and search through the shared CLI/API.
- Added session-owned terminal operation handles with status, result, and repeatable waits that survive caller disconnects and wait timeouts. Operations are not persisted across app restarts.
- Restored working directories, browser starting URLs, and window geometry alongside workspace structure. Invalid restoration hints are discarded without losing the workspace.
- Added optional plugin API/capability compatibility declarations, with validation at registration, enablement, and launch.
- Added complete machine-readable method and command contracts, including all six released updater methods and both updater commands.

### Changed

- `terminal.capture` now returns the active screen. Use `terminal.history` for retained scrollback. A `terminal.run` wait timeout or caller disconnect no longer discards the tracked operation; the pane stays busy until the operation settles. Submission failures are retained as `submissionFailed` outcomes.
- Refined saved-layout editing, pane previews, per-pane working directories, and dedicated launcher presentation.
- Added a responsive SLATE welcome banner and refined onboarding command controls. The website's agent-presence demonstrations now use detached pills in pane corners.
- Replaced the website’s placeholder terminal mark with the shipped app icon in the hero, download section, footer, launcher demo, and favicon. GitHub Pages now bundles the image and deploys asset changes.
- The website and README download links now use GitHub's latest stable Mac installer URL. The release workflow includes `Slate-Terminal-arm64.dmg` as a byte-identical alias of the versioned notarized DMG, with both included in `SHA256SUMS`. Existing published releases are not modified by this workflow change. (`a57ab81`)

### Fixed

- Initialize missing legacy Bash prompt variables without disabling the user’s strict mode.
- Preserve empty Bash command reports when history is disabled; CLI option parsing no longer drops those running-state updates.
- Keep signed release notes byte-identical to the reviewed Markdown so signing warnings do not appear in the updater.

### Internal

- Replaced the notes guard with an explicit conditional for CI ShellCheck compatibility. The v0.2.0 tag stopped at validation and produced no release; v0.2.1 is the published replacement.
- Reconciled the new complete automation catalog with the released updater, preserving one shared descriptor and adding request-parser/result-schema regression tests plus native updater response capture. API generation 1 remains in place; the terminal behavior changes above are called out explicitly for clients.
- Updated native gate dependencies and fixture panel identity, kept all updater gates, and expanded the combined inventory to 90 invocations. Corrected shell/context fixture assumptions and terminal-history teardown; 20 selected VM gates passed after fixes. Separate release verification passed for the signed DMG and the real production 0.1.0 build 1 → 0.2.1 build 3 update, including relaunch and settings/workspace preservation.
- CI and Release now share explicit engine cache restore/save steps, retaining validated engine inputs before later packaging or signing failures. Engine validation and tests still run on cache hits; GitHub tag scope limits reuse to the same tag and eligible default-branch caches.
- Release validation rejects missing, empty, invalid UTF-8, NUL-containing, or oversized notes before the macOS job. Public update configuration is checked before compilation, and the built app is still checked afterward.
- Draft GitHub release descriptions now use the same checksum-verified, curated Markdown as the signed in-app release notes.
- Added repository-local changelog and release skills, with engineering guidance to log meaningful completed changes alongside their implementation. Release preparation curates public notes from this ledger and the release diff; draft building and publication remain distinct operations with actual VM installation and updater checks.

## 0.1.0

First published release. This baseline is summarized from the reviewed [0.1.0 release notes](docs/releases/v0.1.0.md), committed at `2901ae5`.

### Added

- Native macOS workspaces with terminal and browser panes arranged in tabs and splits.
- Saved layouts with working directories, reopened through dedicated launchers.
- Plugins providing custom panels, commands, and background services.
- Workspace control through the CLI and shared automation API.
- Signed in-app update checks, release notes, and downloads, with explicit Install and Relaunch confirmation. Closing the update window or quitting does not install a staged update. This first release establishes the update channel for later published versions.

### Compatibility

- Requires Apple Silicon and macOS 27 or later.
