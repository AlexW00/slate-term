# Release builds and credentials

Slate's release workflow builds Apple Silicon apps for macOS 27 or later. A successful workflow produces a **draft** GitHub release containing a signed and notarized ZIP, a signed and notarized DMG, matching source, and SHA-256 checksums. Publishing the draft remains a separate maintainer action. This tooling does not implement in-app updates; Sparkle integration and an appcast are separate work.

## Repository checks

Pull requests and pushes to `main` run the complete fetched-history secret scan, release-tooling tests, verification-inventory tests, workflow validation, Swift unit tests, and an unsigned Release build/package smoke test. Actions are pinned by commit; Dependabot proposes updates. Fork builds receive no signing credentials. Native application behavior still requires the [VM gates](vm-testing.md); CI packaging does not certify GUI behavior.

The macOS jobs use the Apple Silicon `xcode-27` runner because the app requires SDK 27. The bootstrap pins Ghostty, Zig, downloaded archive hashes, and the local Ghostty patch. It disables Sentry and gettext, and rejects their symbols in the resulting library. The license collector checks pinned dependency notices and installs them into the app.

Run the inexpensive checks locally:

```sh
python3 scripts/security-scan.py --include-untracked
python3 -m unittest discover -s Tests/Release -v
python3 -m unittest discover -s Tests/VMRunner -v
python3 scripts/check-workflows.py
```

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

Signing uses an explicit keychain for each nested executable and app, enables hardened runtime, submits for notarization, staples tickets, and checks the result before producing final assets. A missing identity, changed app, dirty source, absent/mismatched source archive, failed notarization, or failed verification stops the release. `bash scripts/release-package.sh --unsigned` exercises packaging without credentials; its filenames are marked `-unsigned`, and it does not establish Gatekeeper acceptance.

## GitHub setup and release

1. Create a `release` environment. Add the five fields above as **environment secrets**, using a private authenticated UI or stdin from the secret manager. Do not keep copies in any checkout. Apply tag-only deployment rules and required reviewers where the repository's plan supports them.
2. Protect `main` and require the source and macOS CI checks before merging. Keep Actions workflow-token permissions read-only by default. Only the draft-release job requests `contents: write`; it receives distributables, not the signing credentials.
3. After CI and relevant VM/manual QA pass, create a `vX.Y.Z` tag on the reviewed default-branch commit and push it. This action starts signing. The workflow also supports a manual run for an existing tag. With tag-only environment rules, set the workflow ref to that same tag: `gh workflow run release.yml --ref v0.1.0 -f tag=v0.1.0`. Selecting `main` for dispatch does not become a tag deployment merely because the checkout uses a tag. Metadata validation rejects tags outside default-branch history or invalid version syntax.
4. Inspect the draft, download/check its assets, install and exercise the notarized app on a clean Mac/VM, and confirm source availability. Then publish the draft when authorized. Re-running an already-created draft fails rather than replacing published assets silently; inspect the prior run before retrying.

The build number is the workflow run number. Source packaging happens before credentials are loaded. Uploads retain only distributable ZIP/DMG/source/checksum files for seven days; temporary keychains, source caches, and raw credential inputs are not uploaded.

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
