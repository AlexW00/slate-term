# Welcome delivery reassessment

> **Decision record.** The recommended native inline welcome has since been built; see [welcome](../welcome.md) for current behavior.

This supersedes the recommendation in `shell-independent-welcome.md`. Research only; no onboarding, launcher, engine patch, or application change is implemented. This research did not modify the original checkout or installed app. The final status check showed unrelated concurrent changes in the original checkout; those were left alone. The cached engine still had no reported changes. Two isolated probes were run, including compilation of a standalone C test linked to an existing VT library; no engine or app was built or launched.

## Step back: remove an invented requirement

The user requested a concise welcome in new terminal panels, repeated until explicitly acknowledged through the CLI. **The user did not require terminal scrollback/capture.** The assistant introduced “terminal output above the first prompt,” then treated that presentation as mandatory. That unnecessarily biased the recommendation toward engine work.

**Recommend native inline welcome content first.** Place it above, not over, the terminal inside the pane. Leave the actual shell/surface untouched. `slate-term welcome` can still print the same shared content normally; `--read` can use the same host acknowledgement operation to stop future welcomes and remove visible native welcome areas. Removing native content is a proposed UI behavior, not erasing terminal history. Keep reset scoped to future sessions as previously proposed. Do not launch the CLI automatically to render native content.

This works independently of shell, shell integration, shell startup timing, and terminal clears. It is not a modal onboarding wizard. Its honest tradeoff is space: a bounded native area takes height from the terminal and is not part of its scrollback/capture. Narrow/small panes need compact presentation; layout compression must not count as acknowledgement.

If literal terminal output becomes an explicit requirement, there is also a credible **no-engine-fork launcher** option. The previous blanket rejection of launchers was incorrect.

## Source verification: native composition

Slate remains at `f5638ec`, on `investigate/shell-independent-welcome`. Review was limited to the existing research worktree. An independent reviewer challenged both native composition and launcher feasibility; key findings were checked directly against source.

- `Native/WorkspaceHost.swift:1639–1641` currently assigns the retained `TerminalView` directly as a generic controller's view. A content wrapper can compose native text with that same terminal. Keep `terminals[id]`, `ShellSession`, surface identity and all shell-launch configuration unchanged.
- `Native/PaneContainer.swift:104–133` already embeds a content controller beneath independent pane chrome and places inactive shading over the complete pane. Welcome content belongs inside that content region, not in the hideable header.
- **Required focus change:** `WorkspaceHost.focusResponder`, lines 1974–1977, currently focuses the leaf controller's root view. A wrapper must instead direct focus to `terminals[pane]`. This is not a drop-in label-only change. Welcome background clicks should focus the owning terminal without manufacturing a terminal mouse click; keyboard input should remain terminal-owned.
- **Required inspection change:** `WorkspaceHost.inspect`, lines 2818–2828, currently equates root bounds and first-responder identity with terminal bounds/identity. With a wrapper these must be distinguished; do not mask a focus failure by reporting the wrapper as the terminal.
- `TerminalView.setFrameSize` and `synchronizeGeometry` (lines 119–145) already forward actual terminal bounds to Ghostty. Removing/collapsing the welcome should resize, not recreate, the terminal.
- `WorkspaceHost.controller` (lines 1812–1824), `WorkspaceSplitController.paneHoldingPriority`, and `PaneContainer`'s optional text priorities constrain small splits. A pane can approach the 80-point minimum while its header consumes 28 points; a full multi-line welcome cannot be forced into every size. Do not let intrinsic text size override model split fractions. Prefer a bounded, compact/expandable representation when needed, keeping full text available through the CLI.
- Keep the native welcome tied to terminal-session creation, not focus/reparenting. Acknowledgement persists independently of content/view state; reset does not recreate sessions.

No architecture blocker was found. **Runtime visual layout, focus/IME, accessibility, resize and API parity remain unverified because no UI implementation exists.** These need focused validation after implementation is separately authorized.

## Reopened alternatives

### 1. Explicit shell integration plus compiled exec launcher: feasible candidate

The prior rejection correctly identified why a **naive wrapper with `shell-integration=detect` fails**, but incorrectly implied all wrappers need an engine modification.

The pinned engine supports forcing the actual shell type. `src/termio/Exec.zig:774–812` selects explicit bash/zsh/fish/elvish/nushell integration before constructing the process command. `shell_integration.setup` uses that selection instead of detecting the launcher basename. Bash and Nu preserve the executable while rewriting its subsequent arguments (`src/termio/shell_integration.zig:303–410,779–842`). A compiled launcher can receive those prepared arguments/environment, write a short message to its PTY stdout, and `exec` the configured real shell.

Necessary design constraints, not implemented or runtime-proven:

- The actual shell path and eligibility/payload must be conveyed out of band, not as extra shell arguments that Ghostty interprets or rewrites. Strip launcher-only environment before `exec` and avoid leaking stale routing data into nested sessions.
- The launcher must be a compiled executable, not a shell script whose interpreter could consume injected shell environment/startup flags.
- Preserve argv-zero login semantics, rewritten arguments, CWD, environment, PID continuity, exit behavior and signal/job-control behavior. `Exec.execCommand` still uses macOS login and the bash `exec -l` trampoline (`Exec.zig:1928–1959`). Forward shell arguments as an argv array, not reconstructed shell text.
- Preserve the **exact `/bin/bash` exclusion** in `detectShell` (`shell_integration.zig:137–159`). Forcing bash bypasses the exclusion; Apple's Bash disables the ENV startup path this integration relies on. Select `none` for that target, as today. Unknown shells and user integration-off also use `none`; displaying the welcome itself does not depend on integration.
- A helper named `bash` or `zsh` can trigger detection, but conceals the `/bin/bash` exception and is less explicit than target-aware selection. Not recommended as a detection trick.
- Avoid startup RPC: the host already knows eligibility. Handle optional banner-write failure without withholding the shell, use bounded output, and account for process launch failure separately. The proposed message is not a reason to wait for a CLI/socket.
- Banner output is before the real shell and its dotfiles. It may be cleared immediately. Existing CLI PATH repair should remain with the shell's existing integration.

This avoids a Ghostty fork, but requires packaging a launcher and maintaining a small shell-selection compatibility policy. Source evidence establishes feasibility, **not complete runtime compatibility**. Fish and Nu were not installed on this host, and no launcher was implemented or tested. If output is required, verify this option before choosing an engine extension.

### 2. macOS login/MOTD: wrong ownership and scope

Ghostty already invokes `/usr/bin/login`, with `-q` when it detects `.hushlogin`. Apple's login documents `/etc/motd` and quiet-login suppression, not an app-selected per-surface welcome-file option. Changing `/etc/motd`, PAM, or user hush settings would affect unrelated terminals and require inappropriate system/user startup modifications. Do not use this route. No system login files or settings were changed.

Primary sources: [Apple login manual](https://github.com/apple-oss-distributions/system_cmds/blob/8fcbc8dee07e730ee5ff089519a7f78befcb8aa5/login.tproj/login.1), [Apple login implementation](https://github.com/apple-oss-distributions/system_cmds/blob/8fcbc8dee07e730ee5ff089519a7f78befcb8aa5/login.tproj/login.c). These are published source references, not proof of the exact local OS binary revision.

### 3. Write the exported TTY slave: possible, unordered

`ghostty_surface_tty_name` exports the slave path. Writing a slave is output, unlike input-facing `ghostty_surface_text`. The private PTY probe below confirmed both directions on this Mac. But reopening a slave has no host-before-child barrier, and does not protect against partial escape sequences, changed termios, child exit, or path reuse. Waiting a fixed time or checking a process name does not establish prompt readiness. Stopping/signalling a child to manufacture a barrier would interfere with user process semantics. Not recommended.

### 4. Runtime pre-exec callback: not an existing embedder hook

`src/Command.zig:202–225` has internal post-fork/pre-exec callbacks after PTY stdio setup. `Exec.zig:1051` chooses them at compile time, and the embedded runtime/public `ghostty_runtime_config_s` exposes no equivalent callback. Using this would still be engine work and require fork-safe, preowned output handling—not Swift/AppKit or socket operations in a forked child. No advantage over native composition for this request.

### 5. Engine initial output: technically plausible, now a fallback

The original source trace remains valid: `Termio` is initialized before IO starts; just before `backend.threadEnter`, the parser and renderer infrastructure exist but the subprocess/read thread have not started. With a copied, creation-only, bounded plain-text payload, calling `processOutput` there can establish output-before-child parsing without changing shell startup.

The previous independent review identified genuine constraints:

- Output-only startup must allocate its own state even when there is no configured initial input.
- Do not free the shared startup arena before later initial-input writes have consumed its slices; clean up on failed or never-entered startup too.
- Restrict payload to printable UTF-8 and CR/LF. Terminal queries enqueue replies on a 64-message IO mailbox whose consumer has not started yet; a sufficiently query-rich payload can deadlock startup. Partial escape sequences can also alter later child output. A byte limit alone does not make arbitrary VT input safe.
- Parsing before the child is not a guarantee of a visible frame before the shell clears the screen.
- Requires an intentional, reproducible engine dependency/API change; never bypass `scripts/build-ghostty.sh`'s source-pin checks.

The probe below verifies terminal parsing properties, **not this unimplemented threading/ownership insertion**. Complete verification cannot be claimed without implementing and testing the extension. Since simpler alternatives meet the actual request, that work is not justified now.

## Runtime evidence from isolated probes

### Private PTY direction/order probe

`probes/pty-directions.py` creates its own PTY pair, enables raw mode, and uses only owned descriptors; no shells, user terminal devices or apps are involved. Executed with Python 3 and a 10-second outer command timeout. It passed:

- Slave writes are output readable at the master.
- Master writes are input readable at the slave.
- Reopening the slave and interleaving sequential writes can yield either `CHILD HOST` or `HOST CHILD`; reopening supplies no ordering barrier.

This is a controlled direction/order demonstration, not a race-frequency test or a live Ghostty-surface test.

### Existing VT library parser probe

`probes/output-parser.c` was compiled with `clang -Wall -Wextra -Werror`, using the pin's headers and the pre-existing `zig-out/lib/libghostty-vt.0.1.0.dylib`. Only the standalone probe executable was built, under ignored `artifacts/welcome-research`; no engine/app was rebuilt. All five assertions passed:

1. Feeding welcome + CRLF before shell text preserves that ordering.
2. Clear-display/home removes welcome text from the current screen.
3. Bare LF preserves the cursor column; direct output needs CRLF for these lines.
4. Injecting text between chunks of a CSI escape sequence changes/corrupts the intended injected text.
5. UTF-8 text containing `→`, `⌘K`, and Japanese survives byte-at-a-time input.

The library reports only `0.1.0-dev`. Its SHA-256 is `d58fec9bf082488ed53086a66ba293ec0b415fe0ee4dbb4fb82252302801c786`. **Build provenance does not establish that this cached binary exactly matches the inspected pin.** Therefore these results are empirical parser evidence for that identified library, not certification of pinned-engine startup or an implemented welcome. The standalone VT library is not a live-surface output API.

Logs: `artifacts/welcome-research/output-parser.log` and `library.sha256` (ignored local artifacts). Probe sources are retained with the research notes so the observations are reproducible. Compile using the inspected engine's `include` directory and `zig-out/lib` for `-I`, `-L`, and runtime rpath; link `-lghostty-vt`. No new dependencies were installed.

## Decision and remaining checks

1. **Native inline welcome is the smallest fit for the request as stated.** Share content/acknowledgement with CLI; do not alter shell startup or fork Ghostty. Explicitly accept the space/capture tradeoff before implementation.
2. **If actual terminal output is essential, investigate the explicit-integration launcher next.** It is a feasible source-backed route, not yet runtime-validated. Test all supported shell targets, integration off, `/bin/bash`, login/argv/CWD, PATH, signal/job control, immediate exit, startup clear and authenticated zsh run/wait preservation.
3. **Only then consider the engine extension.** Its lifetime/threading/API contract still needs implementation-level tests; source tracing and standalone parser probes cannot substitute for them.

For native UI, the future high-value checks are minimum-size and header-hidden panes, wrapping, compact/expanded content, keyboard focus/IME, VoiceOver, resize/zoom/reparenting without session replacement, shared CLI/plugin/service acknowledgement, restart persistence and content updates without acknowledgement reset. No such UI checks were run: there is no UI implementation.

Current primary Ghostty docs explicitly document forced shell integration: [shell integration](https://ghostty.org/docs/features/shell-integration), [configuration reference](https://ghostty.org/docs/config/reference). Decisions above are grounded in the inspected `554ea65867ffe34bb3e51e09bd016e154a1f9d7a` source, not merely current documentation. [PTY direction reference](https://man7.org/linux/man-pages/man7/pty.7.html) is Linux documentation; the private PTY probe provides the local macOS observation.
