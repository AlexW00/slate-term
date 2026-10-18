# Changelog

Detailed change record for agents and maintainers. Public release notes live in `docs/releases/`.

## Unreleased

### Added

### Changed

- Replaced the website’s placeholder terminal mark with the shipped app icon in the hero, download section, footer, launcher demo, and favicon. GitHub Pages now bundles the image and deploys asset changes.

- The website and README download links now use GitHub's latest stable Mac installer URL. The release workflow includes `Slate-Terminal-arm64.dmg` as a byte-identical alias of the versioned notarized DMG, with both included in `SHA256SUMS`. Existing published releases are not modified by this workflow change. (`a57ab81`)

### Fixed

### Internal

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
