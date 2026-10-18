# Release builds and credentials

Slate's release workflow builds Apple Silicon apps for macOS 27 or later. A successful workflow produces a **draft** GitHub release containing a signed and notarized ZIP, a signed and notarized DMG, matching source, a signed Sparkle appcast, signed release notes, and SHA-256 checksums. Publishing the draft remains a separate maintainer action. Sparkle 2.10.0 uses the latest published stable release’s appcast; preparing a draft does not advertise an update.

## Changelog and release skills

For meaningful implementation work, follow [slate-changelog](../.agents/skills/slate-changelog/SKILL.md) and keep the detailed [change ledger](../CHANGELOG.md) current in the same change. For release work, follow [slate-release](../.agents/skills/slate-release/SKILL.md): reconcile the ledger against the actual changes since the last published stable tag, then curate `docs/releases/vX.Y.Z.md`. Both the GitHub release description and signed in-app notes use that reviewed file. Routine internal details can stay in the ledger; retain user-relevant compatibility, security, breaking changes, and limitations.

Preparation, building a signed draft, and publishing are separate operations. Carry the user's existing authorization forward and honor any release hold. Build includes the reviewed commit and tag pushes when explicitly requested; publication still needs explicit authorization. A draft is marked Pending publication in the ledger until it is actually public. The release skill requires a candidate DMG installation in VMPal, followed by a real previous-version upgrade through Sparkle after authorized publication.

## Repository checks

Only pushes of version tags matching `v*` (release format `vX.Y.Z`) run CI and release workflows. Pull requests, ordinary branch pushes (including `main`), and manual dispatches do not start them. Tag-triggered CI retains the complete fetched-history secret scan, release-tooling tests, verification-inventory tests, workflow validation, Swift unit tests, and unsigned Release build/package smoke test. The release workflow validates the tag before building, signing, notarizing, and creating a draft. Actions are pinned by commit; Dependabot proposes updates. Signing credentials remain restricted to the release environment. The separate website workflow is unchanged. Native application behavior still requires the [VM gates](vm-testing.md); CI packaging does not certify GUI behavior.

Release notes are validated before allocating the macOS build runner. The environment-bound build job validates the public update key and repository-specific feed before Metal setup, tests, or compilation, then validates the compiled app again. Notes must be nonempty UTF-8 text, without NUL characters, and at most 256 KiB.

CI and Release restore the same pinned engine cache, keyed by runner OS/architecture, Xcode version, and engine script/patch hashes. Both always run the engine build and its source, patch, symbol, and receipt checks, then save a missing cache immediately after success, before app packaging or credentials. Only `.tools/zig-*` and `.build/bootstrap` are cached; release assets and signing material are excluded. [GitHub cache scope](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache) permits the same tag and eligible default-branch caches, not caches from other tags. New-tag CI and Release jobs may both miss; this change does not guarantee a warm build for each release or deduplicate the two builds.

The macOS jobs use the Apple Silicon `xcode-27` runner because the app requires SDK 27. Each job installs Apple's optional Metal Toolchain if the shader compiler is unavailable. The bootstrap pins Ghostty, Zig, downloaded archive hashes, and the local Ghostty patch. It disables Sentry and gettext, and rejects their symbols in the resulting library. The license collector checks pinned dependency notices, including Sparkle and its bundled third-party notices, and installs them into the app. The Swift library and Xcode package pin inventories are checked separately because Sparkle belongs only to the native app.

Run the inexpensive checks locally:

```sh
python3 scripts/security-scan.py --include-untracked
python3 -m unittest discover -s Tests/Release -v
python3 -m unittest discover -s Tests/VMRunner -v
python3 scripts/check-workflows.py
```

Before tagging, workflow validation must include ShellCheck. If the script reports that ShellCheck is unavailable, use an existing or task-local official binary and rerun it; that partial check does not cover CI shell lint.

The security scanner checks every reachable blob and commit plus private filenames in every historical tree. Reports contain only rule/location metadata. `--tree-only` is useful during cleanup but is not a publication audit. Scanners cannot prove the absence of every possible secret; review findings, dependency sources, and the publication diff too.

## Shared credentials across worktrees

Keep credentials in 1Password and the reference file outside **every** Git checkout. All worktrees use the same default `~/.config/slate-term/release.env.op`; there are no credential symlinks or plaintext `.env` files inside the repository.

Create the directory with mode `700`, copy `config/release.env.op.example` there as `release.env.op`, and set its mode to `600`. Edit only its `op://` references to existing private 1Password fields. The helper rejects literal values, extra variables, insecure permissions, symlinks, and files located inside any Git checkout. Authenticate the 1Password CLI through its normal desktop integration.

Required fields:

| Variable | Value held in the private credential store |
| --- | --- |
| `SLATE_RELEASE_CERTIFICATE_P12_BASE64` | Single-line base64 of a Developer ID Application certificate and its private key, exported as P12. |
| `SLATE_RELEASE_CERTIFICATE_PASSWORD` | Password protecting that P12. |
| `SLATE_NOTARY_KEY_P8_BASE64` | Single-line base64 of the App Store Connect team API private key used for notarization (individual keys are unsupported). |
| `SLATE_NOTARY_KEY_ID` | API key ID. |
| `SLATE_NOTARY_ISSUER_ID` | API issuer ID. |

An Apple Development or Apple Distribution identity is not a Developer ID Application identity. Do not paste private keys, passwords, or base64 contents into issues, chat, logs, workflow files, or shell command arguments.

The wrapper uses `op run` for local injection, creates a unique temporary keychain and notary profile, and passes only the derived signing identity/keychain/profile to the packaging child. Raw input variables and `OP_*` variables are removed from that child's environment. Concurrent worktrees share a short lock only while creating/deleting keychains; the helper does not replace the default keychain or its complete search list. Ordinary failures, timeouts, and handled signals clean up the owned process group, keychain, and files. Power loss or SIGKILL can bypass cleanup; inspect only the affected run's `slate-release-*` temporary directory/keychain before removing leftovers. Apple's security utility accepts its import password as an argument, so this is not a claim of protection from other processes running as the same user.

## Local release rehearsal

Use a clean, committed checkout. The unsigned build can be exercised with dirty source, but such a build is deliberately ineligible for signed packaging or a corresponding-source release.

```sh
bash scripts/build-ghostty.sh
bash scripts/release-build.sh --version 0.1.0 --build-number 1
python3 scripts/release-source.py --output artifacts/release/assets --version 0.1.0 --build-number 1
python3 scripts/release-with-credentials.py -- bash scripts/release-package.sh
```

`--env-file /private/location/release.env.op` selects a different reference file. The source packager verifies that HEAD, clean source state, version/build, and the unsigned app digest match the build receipt. It includes the project's tracked files, patched Ghostty, selected Zig dependency sources, resolved Swift dependency sources, compiler runtime source, licenses, and `REBUILD.md`. It excludes `.git` and compiled caches. Source archives contain instructions to select bundled dependencies without the original Git metadata.

Signing uses an explicit keychain for each nested executable and app, preserves Sparkle Downloader entitlements, signs its helpers and nested bundles before the framework, enables hardened runtime, submits for notarization, staples tickets, and checks the result before producing final assets. A missing identity, changed app, dirty source, absent/mismatched source archive, failed notarization, or failed verification stops the release. `bash scripts/release-package.sh --unsigned` exercises packaging without credentials; its filenames are marked `-unsigned`, and it does not establish Gatekeeper acceptance.

## GitHub setup and release

1. Create a `release` environment. Add the five Apple fields above and `SLATE_SPARKLE_PRIVATE_KEY` as **environment secrets**, using a private authenticated UI or stdin from the secret manager. Do not keep copies in any checkout. Apply tag-only deployment rules and required reviewers where the repository's plan supports them.
2. Protect `main` with review requirements; do not require the tag-only CI jobs as pull-request status checks, because they do not run on PRs. Keep Actions workflow-token permissions read-only by default. Only the draft-release job requests `contents: write`; it receives distributables, not the signing credentials.
3. Set the public `SPARKLE_PUBLIC_ED_KEY` and `SPARKLE_FEED_URL` environment variables described below, and commit reviewed release notes at `docs/releases/vX.Y.Z.md`. After local checks and relevant VM/manual QA pass, create a `vX.Y.Z` tag on the reviewed default-branch commit and push it (`git tag v0.1.0` then `git push origin v0.1.0`, for example). The tag push starts CI and the release pipeline; there is no manual-dispatch trigger. Metadata validation rejects tags outside default-branch history or invalid version syntax.
4. Inspect the draft, download/check its assets, install and exercise the notarized app on a clean Mac/VM, and confirm source availability. Then publish the draft as the latest stable release when authorized. Follow the update publication checks below. Re-running an already-created draft fails rather than replacing published assets silently; inspect the prior run before retrying.

The workflow also includes `Slate-Terminal-arm64.dmg`, a byte-identical copy of the versioned, notarized DMG. The website and README use `https://github.com/AlexW00/slate-term/releases/latest/download/Slate-Terminal-arm64.dmg` so their direct download follows the latest stable release. The updater continues to use immutable, version-specific archive URLs. Include both DMGs in `SHA256SUMS`.

The build number is the workflow run number. Source packaging happens before credentials are loaded. Uploads retain only distributable ZIP/DMG/source/appcast/release-note/checksum files for seven days; temporary keychains, source caches, and raw credential inputs are not uploaded.

## In-app update configuration and signing

The native app pins Sparkle 2.10.0. Release builds receive `SPARKLE_PUBLIC_ED_KEY` and `SPARKLE_FEED_URL` as Xcode build settings, mapped to `SUPublicEDKey` and `SUFeedURL`. Configure them as public variables on the GitHub `release` environment:

- `SPARKLE_PUBLIC_ED_KEY`: the base64 Ed25519 public key, decoding to exactly 32 bytes.
- `SPARKLE_FEED_URL`: `https://github.com/OWNER/REPOSITORY/releases/latest/download/appcast.xml`, using the release repository’s exact owner and name.

The app stages and authenticates the archive before showing Ready. It holds Sparkle’s install reply until explicit Install confirmation, preventing install-on-quit before consent. Sparkle downloads the archive again after confirmation and verifies installability before installation; Ready means signature-authenticated bytes, not a completed installation check. Signed Markdown notes are rendered as text without WebKit.

The app requires signed feeds, verifies archives before extraction, and sets `SUSignedFeedFailureExpirationInterval` to `0` so signature validation never expires. Signed packaging checks all three settings and rejects missing provisioning. Unsigned smoke builds can omit the public configuration; their update controls report that updates are unavailable. A missing first public release likewise means there is no feed yet.

Provision a dedicated Sparkle Ed25519 private key separately, after explicit authorization. `SLATE_SPARKLE_PRIVATE_KEY` holds Sparkle’s exported base64 key (32-byte seed, or legacy 96-byte format) as a release environment secret. Keep a secured backup outside every checkout. The Apple credential wrapper and its five-field `.env.op` template are unchanged; the update-signing command accepts this separate variable only for its own process. It passes the key to official tools over standard input with `--ed-key-file -`, removes signing inputs from child environments, and suppresses tool diagnostics that could echo malformed keys. It never falls back to a login Keychain, generates keys, or provisions secrets.

The tools are downloaded from the official 2.10.0 release with a committed SHA-256 checksum. `generate_appcast` signs the notarized ZIP, release notes, and feed; `sign_update --verify` verifies all three. The generated feed must contain exactly one release with matching version/build, macOS 27 minimum, archive size, signed notes, and immutable version-tag asset URLs. Delta updates are disabled. Source packaging includes the entire resolved Sparkle checkout and its vendored source; `REBUILD.md` explains rebuilding its framework.

After producing the signed distributables, local preparation is:

```sh
python3 scripts/release-updates.py bootstrap-tools --output .build/sparkle-tools
# Inject SLATE_SPARKLE_PRIVATE_KEY for this command using your private secret manager.
python3 scripts/release-updates.py prepare --tools .build/sparkle-tools \
  --app 'artifacts/release/Slate Terminal.app' --assets artifacts/release/assets \
  --notes docs/releases/v0.1.0.md --repository OWNER/REPOSITORY
```

Use a fresh tools directory or reuse the verified existing distribution; the bootstrap refuses to overwrite one. Regenerate `SHA256SUMS` after adding `appcast.xml` and `*-arm64.md`, as the workflow does. Do not edit signed appcasts, archives, or notes after generation; changes require regenerating and verifying signatures. The draft job verifies downloaded checksums and requires exactly one notes asset, then uses that same reviewed Markdown for the GitHub release description. It does not generate a separate commit-list description.

## Publishing an update

GitHub’s [latest release asset route](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases) makes the feed available only once its release is public and selected as latest. Draft assets are inaccessible to unauthenticated clients, and GitHub excludes drafts and prereleases from its [latest release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release). No public feed is changed by the tag workflow: it only uploads the candidate appcast beside the candidate archives in a draft. There is no release-publication workflow, website deployment, or automatic publishing action.

When separately authorized to publish:

1. Verify the draft’s source, ZIP, both DMGs, appcast, notes, and checksums. Confirm `Slate-Terminal-arm64.dmg` is byte-identical to the versioned DMG. Check that the appcast’s tag-specific archive and notes URLs match assets on that same draft.
2. Verify version and build numbers both advance beyond the current stable release. The workflow run number supplies the build number; do not promote an older tag or rerun as latest. Sparkle refuses downgrades, but an older latest feed could hide an available newer release.
3. Publish the draft as a stable release and explicitly select **Set as the latest release**. Keep prereleases on a separate future channel; this pipeline supports stable versions only.
4. Without GitHub authentication, fetch the stable feed URL and each referenced archive/notes URL. Compare downloaded bytes with `SHA256SUMS`, and confirm the stable feed resolves to the newly published tag. A private repository, missing appcast on the latest release, deletion, or an incorrectly selected latest release will break the stable endpoint.
5. Exercise checking, download, signature rejection, installation, and relaunch using the previous signed app in a clean VM. Publication and checksums do not prove native install behavior. CDN propagation can delay availability; retain prior releases and never rewrite assets in place.

This single-release feed intentionally targets macOS 27 and Apple Silicon. A future OS-support split needs a reviewed multi-version feed design before increasing the minimum OS; otherwise older systems would see no compatible item. Changing keys also needs a deliberate Sparkle key-rotation release, not a silent variable replacement. See Sparkle’s [publishing](https://sparkle-project.org/documentation/publishing/), [security configuration](https://sparkle-project.org/documentation/customization/), and [manual nested signing](https://sparkle-project.org/documentation/sandboxing/#code-signing) guidance.

## Preparing a public history without rewriting active worktrees

Use `scripts/prepare-public-source.py` to create a new private standalone repository from the selected branch. It filters `xcuserdata` from every historical tree, applies explicit private-text replacements, keeps only `main`, removes remotes and unreachable old objects, and runs the complete secret scan. Its receipt is written to `.git/public-source-export.json` only after verification. The source repository, index, files, and other worktree branches are preserved.

Supply a local `git-filter-repo` script matching the pinned official v2.47.0 digest checked by the helper. Example (replace the private path locally):

```sh
python3 scripts/prepare-public-source.py /absolute/new/private/public-source \
  --filter-repo /absolute/path/to/git-filter-repo \
  --replace-text /absolute/private/worktree '~/.worktrees/<owner>/<repo>/task'
```

`--include-working-tree` explicitly snapshots the current publishable edits into the export without committing the original worktree. Review the exported history and rerun its checks before adding a remote or pushing it. Keep any unfiltered repositories private. A public-history rewrite cannot revoke a leaked credential; rotate any real credential found before publication.

## License

Original Slate code is GPL-3.0-or-later; see [COPYING.md](../COPYING.md). Distributed modifications must follow the GPL's source and notice requirements. Third-party components retain their own licenses; the checked inventory and complete notice texts are in `licenses/` and [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md). Keep corresponding source alongside each binary release.
