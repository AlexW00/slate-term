# Tests in VMPal

Run from the repository root:

```sh
python3 scripts/verify-vm.py --list                  # Discover every gate
python3 scripts/verify-vm.py terminal browser        # Select gates
python3 scripts/verify-vm.py --vm slate-term context # Choose a prepared VM
bash scripts/verify-all.sh                          # Complete suite
# Equivalent: python3 scripts/verify-vm.py --all
```

No selection only lists tests; it does not build or launch anything. `scripts/verification_gates.py` is the shared inventory for selection, full execution and completeness checks: **96 invocations**, including seven host checks, all 19 native recipes and three separate app iterations. `app` aliases `app-1`; `--all` includes `app-1`, `app-2` and `app-3`. Unregistered verification scripts fail inventory validation rather than being silently omitted.

**Build on the host; execute native/UI tests sequentially only in the VM.** The seven host-classified gates are engine build, package tests, runner tests, release-tooling tests, mutation checks, app build and whitespace. There is no guest compilation or host GUI fallback. Direct native shell scripts normally compile and execute on the same machine; use the VM runner instead.

## Prerequisites

- Host VMPal and Xcode/Metal tools, plus pinned Ghostty build dependencies. Existing host build caches are reused. The runner uses VMPal's bundled helper without a global CLI installation; `--vmpal` overrides it.
- A signed-in, unlocked macOS VM with VMPal Tools agent control enabled. Default: `slate-term`; override with `--vm` or `SLATE_TEST_VM`.
- **Inside the guest**, VMPal Tools needs Screen & System Audio Recording permission. The user approves this once; host permission is separate.
- Execution runtime at `~/Developer/slate-vm/runtime/bin`: Python 3.9+, Node and tmux. The prepared VM uses a copied relocatable runtime, not guest Xcode. A missing runtime fails explicitly instead of installing development tools.

Execution has been exercised on macOS 27.0.1 with **two CPUs and 4 GB RAM**. The runner starts/resumes the VM in background mode and keeps its virtual display awake. Its window can remain hidden; closing it may suspend the VM. The VM remains running afterward.

### Unlocking the test VM

Alex has granted standing authorization to unlock this test VM during development
and release verification. Carry it forward without asking again. This applies to
VM sign-in, not unrelated accounts or browser authentication.

First use VMPal's saved password:

```sh
/Applications/VMPal.app/Contents/Helpers/VMPalMachine.app/Contents/MacOS/VMPalMachine \
  --cli sign-in slate-term
```

If the saved password is stale, use the authenticated 1Password CLI to fetch
`op://Personal/vmpal - slate-term/password`, refresh VMPal through standard input,
and sign in. An unauthenticated CLI requires its normal authentication flow;
do not create accounts or change credential configuration automatically.

```sh
(
  set -o pipefail
  op read 'op://Personal/vmpal - slate-term/password' |
    /Applications/VMPal.app/Contents/Helpers/VMPalMachine.app/Contents/MacOS/VMPalMachine \
      --cli set slate-term --account-password-file - &&
    /Applications/VMPal.app/Contents/Helpers/VMPalMachine.app/Contents/MacOS/VMPalMachine \
      --cli sign-in slate-term
)
```

Keep shell tracing off. Never print the password or put it in command arguments,
files, logs, or the repository. VMPal checks for a locked screen before typing.
Verify the unlocked desktop before resuming native tests. Do not repeatedly retry
a rejected password; ask for help only if normal authentication or sign-in fails.

## Build and transfer

Selected native recipes compile with `SLATE_VM_BUILD_ONLY=1`; their packaged executables run with `SLATE_VM_PREBUILT=1`. The bundle includes required app/CLI/native products, relocatable local libraries, Ghostty resources, scripts and fixtures. Compiler modules, debug symbols, build caches and the development toolchain are excluded. Compiler commands are blocked in the guest.

Source inputs travel for fixtures and provenance, not compilation. Source changes during the run invalidate completion. Separate host-product and transferred-product hashes bind receipts to actual binaries; guest verification checks transferred source/product hashes before starting tests. Native dependencies must resolve to packaged gate-local libraries or system libraries.

## Evidence and failures

Every invocation prints `artifacts/vm/<run-id>/` containing:

- `receipt.json`: selection, source/binary hashes, host and guest statuses, completion, exit and cleanup/retrieval information.
- `host-build.log` and host-gate logs; `vm-exec.log` and individual VM-gate logs.
- `results.json`: checkpointed guest statuses, including partial results when available.
- `gates/<gate>/`: changed per-gate artifacts, preserving the three app iterations separately.

`completed` means every selected gate has a status, **not** that every gate passed. Check `exitCode` and individual results. Failures remain failures; subsequent gates normally continue so the run collects their outcomes. Timeouts return **124**; SIGINT/SIGTERM cancellation returns **130/143** with bounded owned teardown and a receipt. Host compiler jobs use process-group cancellation without adopting persistent shared SDK build services as test processes.

Only `--all` can publish `artifacts/verification.json` and `verification-checks.txt`, after every inventory gate succeeds, evidence retrieval/teardown succeeds, and sources/binaries still match. Cancellation or finalization failure withholds/withdraws that certificate. Starting another full run archives the preceding certificate/check list in its run directory. A selected pass is not full-suite certification.

VM execution holds `/tmp/slate-ui-tests.lock`, taken after host builds, just before the bundle is transferred. Its `owner.json` records the run ID, host name, runner PID and that process's start time, plus the guest run directory once created. A run that finds the lock busy waits for it (`--lock-wait SECONDS`, default 1800) instead of failing. It recovers the lock only when the owner ran on this Mac and that runner process no longer exists, for example after a killed session: it first runs the ended run's `--cleanup-guest`, keeps the lock if that cannot be confirmed, and records the recovery in its receipt as `recoveredStaleLocks`. A live owner, an owner on another host, an unknown start time and an old-format lock without `owner.json` are never broken automatically; inspect those by hand. Cleanup tracks owned process identities/descendants, not arbitrary processes with similar names. Failed runs preserve guest bundle/ownership evidence; `--keep-guest` also preserves successful runs. Incomplete retrieval or teardown is reported, and unconfirmed teardown retains the lock. Process tracking is not containment against malicious same-user code.

`--timeout` sets each VM gate's deadline (600 seconds by default). Quiet runner regressions can also run directly on the host:

```sh
python3 -m unittest discover -s Tests/VMRunner -v
```

### Auditing captured API responses

Selected owned fixtures opt into `*-contracts.jsonl` evidence containing the native
catalog followed by public response values/error codes. It is bounded to 32 MiB and
4,000 records per fixture; exceeding a limit fails rather than silently dropping
samples. Private/debug calls, request arguments and error messages are excluded.
Command IDs are retained to choose the exact built-in or contributed result schema.
This is fixture evidence, not application logging or saved terminal transcripts.

After a run finishes and artifacts are retrieved, audit its gate copies on the host:

```sh
SLATE_TEST_CONTRACT_OBSERVATIONS="$PWD/artifacts/vm/<run-id>/gates" \
  swift test --jobs 4 --filter capturedNativeResponsesConformToTheCurrentSharedCatalog
```

This package test never launches native UI. It checks the captured catalog against
current source and validates observed results/errors with the test schema evaluator.
Without the environment variable it is explicitly skipped. Report its printed
method/command/client coverage, not a claim that every handler/state was exercised.
Run it separately from the VM runner; a VM receipt alone does not certify this audit.

Historical focused evidence includes successful terminal/text-checking/browser execution (`20261016T031205Z-55d6457a`), actual timeout/cancellation receipts (`20261016T031250Z-02ce1790`, `20261016T031305Z-f737e0a2`), and browser-navigation/command-picker (`20261016T040246Z-61937331`). These establish those particular runs, not a fresh full-suite pass. Use the current full certificate and its linked run receipt for current-source verification.


### Signed Release layout-app checks

Use separately built and locally signed Release fixtures without rebuilding them as Debug:

```sh
python3 scripts/verify-vm.py layout-apps layout-app-upgrades layout-app-sync layout-apps-ui \
  --app "$PWD/artifacts/release/layout-apps-v1/Slate Terminal.app" \
  --upgrade-app "$PWD/artifacts/release/layout-apps-v2/Slate Terminal.app" \
  --incompatible-upgrade-app "$PWD/artifacts/release/layout-apps-abi2/Slate Terminal.app"
```

Each fixture keeps its original `build-source.json` and a verified `vm-signing.json` linking the unsigned tree, signed tree, source receipt and exact signing certificate. The ABI-negative fixture is explicitly derived on the host and signed after its metadata change. The runner records the derivation's selected signed bytes; neither it nor the guest signs or compiles a replacement. UI captures still require independent visual review, and API reset/icon selection checks do not establish mouse hit-target behavior.

The `layout-app-sync` gate checks live parent plugin changes, deferred replacement/removal while child panes remain open, unavailable package retention, duplicate owner activation, maintenance exclusion, and corrupt/missing startup preservation. Startup-failure evidence includes sampled native WindowServer state and the runtime publication markers; it does not test the non-integration error dialog.

Behavior-changing upgrade baselines may include `fixture-source-variant.json` beside their original build receipt. It binds the entire current source inventory, original source inventory, and exact archived original files. The runner verifies each difference and records `matched-explicit-upgrade-baseline`; it never describes that baseline as a current-source build. Ordinary prebuilt app receipts still require an exact current-source match.

## Native Create App save-panel input

The default `layout-apps-ui` gate captures and cancels the real save panel, then
creates its child-app fixture through the public API. macOS hosts save panels in
a separate process and does not allow the app to invoke their OK action.

For actual native confirmation checks, add `--external-save-input` to the VM
runner with `layout-apps-ui`. The fixture announces each confirmation in its log
and waits up to 30 seconds for a Create click through VMPal. This mode exercises
stale-source rejection, destination collision, and successful chosen-name/location
creation. The runner retains the ordinary VM lease, provenance, and cleanup, and
records this external-input mode in its receipt. A timeout fails the check; it
never substitutes a successful save response.
