---
name: slate-release
description: Prepare, build a signed draft, or publish a Slate Terminal release using the repository's tag pipeline and resumable release helpers.
---

# Slate releases

Work from the repository root. Read `AGENTS.md`, `CHANGELOG.md`, and the [routine release commands](../../../docs/releasing.md#routine-release-commands). Read provisioning or VM documentation only when that work is needed. Reuse the helpers; do not create per-version verification scripts.

## Scope and authorization

- **Prepare:** reconcile committed changes and draft notes. No commit, push, tag, signing or publication.
- **Build:** an explicit request authorizes the reviewed commit/main push, fresh tag push, signed draft and verification.
- **Publish:** requires explicit publication authorization and makes the production feed live. Carry existing authorization forward without another approval pause.

Preserve unrelated changes and worktrees. Never move release tags, overwrite published assets or automatically rerun failed signing workflows. A failure after publication leaves the release published; resume verification and report its actual state.

## Decisions that need review

Establish the last published stable tag, commit and build, plus the intended candidate commit. Compare the actual committed diff and ledger using `slate-changelog`. Unmerged or dirty work is excluded. When development and public histories differ, integrate the committed delta in an isolated public worktree; preserve public-only updater and release code. Do not rerun the initial history-export tool for routine releases.

Recommend the version and curate `docs/releases/vX.Y.Z.md` from that evidence. Use patch for compatible fixes, minor for new capabilities, and an explicit decision for breaking changes before 1.0. Both version and build must advance. Retain relevant limitations; do not invent migration requirements for unreleased development formats. Archive only the selected ledger entries under **Pending publication**, retaining fresh Unreleased categories and unrelated entries.

Choose native regression gates from the actual changed behavior. Reuse successful evidence for unchanged source. Candidate DMG installation and a real previous-version Sparkle upgrade cover different paths; normally perform both in VMPal. A full gate inventory, rejection tests and cancellation tests are needed when changes justify them, not automatically on every release. Record an explicit maintainer waiver when those checks are waived; an occupied VM or timeout is not a waiver. See `docs/vm-testing.md` when running native checks.

## Execute the release

1. Run `bash scripts/release-preflight.sh` and relevant change checks. Confirm the existing public update key/feed, reviewed notes and clean committed candidate. Use `release-metadata.py` for tag/default-branch validation. Push a fresh stable tag on the reviewed main commit within Build authorization. Do not provision or rotate credentials during a normal release.
2. Run `release-finalize.py watch --tag vX.Y.Z`, then `verify --tag vX.Y.Z`. These bind both tag workflows, assets, source, signatures and notes to the candidate and retain receipts. Investigate failures instead of writing replacement scripts. Install and exercise the downloaded DMG in VMPal unless explicitly waived.
3. When publication is authorized, run `publish --tag vX.Y.Z --native-evidence REFERENCE` or `--native-waiver 'explicit maintainer instruction and reason'`. The helper checks newer version/build, publishes once and verifies anonymous public delivery. Rerunning after a publication/readback interruption continues verification without republishing. Neither a flag nor this skill creates user authorization.
4. Exercise the real production upgrade from the previous signed app unless explicitly waived. Record the offered version/notes, installation consent, relaunch and preserved state. A checksum or copied app does not establish this behavior.
5. Run `reconcile --tag vX.Y.Z` to date only the selected ledger heading from actual publication. Use `--ledger PATH` for another ledger only if it already contains that candidate section. Review/commit/push bookkeeping within existing authorization. Report release URL, artifact/public checks and native evidence or waiver separately.

All finalizer commands use `python3 scripts/release-finalize.py`; `--output PATH` selects a task-owned receipt/cache directory. Commands and failure behavior live in `docs/releasing.md`.
