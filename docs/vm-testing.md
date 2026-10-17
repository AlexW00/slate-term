# Tests in VMPal

Run from the repository root:

```sh
python3 scripts/verify-vm.py --list                  # Discover every gate
python3 scripts/verify-vm.py terminal browser        # Select gates
python3 scripts/verify-vm.py --vm slate-term context # Choose a prepared VM
bash scripts/verify-all.sh                          # Complete suite
# Equivalent: python3 scripts/verify-vm.py --all
```

No selection only lists tests; it does not build or launch anything. `scripts/verification_gates.py` is the shared inventory for selection, full execution and completeness checks: **82 invocations**, including six host checks, all 19 native recipes and three separate app iterations. `app` aliases `app-1`; `--all` includes `app-1`, `app-2` and `app-3`. Unregistered verification scripts fail inventory validation rather than being silently omitted.

**Build on the host; execute native/UI tests sequentially only in the VM.** The six host-classified gates are engine build, package tests, runner tests, mutation checks, app build and whitespace. There is no guest compilation or host GUI fallback. Direct native shell scripts normally compile and execute on the same machine; use the VM runner instead.

## Prerequisites

- Host VMPal and Xcode/Metal tools, plus pinned Ghostty build dependencies. Existing host build caches are reused. The runner uses VMPal's bundled helper without a global CLI installation; `--vmpal` overrides it.
- A signed-in, unlocked macOS VM with VMPal Tools agent control enabled. Default: `slate-term`; override with `--vm` or `SLATE_TEST_VM`.
- **Inside the guest**, VMPal Tools needs Screen & System Audio Recording permission. The user approves this once; host permission is separate.
- Execution runtime at `~/Developer/slate-vm/runtime/bin`: Python 3.9+, Node and tmux. The prepared VM uses a copied relocatable runtime, not guest Xcode. A missing runtime fails explicitly instead of installing development tools.

Execution has been exercised on macOS 27.0.1 with **two CPUs and 4 GB RAM**. The runner starts/resumes the VM in background mode and keeps its virtual display awake. Its window can remain hidden; closing it may suspend the VM. The VM remains running afterward.

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

VM execution holds `/tmp/slate-ui-tests.lock`. Cleanup tracks owned process identities/descendants, not arbitrary processes with similar names. Failed runs preserve guest bundle/ownership evidence; `--keep-guest` also preserves successful runs. Incomplete retrieval or teardown is reported, and unconfirmed teardown retains the lock. Inspect the receipt and owned guest processes before recovery; never automatically break another run's lock. Process tracking is not containment against malicious same-user code.

`--timeout` sets each VM gate's deadline (600 seconds by default). Quiet runner regressions can also run directly on the host:

```sh
python3 -m unittest discover -s Tests/VMRunner -v
```

Historical focused evidence includes successful terminal/text-checking/browser execution (`20261016T031205Z-55d6457a`), actual timeout/cancellation receipts (`20261016T031250Z-02ce1790`, `20261016T031305Z-f737e0a2`), and browser-navigation/command-picker (`20261016T040246Z-61937331`). These establish those particular runs, not a fresh full-suite pass. Use the current full certificate and its linked run receipt for current-source verification.
