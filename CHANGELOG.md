# Changelog

Detailed change record for agents and maintainers. Public release notes live in `docs/releases/`.

## Unreleased

### Added

### Changed

### Fixed

### Internal

## 0.3.0 — Pending publication

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
