# UI tests in VMPal

Run from the repository root:

```sh
python3 scripts/verify-vm.py --list
python3 scripts/verify-vm.py terminal text-checking browser
python3 scripts/verify-vm.py --vm slate-term browser
```

Names select existing test gates; no arguments only lists them. The runner **builds on the host but executes UI tests only in the VM**. It never falls back to host execution or compiles in the guest. Quiet package/static tests can still run on the host.

## Prepared environment

- VMPal installed on the host; no global CLI installation is needed. The bundled helper is used when `vmpal` is not on PATH. `--vmpal` overrides it.
- The `slate-term` macOS VM, signed in and unlocked, with VMPal Tools agent control enabled. `--vm` or `SLATE_TEST_VM` selects another prepared VM.
- **Inside the guest**, VMPal Tools has Screen & System Audio Recording permission. This requires user approval once; host permission is separate.
- Guest execution runtime at `~/Developer/slate-vm/runtime/bin`: Python 3.9+, Node and tmux. This VM has a copied, relocatable runtime; it does not require guest Xcode. A missing runtime fails explicitly rather than installing tools or falling back.
- Host Xcode/Metal tools and the pinned Ghostty build dependencies. Existing incremental build caches are reused.

Validation used macOS 27.0.1 with **2 CPUs and 4 GB RAM**, without increasing its allocation. The runner starts/resumes the VM in background mode and keeps its virtual display awake during tests. Keep the VM window hidden if you do not want to see its desktop; closing it may suspend the VM. The runner leaves the VM running afterward.

## What gets transferred

The current app/native test binaries, resources, test scripts and fixtures travel in a temporary bundle. Small source inputs are included for fixture use and provenance, **not guest compilation**; host build caches and the development toolchain are not transferred. Source changes during build/packaging abort the run. Source/binary hashes are checked again in the guest.

Python gates are selectable except the compilation-based model mutation gate. Native shell gates currently ported are `terminal`, `text-checking`, and `browser-navigation`. The `web` gate receives a precompiled screenshot pixel checker. Other shell gates and the complete `verify-all.sh` sequence are not ported; do not execute that sequence on the host to compensate.

## Results and failures

Each run prints its host output directory under `artifacts/vm/<run-id>/`:

- `host-build.log`, `vm-exec.log`, per-test logs and screenshots.
- `receipt.json`: selected VM/tests, source and artifact hashes, guest directory, exit/cleanup/retrieval status.
- `results.json`: guest gate statuses when the guest runner completes normally.

Tests run sequentially under a VM-wide lock. A failed gate stays failed; a timeout returns **124**. SIGINT/SIGTERM cancellation is forwarded to VMPal, followed by a separate guest teardown check. The runner monitors owned process descendants and verifies their identities during cleanup; this is not containment for deliberately daemonizing or malicious code.

A forced cancellation may kill the guest runner before it writes `results.json`. The host still records a nonzero receipt and attempts to retrieve partial artifacts. Guest files are retained if retrieval/cleanup is incomplete, or with `--keep-guest`. If teardown cannot be confirmed, the lock at `/tmp/slate-ui-tests.lock` is retained. Inspect the receipt and owned guest processes before recovery; never break another run's lock automatically. `--timeout` sets the per-test deadline (600 seconds by default).

## Proven coverage and current limits

The actual runner passed `terminal`, `text-checking`, and `browser`, including real Ghostty/Metal rendering, native tabs/reparenting/input/cleanup, native text editing, and production WebKit navigation/JS/snapshots/store isolation. Captures were retrieved and the terminal pixels inspected. Evidence: `artifacts/vm/20261016T031205Z-55d6457a/`. A deliberate browser timeout returned 124; an actual host-runner SIGTERM returned 143, confirmed guest teardown and released the lock. Those receipts are `20261016T031250Z-02ce1790` and `20261016T031305Z-f737e0a2`.

The follow-up run `artifacts/vm/20261016T040246Z-61937331/` passed **both `browser-navigation` and `command-picker`** through the same host-build/guest-run workflow:

- `browser-navigation`: the standalone fixture now starts WebKit checks after AppKit finishes launching and runs its real application event loop. The existing five-second assertions and overall watchdog are unchanged. Delayed welcome/recipe callbacks, RPC/page supersession, cancellation, history, local HTML/CSS/JS/images/video in both browser modes, native address/recipe loading, bridge isolation and persistent-profile cleanup all passed.
- `command-picker`: the fixture now distinguishes the globally available `browser.clearData` action from pane-specific browser actions. It explicitly requires global clearing to remain enabled from a terminal, then checks an empty `reload page` query and verifies Return cannot execute it. The full picker gate passed, including focus/targets, mouse/keyboard execution, shortcuts, catalog/busy states, themes and windowless use.

These were fixture corrections, not product-behavior changes or relaxed deadlines. This is **not a full-suite pass**: other listed gates remain selectable but are not certified by these focused runs, and unported shell gates still need a host-build/prebuilt-guest split.

Window-free runner checks:

```sh
python3 -m unittest discover -s Tests/VMRunner -v
```
