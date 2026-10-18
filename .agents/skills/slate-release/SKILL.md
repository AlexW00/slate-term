---
name: slate-release
description: Prepare, build a signed draft, or publish a Slate Terminal release using the repository's tag-triggered pipeline, curated notes, and VM installation checks.
---

# Slate releases

Work from the repository root. Read `AGENTS.md`, `docs/releasing.md`, `docs/vm-testing.md`, `CHANGELOG.md`, the latest `docs/releases/vX.Y.Z.md`, and the current release workflow. The documentation and existing `scripts/release-*` helpers own the commands; reuse them instead of creating a parallel release pipeline.

## Choose the requested operation

- **Prepare:** reconcile local release contents, recommend a version, and draft reviewable notes. This does not authorize commits, pushes, tags, signing, or publication.
- **Build:** commit and push the reviewed release preparation on `main`, tag that exact commit, monitor the signed draft, and verify its assets and VM installation. An explicit request for this operation authorizes those steps unless the user narrows it.
- **Publish:** promote the verified draft to latest stable and verify public downloads and the actual updater. This requires explicit publication authorization; a Build request does not authorize it.

Carry authorization already given in the conversation forward. Automatic skill selection is not authorization. Honor any current hold or narrower scope. If the request is ambiguous, complete local preparation first and ask only about the specific remaining external action. Do not add a second approval step when the user already authorized that operation.

## Prepare

1. Establish the last **published stable** release, its tag/commit and build number, and the intended `main` commit. Inspect worktree ownership and pending work without incorporating unmerged branches. If remote metadata cannot be checked, label the baseline provisional. A local tag or GitHub draft alone does not establish a published release.
2. Reconcile `CHANGELOG.md` against the commits and full diff between that baseline and the intended release. Follow `.agents/skills/slate-changelog/SKILL.md`; identify missing entries, duplicates, breaking changes, compatibility changes, and limitations. State what is excluded because it has not landed.
3. Recommend `X.Y.Z` with a short rationale: patch for compatible fixes, minor for new capabilities, and an explicit compatibility decision for breaking changes, especially before 1.0. Respect a user-selected version if valid. Both version and build must advance beyond the stable release; CI supplies the build number from its run number. This pipeline accepts stable `vX.Y.Z` tags only.
4. Write `docs/releases/vX.Y.Z.md` from the reconciled ledger and diff. Lead with user-visible outcomes; combine related work and omit routine internal noise. Retain relevant breaking, security, compatibility, and limitation information. Verify claims against implementation and evidence. Match the app's plain-text Markdown notes renderer. GitHub's generated commit list is not the curated notes.
5. Keep ordinary preparation in `Unreleased` until the release scope is reviewed. When finalizing the candidate for Build, move exactly those entries to a version section marked **Pending publication**, leaving a fresh `Unreleased` with Added, Changed, Fixed, and Internal headings. Preserve unrelated later work. Do not mark a candidate as published or invent a publication date.
6. Present the exact base/target commits, proposed version, notes, relevant checks, and outstanding verification. Reconcile again if `main` changes before tagging.

## Build the signed draft

1. Confirm release changes have landed on reviewed `main`, the notes match that scope, and the build checkout will be clean and committed. Preserve unrelated worktrees. Run the local release checks in `docs/releasing.md` and relevant VM gates; ordinary pushes and PRs do not run CI. Stage only reviewed release changes, commit and push within the authorized scope, then confirm the remote commit.
2. Confirm the existing public `SPARKLE_PUBLIC_ED_KEY` and `SPARKLE_FEED_URL` configuration matches the release repository. Keep pinned dependencies and checksum-pinned Sparkle tools. Normal releases do not provision secrets, generate keys, rotate signing keys, or install global tooling. Missing provisioning is a separate task.
3. Create a fresh `vX.Y.Z` tag on that exact reviewed commit and push it. Use `scripts/release-metadata.py` for its existing tag/default-branch/clean-source checks. Monitor both tag-triggered CI and the release workflow; successful ordinary branch checks cannot substitute for them. There is no manual-dispatch release path.
4. Inspect the resulting **draft** and download its assets into a task-owned directory. Verify the source commit and version/build association, `SHA256SUMS`, signed/notarized ZIP and DMG, corresponding source and rebuild instructions, signed appcast and notes, and successful signing/notarization verification from the workflow. Confirm `Slate-Terminal-arm64.dmg` is byte-identical to the versioned DMG and both are checksummed. Appcast archive/notes URLs must be immutable URLs for this tag, not the latest alias.
5. Use VMPal for native checks. Install the candidate from its actual downloaded DMG and verify launch, reported version/build, and representative terminal/browser behavior. Record evidence and limitations separately from unit/build/package checks. Preserve a separate VM snapshot or installation of the previous published DMG for the updater check below. Do not launch test GUI on the host or compile in the guest.

The production feed cannot expose draft assets. Candidate DMG installation verifies the candidate installer, not the previous-version Sparkle upgrade. An isolated test feed is an option only if an existing supported mechanism permits it without changing signed production assets; otherwise perform the real upgrade after authorized publication.

If a run fails, inspect its actual state and fix the cause. An existing draft is not permission to replace assets or move a tag. Never overwrite published assets, force-move a release tag, or repeatedly retry a failed release without understanding the failure. Rebuild changed source as a new reviewed candidate using the applicable authorization.

## Publish and verify the update

1. With publication authorization, confirm the candidate still has the reviewed commit, successful required checks, verified assets, and strictly newer version/build. Publish the draft as stable and explicitly select it as latest. Publication changes the production updater feed immediately.
2. Without GitHub authentication, fetch the stable appcast and stable DMG alias, then every archive/notes URL referenced by the feed and the corresponding source/checksums. Verify the new tag/version, checksums, and stable/versioned DMG equality. Allow bounded CDN propagation retries; diagnose persistent mismatches rather than editing signed files or rewriting assets.
3. In VMPal, install the **previous published DMG**, launch it, and capture its version/build plus representative settings and saved workspace state. Use the real Check for Updates → Download → Install and Relaunch flow against the production feed. Confirm the offered version and notes, explicit installation consent, application exit/relaunch, installed version/build, and preserved settings/workspace state. Capture fresh screenshots/state readback at each meaningful result. A manually copied candidate, a simulated updater, or a successful checksum does not prove this upgrade.
4. Exercise applicable signature-rejection and cancellation gates using isolated fixtures; never tamper with the public feed to test rejection. Record their evidence separately from the successful production upgrade.
5. After confirming publication, replace the candidate's Pending publication marker with the actual publication date in a task-owned follow-up change. Commit/push that bookkeeping only within existing authorization. Keep fresh `Unreleased` entries intact. Report the release URL, public download/feed checks, installation and upgrade evidence, and anything still unverified. Publication remains published if a later check fails; report that state accurately and investigate without silently deleting or replacing the release.
