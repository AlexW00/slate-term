# Saved layouts as separate macOS apps

Historical proposal: the implemented stable-shell design and verification are documented in [layout-apps-implementation.md](layout-apps-implementation.md). Statements below describe the planning baseline.

Status: **proposal; two reviews addressed; not implemented**. Written 2026-10-19 against main at `7757926`; revised after review against main at `17162fa`. Decisions marked "Review decision" were confirmed by Alex; other defaults remain recommendations. The software-update feature exists on the public repository's `main` (`AlexW00/slate-term`, `e474096`, release 0.3.0), not yet in this repository's `main` (`c39eeb4`). Sections 4 and 7 are written against the public `main` and the installed 0.3.0 release.

Milestone 0 platform experiments were run on 2026-10-19. Read the [HTML explanation](../../artifacts/layout-apps-spikes-20261019/layout-apps-results.html) and [empirical results](#appendix-milestone-0-empirical-results) before implementation. The copied runtime works without Hardened Runtime; the hardened variant fails library validation. A stable signing-identifier requirement preserves tested grants but also lets independently compiled replacement code inherit them. Spotlight remains unverified, and the App Management policy comparison did not trigger differential enforcement. Signing policy requires an explicit product decision. Product implementation has not started. Historical revisions above are not current checkout claims.

## Overview

Each layout app is a full copy of the installed Slate runtime, re-signed locally with its own bundle identifier. It runs on its own, but takes its configuration, plugins, and recipe from Slate Terminal.

```text
Slate Terminal.app (parent, updated by Sparkle)          Writing.app (own process, windows, Dock entry)
  Runtime ───────────── copied, auto-refreshed ─────────▶  Runtime copy (ad-hoc signed, own bundle ID)
  config.toml + palettes ── read live (read-only) ──────▶  Effective config = parent config + overrides.toml
  Installed plugins ───────── synced live ──────────────▶  Plugin copies (own registry)
  Layout library ──────── recipe for fresh openings ────▶  Session + browser logins (private)
  Plugin data ───────────── optional one-time copy ─────▶  Plugin data (private after creation)
```

| Thing | Behavior |
| --- | --- |
| Config, themes, palettes, plugin settings | Shared live from Slate; changes inside the app go to its own override file |
| Installed plugins | Synced live from Slate; changes that would close or replace open panes wait until those panes close |
| Source recipe | Read-only; used for first launch and fresh openings |
| Plugin data | Optional one-time copy at creation (on by default), then separate |
| Session, windows, browser logins | Separate per app |
| macOS permissions | Per app; Slate's grants do not carry over |
| Runtime version | Follows Slate automatically through refresh |

Sections 1–10 hold the full specification. Section 11 summarizes the UI changes, and section 12 lists known quirks and limitations.

## 1. Outcome

Creating an app from a saved layout should produce a local macOS application with its own name, icon, Dock entry, Cmd-Tab entry, process, windows, and saved session. Opening it must not create a window owned by the ordinary Slate Terminal process.

Example: Alex creates `Writing.app` from a layout containing a terminal and browser. Opening it from Spotlight starts Writing. Opening it again focuses Writing. Quitting Writing closes only Writing's windows and processes. Slate Terminal and a separate `Development.app` remain running.

**Review decision: creating from a layout always makes a separate app.** The creation dialog and `layouts.launcher` no longer produce small shortcut launchers. Existing shortcut bundles keep working, because Slate still handles their `slate-term://layout/UUID` URLs. They are not converted or deleted.

This document specifies the separate-app feature. The icon-picker and icon-export fixes are separate work. The `fix/launcher-icons` branch has no commits beyond main; the fixes exist only as uncommitted edits in the `launcher-icon-fixes` worktree, and their final native verification was blocked by the locked VM. Those edits change the shortcut bundle identifier to `com.slateterm.layout.<layoutID>.<random>` and rewrite `LayoutLauncherDialog`. Land them before extending the dialog in section 7, and keep the two bundle-identifier namespaces distinct. Do not treat those fixes, or this proposal, as a completed separate-app implementation.

## 2. Current behavior and implementation constraints

- [`Native/SavedLayouts.swift`](../Native/SavedLayouts.swift) creates an app containing the small launcher helper, icon, layout UUID, and parent Slate location/identity.
- [`Sources/SlateLayoutLauncher/main.swift`](../Sources/SlateLayoutLauncher/main.swift) sends `slate-term://layout/UUID` to Slate through `NSWorkspace` and terminates. Its activation policy is accessory; the generated bundle sets `LSUIElement`.
- [`slate-term/MyApp.swift`](../slate-term/MyApp.swift) starts the ordinary workspace host and forwards layout URLs to it. Its reopen handler shows the existing workspace.
- [`Native/WorkspaceHost.swift`](../Native/WorkspaceHost.swift) restores the workspace during initialization and creates a default terminal when starting with no tabs. `showWorkspaceWindow` also runs `window.new` when no window exists. All three behaviors need an explicit layout-app startup policy.
- A failed restoration currently returns a recovery workspace with autosave suspended (`ApplicationSettings.restore`). Layout apps replace this with a native alert (section 5).
- [`Native/SavedLayouts.swift`](../Native/SavedLayouts.swift) gates launchers, the Settings launcher panel, and layout URLs on `usesDefaultLibrary`, which is hard-coded to `~/.config/slate-term/layouts`. Recipe opening (`openSavedLayout`) is private and reads only the instance's own store.
- The control socket has a random name under `<base>/control`. The CLI finds an instance only through `SLATE_TERM_SOCKET` or `--socket`, so a terminal inside a generated app addresses that app, never the parent.
- The only state lease is `flock` on `state/workspace.lock`. Its failure message refers to `SLATE_TERM_STATE_DIR`, and startup then shows "Slate Terminal could not start" and exits.
- The existing launcher packaging ad-hoc signs with `codesign --force --sign -`. Release builds are notarized and use the hardened runtime. Nothing in the repository handles `com.apple.quarantine`.
- [`Native/ApplicationSettings.swift`](../Native/ApplicationSettings.swift) derives workspace storage and configuration locations. The default app state root is `~/Library/Application Support/SlateTerm`.
- The plugin registry/packages, durable plugin data, browser profile identifier, workspace restoration, and control socket currently depend on the app's state root. `PluginCatalog` assumes its writer holds the state lease. Merely starting another process with the same root is not safe.
- [`Native/BrowserData.swift`](../Native/BrowserData.swift) already supports a named persistent browser profile per state directory. It should remain the authoritative implementation.
- [`docs/saved-layouts.md`](saved-layouts.md) defines recipes and startup-command behavior. A recipe is not a snapshot of terminal processes, browser authentication, or durable plugin data.

Apple documents that [`LSUIElement`](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement) hides an agent app from the Dock. Removing that flag alone is insufficient here: the helper still exits, and the ordinary Slate process still owns the windows.

## 3. Scope

### Included

- Local app creation from layouts in the default Slate library.
- Terminal, browser, private-browser, and supported registered-plugin panes.
- Persistent, distinct application identity and isolated mutable state.
- Reopen, window-close, quit, restoration, startup failures, and runtime refresh.
- Native controls and equivalent trusted CLI/plugin/service operations.
- Real macOS launch, icon, Dock, Cmd-Tab, and lifecycle verification in VMPal.

### Excluded

- App Store distribution, notarization services, or independently distributed products.
- Arbitrary custom-config origins in the first version.
- Live sharing of terminal processes, browser cookies, plugin data, or workspace state with another Slate instance. Configuration and installed plugins do follow the parent (section 6).
- Converting existing shortcuts in place, deleting app data, or automatically moving windows between apps.
- A new terminal engine or a shared-runtime-framework extraction. Section 4.1 explains why. The only shared-runtime variant worth revisiting is a tiny stub plus a per-app APFS clone of a versioned runtime.
- Automatically installing or refreshing global agent skills from each generated app.

## 4. Recommended architecture

### 4.1 Package the existing native runtime

For the first version, build each generated app from the installed Slate runtime. In the 0.3.0 release it contains the native executable, two helpers (`Contents/Helpers/slate-term`, `Contents/Helpers/slate-layout-launcher`), resources, and these frameworks in `Contents/Frameworks`: `SlateArchive`, `SlateTermCore`, `SlateTermIPC`, `SlateTermSettings`, the TOMLDecoder package product, and `Sparkle`. `Sparkle.framework` contains its own nested code: `Autoupdate`, `Updater.app`, and the `Downloader.xpc` and `Installer.xpc` services. GhosttyKit is linked statically. Configure that runtime through a small, versioned bundle manifest. The generated app's executable must own its native windows directly.

Do not use a resident decorative helper that launches ordinary Slate windows. Do not rely on executable symlinks or changing the ordinary process's Dock icon to simulate an independent application.

Use Foundation's `FileManager.copyItem`; it already clones on supported APFS volumes and remains correct when copying is required. The isolated APFS measurement retained about 31.5% savings after signing: 26.0 MiB per copied app versus 38.0 MiB for byte copying. Explicit cloning offered no meaningful additional saving. These are measurements of the inspected runtime on one volume, not a future-release capacity guarantee (appendix). Running apps must not depend on mutable files inside the parent bundle.

**Review decision: copy the runtime; do not load a shared runtime framework.** A second review compared three options:

- **Copy (chosen).** Each app holds its own runtime copy. Nothing changes under a running app.
- **Stub plus shared framework.** Each app is a tiny stub that loads Slate's runtime from the installed Slate.app. Rejected for these reasons:
  - Slate updates replace the whole parent bundle, through Sparkle's installer on quit or by hand. A running layout app would keep its old code in memory but start the new `Contents/Helpers/slate-term` and shell-integration scripts for each new terminal. One process tree would then mix versions. An in-place overwrite can also kill the process on the next code page-in.
  - An ad-hoc stub can load a Developer ID framework only with library validation disabled. That needs the `com.apple.security.cs.disable-library-validation` entitlement or a stub without the hardened runtime. Chromium's shims accept this trade-off (`web_app_shortcut_creator.mm`).
  - Nine `Bundle.main` lookups would need a runtime-bundle redirection. The stub entry point would become an interface frozen for every app ever created.
  - Layout apps would stop working whenever Slate is moved or deleted.
- **Chrome-style hybrid.** The stub only hosts windows, and the main Slate process owns the logic. Rejected because quitting Slate would end every layout app's terminals. It also needs cross-process window hosting.

Before broad implementation, prove that this packaging approach retains the generated bundle's identity under Launch Services and that resources resolve from the generated bundle. Prove that the locally re-signed runtime launches from a notarized, quarantined release parent, not only from a local Debug build. A Debug build has no quarantine attribute and a development signature, so it cannot pass for the release case. These are acceptance gates, not assumptions.

Signing rules for the gate:

- The project has no `.entitlements` file, injects no base entitlements, and disables App Sandbox. Do not invent entitlements for the generated app.
- Re-sign inside out: Sparkle's XPC services, `Autoupdate`, and `Updater.app`; then every framework; then both helpers; then the bundle. The tested ad-hoc variant with `--options runtime` passed strict static verification but failed to launch. Do not prescribe that flag as a working production configuration.
- Every nested framework and the main executable are independently ad-hoc signed with no Team ID. In the VM, hardened-runtime library validation rejected Sparkle with “different Team IDs.” The fallback without `--options runtime` ran independent terminals and the copied CLI helper. This removes more protections than library validation alone. Production must explicitly accept that trade-off or revise packaging; the experiment does not silently select the policy. No `disable-library-validation` entitlement was added.
- The generated bundle is user-created local content. Do not copy `com.apple.quarantine` onto it; remove the attribute from the staged copy before signing.
- Verify the result with `codesign --verify --deep --strict` and a real Launch Services launch from Finder and Spotlight.
- Choose the designated requirement explicitly using the observed permission matrix in the appendix. The default ad-hoc requirement lost Documents, Accessibility, and Full Disk Access continuity after a changed payload and fresh process. Notification authorization/delivery and the Automation authorization check survived in this VM. The explicit requirement `-r '=designated => identifier "com.slateterm.layoutapp.<layoutAppID>"'` retained every tested grant, but independently compiled replacement code using the same signing identifier and installed path inherited those grants too. This requirement establishes no publisher identity. Do not silently adopt it as a general permission-preservation fix or extrapolate the matrix to every macOS version or permission.

### 4.2 Identity and manifest

Assign a fresh `layoutAppID` UUID for each creation. It is distinct from the source `layoutID`. Two apps created from the same layout have separate identities and state. Renaming or moving an app preserves its `layoutAppID`.

Proposed manifest fields:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Supported manifest format, initially 1 |
| `layoutAppID` | Persistent generated-app identity |
| `layoutID` | Source recipe UUID |
| `libraryKind` | `default` in the first version |
| `name`, `icon` | Creation choices using the existing name/icon validation |
| `parentBundleID` | Parent discovery through Launch Services |
| `runtimeVersion`, `runtimeBuild` | Embedded runtime provenance; rewritten only by refresh, which re-signs anyway |

Info.plist and `Contents/Resources` are sealed into the signature. Any change inside the bundle forces a re-sign, with the permission effects described in section 4.1. Keep values that change outside refresh in the layout-app root, not in the bundle. One example is `parentPathHint`, the last known parent location, which is a hint and not authority. Renaming an app or changing its icon is a re-sign and follows the same rules as refresh.

Use a bundle identifier such as `com.slateterm.layoutapp.<layoutAppID>`. Keep this namespace distinct from shortcut launchers (`com.slateterm.layout.*`). Set the display name and icon from the chosen values; use regular application activation.

The copied runtime's Info.plist contains `CFBundleIconName = AppIcon`, and `Assets.car` contains the Slate icon. macOS prefers that asset-catalog icon over `CFBundleIconFile`. Remove `CFBundleIconName` and write the chosen icon as `LayoutIcon.icns` with `CFBundleIconFile`, as shortcut launchers do. Verify the icon macOS reports for the copied-runtime bundle, not for the small launcher.

Name the persistent identity `layoutAppID`. The existing `appID` and `appInstanceID` names already mean the ephemeral per-launch instance (`BackgroundServices`, `PluginControlConnection`). Derive mutable state paths from the validated `layoutAppID`, not arbitrary paths embedded in metadata.

The generated bundle must not claim the ordinary `slate-term://` URL scheme, document associations, or other parent-only integrations. Audit copied metadata and startup services. Exclude the parent's updater configuration: remove the Sparkle keys `SUFeedURL`, `SUPublicEDKey`, `SURequireSignedFeed`, `SUVerifyUpdateBeforeExtraction`, `SUSignedFeedFailureExpirationInterval`, `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, `SUAllowsAutomaticUpdates`, and `SUEnableSystemProfiling` from the generated Info.plist. `Sparkle.framework` stays, because the runtime links it, but it never runs in layout-app mode (section 7). Also exclude global installation maintenance. Sign nested code and the final bundle in the required order; do not copy a stale signature and assume it remains valid.

### 4.3 One explicit startup context

Introduce a typed startup context resolved before constructing `ApplicationSettings` or `WorkspaceHost`:

```swift
enum ApplicationLaunchContext {
    case standard
    case layoutApp(LayoutAppDescriptor)
}
```

The descriptor is validated bundle metadata. Do not model production layout apps by setting integration-test environment variables. Sanitize inherited pane, socket, session, invocation, and service identity just as ordinary startup does.

The layout-app root is `<parent base>/LayoutApps/<layoutAppID>`. In production, the parent base is always `~/Library/Application Support/SlateTerm`. Only when `SLATE_TERM_INTEGRATION=1`, the generated app takes the parent base from `SLATE_TERM_STATE_DIR`. Integration fixtures pass both variables through `NSWorkspace.OpenConfiguration.environment`, so real Launch Services launches stay isolated. Production launches ignore these variables.

Resolving the layout-app context also runs the self-refresh check before `ApplicationSettings` or `WorkspaceHost` is constructed. Acquire exclusive state ownership before plugin sync, initial state writes, migrations, or watchers. Plugin sync still finishes before workspace construction; it must not write the local registry merely because context resolution has started.

### 4.4 Application name in user-facing text

A generated app must call itself by its own name. Today about 20 strings hard-code "Slate Terminal". Add one `appDisplayName` value to the launch context. It is the layout app's name in layout-app mode and "Slate Terminal" otherwise. Pass it to the code below instead of the literal.

Strings that name the running app use `appDisplayName`:

- App menu title, "About …", "Quit …" (`Native/WorkspaceHost.swift:2740-2760`). The About panel also shows "Built on Slate Terminal" and the runtime version.
- Startup failure alert and stderr text (`slate-term/MyApp.swift:58-61`).
- Default tab title (`Sources/SlateTermCore/TabTitle.swift:5`) and the rename hint (`Native/TabRenameController.swift:53`).
- Plugin control prompt "Allow … to control …" (`Native/WorkspaceHost.swift:3370`) and the close-warning reset hint (`:3559`).
- Plugin settings text (`Native/SettingsWindow.swift:601`).
- Lease and instance errors (`Sources/SlateTermSettings/WorkspaceStore.swift:30`), replaced by the layout-app messages from section 5.

Strings that name the product or the parent app keep "Slate Terminal":

- Agent skill and CLI text (`SettingsWindow.swift:681-708`, `AgentSkills.swift:158`, `SlateTermCLI`, `SkillSetup.swift`). The skill and CLI belong to the parent product.
- "Managed in Slate Terminal" and other parent-only explanations.
- The welcome content (`Welcome.swift`), which generated apps do not show.

Add a regression check that greps the native and core sources for the literal "Slate Terminal". Allow it only in the parent-product list above, so new hard-coded names fail review.

### 4.5 Startup preparation

Split startup preparation from default-window creation so a layout app can restore or open its recipe without first creating an unwanted terminal window. Reuse the existing recipe validation, resource preparation, commit, and startup-command machinery.

## 5. Proposed lifecycle behavior

| Trigger | Required behavior |
| --- | --- |
| First launch | Read the latest valid source recipe; open exactly one recipe workspace in this app |
| Cold launch with a saved session | Restore this app's own session using normal restoration rules; do not replay recipe commands |
| Cold launch with restoration disabled or no remaining windows | Open the latest source recipe once |
| Open again while windows exist | Focus this app's existing workspace; do not create another instance or rerun commands |
| Close the last window | Keep the app running, consistent with ordinary Slate behavior |
| Reopen while running without windows | Open the latest source recipe once. In layout-app mode, `showWorkspaceWindow` opens the recipe instead of running `window.new` |
| New-window/tab commands | Create content owned by this app, using existing Slate behavior |
| Quit | Apply existing running-process confirmation; close only this app's resources |
| Source recipe edited | Affect the next fresh recipe opening; do not rewrite live or restored sessions |
| Source recipe missing/invalid, valid session exists | Restore the session; report the source problem when a fresh recipe opening is requested |
| Source recipe missing/invalid, no session to restore | Show a native macOS alert naming the layout and the problem, then quit. Do not substitute an empty/default Slate workspace |
| Missing plugin dependency | Use existing dependency preflight/error behavior; never silently replace the pane type |
| Corrupt saved session | Show a native macOS alert, then quit without writing state (see below). Do not open a recovery workspace, erase the file, or replay startup commands |

**Review decision: corrupt sessions use a native alert.** Layout apps do not use the ordinary recovery workspace. Before any window opens, show an `NSAlert` with these contents:

- What failed: the saved session for this app could not be restored.
- The preserved file's path. Add a **Show in Finder** button that reveals it.
- How to recover: quit, move the file aside, and reopen the app to start fresh from the recipe.

The default button is **Quit**. After the alert closes, the app quits without saving, so the file stays untouched. Integration mode writes the same message to stderr instead of showing the alert, as startup failures do today.

Opening an app twice must not create two writers for its state. Use both normal Launch Services application reuse and a per-app state lease. A direct second launch that cannot take the state lease activates the verified lease owner through `NSRunningApplication`, then exits without an alert. Match the recorded PID and process-start identity, layout-app identity, and state root; a bundle-ID match alone can select the refresh coordinator or a Finder copy. If no verified owner is found, it shows a layout-app message ("Writing is already open or is being refreshed"), not the `SLATE_TERM_STATE_DIR` hint. Never fall back to whichever Slate instance is focused.

Refresh holds a separate `maintenance.lock` in the layout-app root. Startup acquires the state lease while still holding maintenance, then releases maintenance before initializing the workspace. Otherwise an updater could observe free state between the two acquisitions and replace a starting app. If refresh holds maintenance, an ordinary startup shows "Writing is being refreshed; try again when it finishes" and exits. An explicitly coordinated replacement uses the handoff path in section 7. Keep both lock files at stable paths; do not recreate them while processes may hold their inodes.

A Finder copy of a generated app keeps its manifest and bundle identifier, so both copies share one state root. The state lease lets only one copy run at a time. Management reports the duplicate as a diagnostic (section 7), and refresh refuses while the identity is ambiguous.

Commands run once per accepted fresh recipe opening, through the existing authenticated shell-readiness flow. A repeated OS activation or an uncertain launch response is not permission to replay them.

## 6. Storage ownership and configuration

Proposed root:

```text
~/Library/Application Support/SlateTerm/LayoutApps/<layoutAppID>/
    config/          # per-app configuration overrides and local layout library
    plugins/         # this app's registry and package copies, synced from the parent
    state/           # workspace, browser profile ID, plugin/panel data, preferences
    control/         # this app's control sockets
    parent.json      # last known parent location (a hint, not authority)
    maintenance.lock # refresh/startup coordination (section 5)
```

| Resource | Proposed ownership |
| --- | --- |
| Workspace, window geometry, counters, panel restoration | Private to `layoutAppID` |
| Browser profile/cookies | Private to `layoutAppID`; private-browser panes remain ephemeral. WebKit stores data per bundle identifier, so sharing is not possible |
| Durable plugin data | Private to `layoutAppID`. Optionally copied once from the parent at creation (see below), then separate |
| Plugin processes, managed services, command runs | Private to the live app instance |
| Configuration and palettes | Shared: read live from the parent, with per-app overrides (see below) |
| Installed plugins | Synced from the parent at each launch (see below). Installing, updating, and removing happen only in the parent |
| Original saved recipe | Read from the parent default library for fresh startup; never mutated implicitly |
| Layouts created/edited inside the generated app | Its local layout library; separate from the source recipe |
| User-selected project files and plugin-owned external services | Keep existing explicit references; these are not automatically isolated |
| Welcome state (`state/welcome.json`) | Seeded as acknowledged, so generated apps do not show the inline welcome |
| Notification authorization | Owned by macOS per bundle identifier. Each app requests it from its own Settings. Expected to survive refresh, because the bundle identifier stays the same (verify in milestone 1) |
| Privacy grants (Full Disk Access, Files & Folders, Accessibility, Automation) | Owned by macOS per designated requirement. Each app asks once. Whether grants survive refresh depends on the requirement chosen in section 4.1 |
| Agent skills | Owned by the parent. Settings → AI Agents in a generated app shows skills as managed by Slate Terminal, without install actions or conflict errors |

**Review decision: share configuration and plugins, keep data separate.** Configuration and installed plugins follow the parent, so layout apps do not drift. Things that cannot be shared safely stay separate: browser logins, plugin data, and sessions.

Configuration:

- The layout app reads the parent's `~/.config/slate-term/config.toml` and `palettes/` read-only. It reloads them through the existing `ConfigurationWatcher`, as Slate does today.
- Changes made inside the layout app go to `config/overrides.toml` in its root. The effective configuration is the parent's configuration with these overrides applied on top. Plugin settings under `[plugins.<id>]` follow the same layering.
- The layout app never writes the parent's files, so there is still one writer per file.
- An unreadable or invalid parent configuration uses the existing configuration-error behavior. The overrides still apply where they are valid.

Plugins:

- The layout app keeps its own `PluginCatalog` and package copies, so it is the only writer for its registry.
- At each launch, before the workspace starts, it reads the parent's registry read-only and syncs to it. While running, it watches the parent's `plugins/registry.json` and syncs again on every change. A missing or changed plugin is re-prepared from the parent's retained `package.zip` through the normal package store. A plugin removed in the parent is removed locally. The `enabled` value follows the parent.
- While running, the layout app applies parent changes as if the user had made them in its own **Settings → Plugins**, with the same live behavior Slate has today (`docs/plugins.md`):
  - **Install or enable:** applied immediately. New pane types and commands appear without a restart.
  - **Update (replacement) or remove/disable** when none of that plugin's panes are open: applied immediately.
  - **Update or remove/disable while that plugin's panes are open in the layout app:** deferred. Slate refuses replacement with visible panes, and closing panes in another app without asking is not acceptable. The change applies when those panes close, or at the next launch. The Settings footer shows "1 plugin change waiting for open panes to close."
- The layout app copies a new package as soon as it sees the change, so a later removal in the parent cannot pull files from under it.
- If a parent package cannot be read or validated, keep the existing local copy and record a diagnostic. Retry on the next registry change or launch.
- If the source recipe needs a plugin that is unavailable after sync, use the existing dependency error.
- Installing, updating, and removing plugins are disabled in the layout app, like the other parent-only controls (section 8).

Plugin data:

- The creation dialog offers **Copy plugin data from Slate Terminal**, checked by default.
- When checked, creation copies the parent's `state/plugin-data-v2/<id>.json` files for the synced plugins. The parent writes these files by atomic rename (`PrivateJSONStore`), so a copy while the parent runs reads a complete version.
- The copy is a one-time starting point. Afterwards, changes in the layout app and in the parent do not reach each other.
- When unchecked, plugin data starts empty.
- Update `docs/plugin-persistence.md` and `docs/saved-layouts.md`, which currently describe launchers reconnecting to shared plugin data.

Do not copy terminal history, browser profiles, or panel restoration. Do not put configuration or credentials into the distributable app bundle.

Keep this visible but quiet. The **Layout app** section in Settings (section 8) carries one caption: "Settings and plugins come from Slate Terminal. Writing keeps its own browser logins and plugin data." Do not label individual settings. A setting that has a per-app override shows a **Reset** action, and nothing else.

Separate the read-only startup recipe source from the app's own editable library. Read the definition through a read-only `SavedLayoutStore` on the parent default library. Pass it to the same recipe-opening implementation, `openSavedLayout(definition, operation:)`, which becomes callable from startup. Evaluate `problems(types:)` against the app's own plugin registry. Existing plugin-relative resources and starting configuration must resolve against the app's synced package copies. Plugins that intentionally use global files, fixed ports, or external services retain those behaviors; app identity is not a sandbox guarantee.

A generated app's own library is not the default library, so the existing `usesDefaultLibrary` gate would disable launchers there. Keep that outcome, but make it intentional: launcher and app creation are parent-only (section 8). Generated apps do not claim `slate-term://`, so `openLayoutURL` never runs in them.

## 7. Creation, management, and refresh

### Creation

Keep the existing creation dialog without a mode switch; it always creates a separate app. Keep existing name/icon choices and non-overwriting destinations. Before creation, explain in one line that separate apps have their own session, browser logins, and plugin data. Show the **Copy plugin data from Slate Terminal** checkbox (section 6), checked by default. List any parent plugins that are unavailable and will not be synced.

Prepare the runtime bundle and initial private state in staging locations. Validate resources, manifest, synced plugin inventory, copied plugin data, executable permissions, signature, and destination before publication. Register the completed bundle with Launch Services only after publication.

Publishing an app, initial state, and management record spans multiple filesystem effects. Do not advertise a transaction across them. Specify ordering and bounded cleanup of newly owned staging and initial-state files. If cleanup or registration fails after an app exists, return that actual outcome and path; do not encourage blind recreation retries.

Maintain a private registry of generated app identities, last known locations, and runtime versions. Moving an app must not change state ownership. Resolve moved apps through Launch Services and validate the resolved manifest before management operations. Treat missing, duplicate, or conflicting identities as explicit diagnostics; never choose an arbitrary bundle to overwrite.

### Refresh

**Review decision: refresh is automatic.** Users should not need to think about runtime versions. A layout app picks up the installed Slate runtime the next time it starts. A running app is never refreshed or restarted under the user.

Refresh replaces only the embedded runtime and runtime metadata, then re-signs the bundle. It preserves the bundle identity, name, icon, source layout reference, configuration overrides, plugin copies, plugin data, and saved state. Plugins are synced separately at launch (section 6), so after refresh the runtime and plugins come from the same parent version.

Refresh has three triggers that share one implementation:

1. **Self-refresh at launch.** While resolving the launch context (section 4.3), the layout app compares its `runtimeBuild` with the installed parent's build. This happens before `ApplicationSettings` or `WorkspaceHost` exist, so no shell, plugin process, or service has started. If the parent is newer, the app:
   - takes `maintenance.lock`, then temporarily reserves the state lease without blocking. If an existing workspace owns state, it activates that verified owner and exits without refreshing;
   - builds, signs, and validates a replacement on the same volume, revalidates the target, and records a prepared refresh journal;
   - swaps the bundle directories with `renamex_np(RENAME_SWAP)` and records the actual installed and retained revisions. Retaining loaded code does not establish safe later resource access;
   - records a pending handoff token and requests `createsNewApplicationInstance = true`. The replacement validates its loaded revision and token, records a bootstrap acknowledgement, then waits for maintenance with a bounded timeout;
   - after validating that acknowledgement, releases its temporary state reservation and exits. The replacement takes maintenance and its own state lease, records handoff acceptance, and only then initializes settings, plugins, and the workspace.

   The old coordinator never initializes runtime state or retains a state lease across handoff. Launch Services completion is not workspace readiness. Other refreshers defer while the handoff is pending; ordinary launches reconcile that record rather than starting another refresh. Keep both event loops responsive and retain the old bundle until its process identity has exited. This ordering is a design requirement awaiting product concurrency/recovery tests. Cost: one extra launch on the first start after a Slate update.
2. **Parent catch-up.** When the parent starts with a newer runtime than a stopped layout app, it refreshes that app in the background. When a running layout app quits, the parent refreshes it if the parent is running. These refreshes only reduce how often trigger 1 runs. Correctness does not depend on them.
3. **Manual repair.** **Refresh App** in the parent's generated-app list remains for recovery and diagnostics, not for normal use.

A running layout app that sees a newer parent shows "Update ready, applies next time you open Writing" in its **Layout app** Settings section. It shows nothing else. It checks the parent build when it becomes active.

Rules for every trigger:

- Stage and validate a complete replacement. Under `maintenance.lock`, take a temporary state-lease reservation so startup cannot become a writer during replacement. All startup paths use the same lock order. Revalidate the unique target path, identity, and expected bundle revision immediately before the swap.
- Recover or report an interrupted replacement without deleting the user's state. Reconcile the journal with both actual bundle revisions; do not repeat a completed swap. If handoff fails after the swap, retain both bundles and diagnose the replacement. Do not resume the old process at a path now containing new resources. Rollback requires no state owner and explicit schema compatibility.
- Reject incompatible state-schema downgrades. If the parent is older than the layout app, keep the layout app's runtime.
- **App Management:** the milestone 0 native self-swap and signed-caller replacements succeeded with an empty App Management list. Both policy and no-policy targets succeeded, so the experiment does not establish that `AllowProcesses` enabled the operation. The signed probe used an Apple Distribution certificate, not the actual parent's Developer ID execution path. Verify the implemented caller and target policy in milestone 1 and retain explicit refusal handling. Before any successful swap, refusal can fall back to the intact current runtime with the "Update ready" line; after a swap, use journal recovery rather than resuming old code at the replaced path.
- **Privacy grants:** changed code using the default code-hash requirement can lose authorization continuity (section 4.1). After refresh, explain renewal where a permission's supported readback establishes it is needed. Do not promise a complete inventory of lost grants without a supported way to inspect each permission.
- Generated apps never run the parent's own update flow. They only copy the installed parent's runtime.

**Review decision: Check for Updates checks for a refresh in layout apps.** The parent's update feature (`docs/updates.md` on the public `main`) uses Sparkle 2.10 with explicit, user-started checks. **Slate Terminal → Check for Updates…**, Cmd-K, the CLI, registered pages, and services all share `updates.get/show/check/download/cancel/install` and the `host.updates.changed` event. `UpdateController` reads its feed from the bundle's `SU*` keys. With those keys removed (section 4.2), a layout app would report `unavailable`.

In layout-app mode, keep the same command, window, and methods, but back them with the refresh check instead of Sparkle:

- The app menu item reads **Writing → Check for Updates…**. It opens the same Software Update window and never contacts the network. `UpdateController` does not create an `SPUUpdater` in layout-app mode.
- `updates.check` compares the app's `runtimeBuild` with the installed parent's build:
  - **Parent newer:** phase `ready`, with the parent's version as `release.version` and the parent's notes if available. The primary button is **Restart Writing**, which maps to `updates.install`. It uses the normal running-process quit confirmation, then relaunches; self-refresh (trigger 1) applies the update before any process starts. Declining the confirmation leaves the update ready for the next launch.
  - **Same build:** phase `current`, with "Writing is up to date with Slate Terminal <version>." A secondary button, **Open Slate Terminal**, opens the parent so the user can check for new Slate releases there.
  - **Parent missing, or older than the app:** phase `unavailable`, with "Writing can update when a compatible Slate Terminal is installed."
- `updates.download` and `updates.cancel` have nothing to do in layout-app mode. They fail with the existing disallowed-phase error (`-32051`).
- `updates.get` and `host.updates.changed` report the refresh state with the same snapshot shape. Clients do not need a separate contract. `api.describe.updates` states that the session is a layout-app refresh check.
- The quiet "Update ready" line in the **Layout app** Settings section (above) is the same state. A running app updates this state when it becomes active.

Real network updates stay in the parent. After Sparkle installs a new parent and relaunches it, parent catch-up (trigger 2) refreshes stopped layout apps. Running apps show the ready state and update at their next launch.

The embedded runtime keeps working if the parent is moved or removed. Refresh and plugin sync need a compatible parent installation. Without one, the app runs on its current runtime and plugin copies. A fresh recipe opening also needs the source recipe; existing restored sessions follow section 5.

## 8. Native and automation contracts

Implement app creation/refresh once in authoritative operations, used by the native UI and shared public dispatch. Do not build a second packaging path in the CLI or plugin bridge.

Proposed API additions, subject to contract review:

| Operation | Contract direction |
| --- | --- |
| `layouts.launcher` | Always creates a separate app; there is no `mode` parameter. Existing `id/path/name/icon` validation remains. Results include `layoutAppID`, path, and runtime version. This changes the result of an existing method, so document it as a breaking change in the release notes |
| `layoutApps.list` | Bounded management records with availability, runtime version, and running/stopped status; no secret configuration |
| `layoutApps.refresh` | Explicit `layoutAppID` and expected bundle revision; reject running, stale, ambiguous, unavailable, or incompatible targets |
| Instance discovery/context | `context get` and `api.describe` report standard vs layout-app mode and the persistent `layoutAppID`, separately from ephemeral `instanceID` |

Update typed contracts, schemas, capability discovery, CLI options, plugin/service adapters, documentation, and parity tests together. All runtime commands remain scoped to their target instance. Export each terminal's own socket/instance/pane context and validate explicit stale/wrong-instance guards.

**Review decision: creation and management are parent-only.** `layoutApps.*`, `layouts.launcher`, and app creation work only in standard Slate. A terminal inside a generated app reaches only that app, and there is no well-known parent socket. In a generated app these operations return one typed error that names the parent ("Manage layout apps from Slate Terminal"). `api.describe` marks them unavailable in layout-app mode.

**Review decision: disable parent-only controls and explain them in the Settings footer.** Do not add per-control locks, symbols, or tooltips.

- Settings shows a **Layout app** section with the app name, source layout, and runtime version. It holds the one caption from section 6 and, when relevant, the "Update ready" line from section 7.
- On pages with parent-only controls (Plugins, Layouts), those controls are simply disabled: install, remove, update, enable toggles, the launcher action, the generated-app list, and Refresh.
- The existing sticky Settings footer (the bar with **Show Config File**, **Revert**, and **Apply**) shows one status line on those pages: "Plugins and layout apps are managed in Slate Terminal." The Layouts page, which hides that footer today, shows it in layout-app mode for this status.
- **Show Config File** reveals the app's `config/overrides.toml`.
- Cmd-K omits the parent-only commands in layout-app mode.
- The CLI and API error uses the same wording.

Use the existing native launcher action to open the name/icon dialog; management actions live beside the generated-app list. Parameterized operations need not become argument-free Cmd-K commands. Review any command availability restrictions as resource/state constraints, not separate client privileges.

## 9. Implementation milestones

0. **Platform spike on the VM, before any product code.** An agent tests the unproven platform behavior empirically in VMPal, using the downloaded, notarized 0.3.0 release and hand-built bundles. No Slate source changes. Record its results, with commands, readback, and screenshot references, in the appendix of this document. It answers these questions:
   - A copied, ad-hoc re-signed 0.3.0 bundle with its own bundle ID launches from Finder and Spotlight, with its own Dock/Cmd-Tab entry and icon.
   - Compare hardened and non-hardened loading of the re-signed runtime. Record which nested components actually execute; static verification of unused Sparkle updater helpers is not an execution pass. Keep the updater inactive in layout-app mode.
   - Privacy grants (Full Disk Access, Files & Folders) and notification permission survive a re-sign, with the default code-hash requirement and with an explicit identifier requirement.
   - App Management: one app replacing another app's bundle in `~/Applications`, and an app swapping its own bundle with `renamex_np(RENAME_SWAP)`, without a granted App Management permission.
   - Disk cost of `clonefile` compared with a plain copy.

   The results decide the signing requirement, the hardened-runtime choice, and whether automatic refresh is viable. If identity or launch fails, revise the architecture before milestone 1.
1. **Implemented packaging and identity:** after choosing the signing policy, implement the production manifest and packaging path. Reproduce milestone 0's process/window ownership, Finder launch, Dock/Cmd-Tab icon, terminal/helper loading, warm reopen, and independent Quit checks using that path. Complete the unresolved Spotlight cold-launch check in a working Spotlight environment. Verify the actual parent refresh caller and refusal handling; a differently signed standalone probe cannot certify it. Recheck permission behavior when the implementation changes the tested identity or replacement mechanism. Do not repeat platform experiments merely to fill a second milestone, or treat standalone success as a product implementation pass.
2. **Startup and state:** add typed launch context, layered configuration, plugin sync, optional plugin-data copy, state leases, recipe startup without a default-window flash, restoration, and failure handling. Prove concurrent parent and two generated apps cannot share writers or misroute commands.
3. **Product and parity:** implement app creation, management records, native list/actions, public contracts, adapters, and documentation. Land the picker/icon fixes from the `launcher-icon-fixes` worktree first; they are not on main.
4. **Refresh and qualification:** implement self-refresh, parent catch-up, manual repair, and recovery, then run lifecycle, parity, regression, and independent visual checks.

Keep milestone results distinct: a bundle that builds or launches once is not proof of app identity, restoration, refresh safety, or Spotlight behavior.

## 10. Observable acceptance checks

Build on the host; run native checks only in VMPal under the repository's VM lease. Register appropriate new gates in `scripts/verification_gates.py`. Use isolated fixture configuration, recipes, app bundles, clipboards, and process ownership. Do not modify Alex's installed Slate or real launchers as test fixtures. Launch generated fixture apps through Launch Services with the integration variables from section 4.3, so they never write to the VM user's real Application Support.

- **Identity:** Spotlight and Finder show the selected name/icon. Dock and Cmd-Tab identify the generated app. Window-owner PID and bundle identity belong to that app, not ordinary Slate. Capture fresh rendered evidence and native process/window readback.
- **Signing:** create an app from a notarized, quarantined release parent. The generated bundle has no quarantine attribute, passes `codesign --verify --deep --strict`, uses the explicitly approved signing policy, and launches from Finder and Spotlight. The tested ad-hoc hardened-runtime configuration is a known failure, not an acceptance requirement that can currently pass.
- **Input/export:** every icon tile responds at its center and padded area; selected state and exported icon agree. Inspect icons that macOS reports for a copied-runtime bundle, not just file headers or the small launcher. Test name validation and existing-destination refusal.
- **Parent-only operations:** from a terminal inside a generated app, `layoutApps.*` and `layouts.launcher` return the typed error. Settings shows the Layout app section. The parent-only controls are disabled, the Settings footer shows the managed-in-Slate status, and Cmd-K omits those commands.
- **App name:** the menu bar, About panel, Quit item, default tab title, and alerts use the layout app's name. The literal-name regression check passes.
- **Per-bundle permissions:** after authorization in a generated app's Settings, its notifications are delivered under its own identity, and authorization survives refresh. Privacy grants behave as the chosen requirement predicts. Report renewal only where supported permission readback establishes it; do not promise a complete inventory of lost grants. Keep notification authorization, delivery readback, and visible presentation distinct.
- **Cold/warm launching:** launch with parent closed and open; reopen repeatedly; close all windows and reopen. Assert window/process counts and that startup commands execute only for fresh recipe openings.
- **Concurrency:** run the parent and two apps, including two created from one recipe. Verify independent state, sockets, plugin data, browser logins, setting overrides, process ownership, and Quit. Exercise direct duplicate-process startup and conflicting app identities.
- **Restoration/failures:** verify own-session restoration, no command replay, edited/deleted recipes, unavailable packages, unavailable directories, and failure before workspace publication. A corrupt session shows the native alert, opens no window, quits without changing the file, and **Show in Finder** reveals it. Preserve data and avoid phantom default windows.
- **Duplicates and refresh lease:** a direct second executable launch activates the running copy and exits. A launch during refresh shows the refresh message. A Finder copy of a running app cannot start a second writer.
- **Shared configuration:** a change to the parent's config or palettes reaches a running layout app. A per-app override wins, applies only to that app, and **Reset** removes it. The layout app never writes the parent's files.
- **Plugin sync:** a plugin installed or enabled in the parent appears in a running layout app without a restart. An update or removal applies immediately when none of its panes are open. With its panes open in the layout app, it waits, the footer reports it, and it applies once those panes close. A running app keeps working while the parent removes a plugin it uses. An unreadable parent package keeps the local copy and records a diagnostic.
- **Plugin data copy:** with the checkbox on, the new app opens with the parent's plugin data, and later edits stay separate in both directions. With it off, plugin data starts empty. The inline welcome does not appear.
- **Parity:** create and refresh through native UI, CLI, registered plugin, and managed service. Verify discovery, response/error contracts, event attribution, and wrong-instance/stale guards.
- **Refresh:** after a parent update, a stopped app self-refreshes on launch before any shell or plugin process starts, then relaunches once. A running app shows "Update ready" and is not restarted. The parent refreshes stopped apps in the background. Preserve identity, overrides, plugin data, and saved state. Handle a parent older than the app, parent/app movement, stale paths, signature failure, App Management refusal, interrupted replacement, and an attempted launch during refresh.
- **Check for Updates in a layout app:** the menu item, Cmd-K, CLI, and page bridge open the Software Update window without a network request. Readback shows `ready` with **Restart Writing** when the parent is newer, `current` with **Open Slate Terminal** when builds match, and `unavailable` without a compatible parent. `updates.download` and `updates.cancel` fail with `-32051`. The generated Info.plist has no `SU*` keys, and no `SPUUpdater` is created.
- **Parent update through Sparkle:** install a signed parent update while one layout app runs and one is stopped. The stopped app is refreshed by the parent. The running app shows the ready state, keeps working, and updates on its next launch.
- **Parent replaced while layout apps run:** replacing Slate.app in Finder does not disturb running layout apps.
- **Regression:** ordinary Slate software updates, ordinary Slate startup/restoration, existing shortcut bundles opening through URLs, plugin installation, and default browser behavior remain valid.
- **Visual review:** obtain independent review of app creation, icon selection, generated-app list, and real macOS app identity. Static mockups and self-review do not establish completion.

Spotlight indexing is controlled by macOS. Test it separately from Launch Services registration, with bounded observation and explicit results. An index delay must not be disguised as a successful Spotlight check or retried by recreating the app.

## 11. UI changes at a glance

Mockups for these exist only as descriptions here; final designs need the independent visual review from section 10.

**In Slate Terminal**

- **Create app dialog:** the existing launcher dialog always creates a separate app. There is no mode switch. Name, icon picker, and destination stay as they are. A new checkbox, **Copy plugin data from Slate Terminal** (checked by default), has the hint "One-time copy. Afterwards Writing keeps its own data." One line explains that the app gets its own session, browser logins, and plugin data, while settings and plugins come from Slate Terminal. Unavailable plugins that will not sync are listed.
- **Generated-app list:** shows each app's availability, runtime version, and running state. **Refresh App** remains as a repair action only.

**In a layout app (example: Writing)**

- **App name everywhere:** the app menu ("About Writing", "Quit Writing"), default tab title, startup and lease alerts, and plugin permission prompts use the app's name. The About panel adds "Built on Slate Terminal". Agent-skill/CLI text and parent-only explanations keep "Slate Terminal" (section 4.4).
- **Settings → Layout app section:** name, source layout, runtime version, and one caption: "Settings and plugins come from Slate Terminal. Writing keeps its own browser logins and plugin data." When relevant, it adds the line "Update ready, applies next time you open Writing."
- **Parent-only controls:** plugin install/update/remove/enable, the launcher action, the generated-app list, and Refresh are disabled. There are no per-control locks or tooltips. The existing sticky Settings footer shows one status line on those pages: "Plugins and layout apps are managed in Slate Terminal." A deferred plugin change adds "1 plugin change waiting for open panes to close." Cmd-K omits these commands.
- **Overridden settings:** individual settings carry no labels. Only a setting with a per-app override shows **Reset**. **Show Config File** reveals the app's `overrides.toml`.
- **Writing → Check for Updates…:** the same Software Update window, without any network request. It shows one of three states: ready with **Restart Writing**, up to date with **Open Slate Terminal**, or waiting for a compatible Slate Terminal.
- **Startup alerts:**
  - Corrupt session: "Writing couldn't restore its session", with the preserved file path, **Show in Finder**, and **Quit**.
  - Missing recipe and no session: an alert naming the layout, then quit.
  - Launch during refresh: "Writing is being refreshed; try again when it finishes."
  - A second launch while the app is open only brings it to the front, with no alert.

## 12. Known quirks and limitations

**Platform findings and remaining decisions:**

- **Permissions after refresh.** The default code-hash requirement lost the tested Documents, Accessibility, and Full Disk Access grants. The stable signing-identifier requirement preserved them and allowed independently compiled replacement code at the same path to inherit them. Notification delivery and Automation authorization had different behavior; use the per-permission matrix below. Neither signing strategy is silently selected here.
- **App Management.** Clean self-swap and native signed-caller replacement succeeded without an App Management grant. Policy and no-policy targets both worked, so policy effectiveness and the eventual production caller remain unproved. Refusal handling is still required.
- **Re-signed frameworks.** Hardened Runtime rejected Sparkle during launch despite valid static signatures. The non-hardened copy ran terminals and its CLI helper. Adopting its reduced protections requires an explicit decision. Unused Sparkle updater helpers were statically verified, not executed.
- **Spotlight.** Finder cold launch passed. Spotlight displayed no results for either the fixture or Safari in this VM despite valid indexed metadata; the available host UI fallback also failed. Spotlight cold launch remains an explicit acceptance check, not a pass.

**Quirks:**

- **Updates arrive at next launch.** A running app is never restarted. The first launch after a Slate update relaunches once, visible as a brief Dock bounce.
- **Separate logins and data.** Each app needs its own browser logins. Copied plugin data drifts: a note edited in Writing does not appear in Slate.
- **Permission prompts per app.** Each app has separate grants. Some may require renewal after refresh, depending on the chosen signing requirement and permission.
- **Some plugin changes wait.** Updating or removing a plugin whose panes are open in a layout app waits until those panes close.
- **Depends on the recipe.** If the source layout is deleted and the app has no saved session, it can only show an alert and quit.

**Limits:**

- **Disk use:** the measured signed copy added about 26.0 MiB through Foundation/APFS versus 38.0 MiB through byte copying. Old-plus-staged copies settled around 52.1 MiB, with sampled transient peaks around 56.8 MiB. These same-volume, same-runtime measurements are not a future-release capacity guarantee.
- **Managed from Slate only:** a terminal inside a layout app cannot create, list, or refresh layout apps.
- **Finder copies:** a duplicated app shares state with the original, and only one can run at a time.
- **No new shortcut launchers:** existing ones keep working. `layouts.launcher` changes behavior for API clients.
- **Local only:** apps read the recipe from the local library. Managed Macs may block ad-hoc signed apps. Icon caches and Spotlight indexing can lag.

## 13. Questions for the reviewing agent

Review the proposal against the current source, not only this document. Return concrete findings with severity, affected section/code, failure scenario, and a suggested correction. Do not implement changes during the review.

1. Does a copied, locally signed native runtime reliably retain its own identity and required entitlements? What must be demonstrated before choosing this packaging approach?
2. Are layered shared configuration and launch-time plugin sync safe with one writer per file? Is an identifier-only designated requirement an acceptable security trade-off for user-created local apps?
3. Does restoration-first behavior match a saved-layout app, or should every cold start use the latest recipe? How would that affect command replay and user changes?
4. Are startup, state, browser/plugin ownership, and management leases sufficient to prevent competing writers and wrong-instance routing?
5. Are creation/refresh partial failures and recovery concrete enough to implement safely? Are app movement, duplicate copies, and version incompatibility covered?
6. Are the native/automation contracts complete without unnecessary new capabilities? Are the proposed acceptance checks sufficient to establish the requested user-visible behavior?

Two independent reviews (2026-10-19) have been addressed in this revision: a review of the whole plan and a packaging comparison. Implementation has not started.

## Appendix: Milestone 0 information gathering

### Status and evidence boundary — 2026-10-19

**Historical research snapshot, superseded by the empirical appendix below.** Pending statements and the handoff gap described in this section record what was known before the VM work; they are not current status or implementation instructions.

**At that earlier checkpoint: research and host static probes complete; VM experiments pending.** This pass changed documentation only in the source repository. It did not launch fixture apps, change macOS permissions, replace app bundles, or run native UI tests. No screenshots or VM pass are claimed. Milestone 0 remains open.

Outcome for this phase: determine whether independent copied apps can launch and refresh with acceptable identity, permissions, and disk cost. The next useful milestone is the VM signing/launch matrix, before startup or product implementation. Existing launcher UI work and unrelated source changes are outside this research pass.

Host evidence is retained outside the nested source repository at `../../artifacts/layout-apps-research-20261019/` relative to this document:

- [Installed release inspection](../../artifacts/layout-apps-research-20261019/installed-release-inspection.json): exact commands, exit codes, plist, dependency list, and file sizes.
- [Signature verification outside the sandbox](../../artifacts/layout-apps-research-20261019/release-signature-outside-sandbox.txt): resolved Developer ID and successful strict verification. The sandboxed check reported an invalid signature and could not resolve the authority; the successful unrestricted check supersedes that result.
- [Designated-requirement probe](../../artifacts/layout-apps-research-20261019/requirement-probe.json): four copied launcher-helper binaries, command/output records, and cross-version requirement checks. These binaries were never executed.

### What is now established

| Question | Evidence gathered | Still unresolved |
| --- | --- | --- |
| What runtime are we copying? | Installed `/Applications/Slate Terminal.app`: 0.3.0 build 4, arm64, minimum macOS 27.0; Developer ID Team `YWRT8FQN6F`; hardened runtime; stapled notarization ticket; no main-executable entitlements. Strict deep signature verification passed outside the sandbox. | Fresh downloaded/quarantined parent and real launch of the modified copy. Installed parent has no quarantine attribute. |
| Does ad-hoc identity stay stable? | Changing signing flags changed the default DR's code hash. An explicit identifier-only DR stayed identical and accepted the changed variant. | TCC and notification behavior after a real changed-app replacement. |
| Will hardened runtime load the re-signed frameworks? | Six dynamic frameworks and both helpers are present. Sparkle is a linked dependency even with its updater disabled. Apple's library-validation rule requires Apple signing or the executable's Team ID. | Real `dyld` loading with independently ad-hoc-signed code, plus nested helper behavior. Signature verification alone cannot establish this. |
| Can Slate refresh a generated app without App Management permission? | Apple documents an explicit allow policy for another signed updater. This is an additional candidate to test. | Applicability to an ad-hoc target, exact caller attribution, and self-swap with no Team ID. |
| Does `RENAME_SWAP` solve self-refresh? | It supplies an atomic namespace swap on supporting filesystems. | App Management, old-process lifetime, later resource reads, cleanup timing, and a relaunch that actually starts the replacement. |
| How expensive is copying? | 930 regular non-symlink files; 36,564,011 logical bytes; sum of reported allocated blocks is 39,673,856 bytes. Foundation can clone automatically. | Incremental physical allocation after signing, and peak allocation while old and staged bundles coexist. |

### Signing and permission experiments

Apple's [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) explains that an ad-hoc DR is specific to a code version and describes authorization tracking through a stored DR. An [Apple DTS reply about ScreenCaptureKit](https://developer.apple.com/forums/thread/819406) confirms the practical loss of continuity for changed ad-hoc builds. Neither establishes the behavior of every permission in this plan.

The host probe copied only `Contents/Helpers/slate-layout-launcher`. For each requirement strategy, variant A used `--options runtime`; variant B used `--options runtime,kill` to change signed metadata. All four passed static signature validation. Default A and B produced different `cdhash` requirements; B failed A's requirement with exit 3. Identifier-only B passed A's requirement with exit 0. Commands and full outputs are in the evidence file above. Representative commands:

```sh
codesign --force --sign - --options runtime \
  --identifier com.slateterm.layoutapp.research-signature fixture
codesign --force --sign - --options runtime \
  --identifier com.slateterm.layoutapp.research-signature \
  -r '=designated => identifier "com.slateterm.layoutapp.research-signature"' fixture
codesign --display --requirements - fixture
codesign --verify --strict -R '=identifier "com.slateterm.layoutapp.research-signature"' fixture
```

These are mechanism checks, not privacy tests. The VM needs changed v1/v2 app payloads, the same bundle ID and path, and a fresh process after replacement. Give each requirement strategy its own identity to avoid contaminating the other trial. For Full Disk Access, Files & Folders, Accessibility, Automation, and notifications, record the initial state, real grant, successful operation, replacement, and post-relaunch operation separately. Notification settings readback alone does not prove delivery. Use fixture-owned protected files and controlled target apps; do not edit TCC databases or reset unrelated grants.

Apple's [library-validation documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation) does not promise that two absent Team IDs match. Expect this to be a significant launch risk. Sign inside out and verify every nested executable, then collect actual launch/dyld diagnostics. If the hardened variant fails, run the plan's non-hardened comparison. Apple's [hardened-runtime guidance](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime) makes clear that disabling the runtime removes several protections. A successful fallback launch must not be reported as retaining them.

Sparkle's updater must remain inactive in a layout app. Separate framework-load evidence from explicit nested-helper execution; do not trigger a network update merely to exercise Sparkle. A main-app launch does not prove every nested helper ran.

### Refresh: an additional policy candidate and a launch race

Apple's [WWDC22 privacy session, 5:14–6:41](https://developer.apple.com/videos/play/wwdc2022/10096/) documents same-team updates and explicit update policies. [`NSUpdateSecurityPolicy.AllowProcesses`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsupdatesecuritypolicy/allowprocesses) maps updater Team IDs to signing identifiers. A generated target could declare this candidate policy, using the currently verified parent identity:

```xml
<key>NSUpdateSecurityPolicy</key>
<dict>
  <key>AllowProcesses</key>
  <dict>
    <key>YWRT8FQN6F</key>
    <array>
      <string>com.alexandermoritzweichart.slateterm</string>
    </array>
  </dict>
</dict>
```

This is a research candidate, not an approved implementation change. Test targets with and without this policy, with no existing App Management grant. The actor must have the recorded signing identity; a shell launched by the test controller does not by itself prove the production caller's authority. If a helper performs the update, inspect that helper's signing identifier and responsible-process attribution. A different signed probe can test the mechanism but cannot certify Slate's exact production path. An ad-hoc self-updater has no Team ID to insert into this dictionary, so the parent policy does not settle self-refresh.

The local `rename(2)` manual establishes only the filesystem swap. Its permission and unsupported-filesystem errors remain possible. Do not infer safe running replacement from atomicity or modify the old executable in place. Retain the old bundle until its process exits, and test delayed resource/helper access and failure recovery.

There is also a concrete gap in section 7's “launches the new bundle, and exits” sequence: [`createsNewApplicationInstance`](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/createsnewapplicationinstance) defaults to false and normally opens the running app. With the same bundle identity, a relaunch request issued before exit can reactivate the old process. Test a deliberate handoff with old/new PID and executable-path readback. Forcing a second process also needs maintenance-lock and state-lease coordination; it is not automatically a safe fix. Do not choose the final handoff protocol until this experiment passes.

### Clone cost: measure the signed result

Apple documents that [`FileManager.copyItem` automatically clones on APFS](https://developer.apple.com/documentation/foundation/about-apple-file-system), and that unchanged blocks remain shared after modifications. A comparison using it as the “plain copy” control would therefore be misleading.

Use three controls: explicit byte copying, Foundation copying, and confirmed cloning. The local `clonefile(2)` manual discourages cloning a directory hierarchy directly; `copyfile(3)` supports recursive cloning but may fall back to copying. Record which operation actually succeeded and preserve framework symlinks. Cloning also copies extended attributes, so check quarantine on staged descendants, not just the bundle root.

Measure before copying, after copying, after inside-out signing, after replacement, and after old-bundle cleanup. Record logical bytes and volume allocation separately. Summed `st_blocks`/`du` values do not establish unique physical allocation of shared blocks. Prefer a quiet disposable APFS test volume and repeated batches large enough to distinguish allocation from filesystem noise; include a no-copy control. This information-gathering pass created no such volume and claims no measured clone savings.

### VM experiment order and acceptance evidence

All native actions run in VMPal under the repository lease. Compile standalone probes on the host, retain their source and hashes, and keep product source unchanged for milestone 0. Use a fresh run directory and fixture identities. Record guest OS/build separately from this pass's host macOS 27.0 (`26A428`).

1. **Qualify the parent.** Download the versioned 0.3.0 build 4 release into the fixture area, verify its checksum/signature/notarization, and record quarantine before copying. The retained release-verification record lists DMG SHA-256 `746a3574a8a2125001ccdb591989343f378031e1b244087873e3e53e0f078103`; verify against the actual asset. That historical record is not a fresh downloaded-parent pass. Neither `downloads/` nor `candidate.dmg` remains in the retained release-artifact directory inspected here.
2. **Sign and launch.** Prepare independent bundles with distinct IDs/names/icons, remove parent URL/updater metadata, and compare hardened/non-hardened signing. Record strict verification, actual PID/bundle/window owner, terminal operation, and copied resource paths. Stop architecture expansion if independent launch fails.
3. **Establish Finder and Spotlight identity.** Verify selected icon, Dock/Cmd-Tab entry, cold launch, warm reopen, and independent Quit. Separate a bounded Spotlight indexing observation from Launch Services registration. Do not treat a programmatic launch as Finder/Spotlight evidence.
4. **Measure permission continuity.** Run the default/identifier-only matrix described above using genuine changed payloads and new processes. Record each permission's supported observation and any missing evidence.
5. **Exercise refresh authority and handoff.** Compare stopped-target replacement by an actual signed caller, the allow-policy candidate, and ad-hoc self-swap. Record caller/target signatures, initial grants, syscall result/errno, any prompt, bundle hashes before/after, old/new PIDs, relaunch count, and interrupted-swap recovery. A shell-level successful rename alone does not pass this gate.
6. **Measure clone cost.** Use the same signing order and bundle mutations as the passing launch variant. Report physical incremental and peak storage, including the replaced bundle retained for the old process.

**Fixture isolation to resolve before step 3:** the unchanged runtime does not implement section 4.3's layout-app manifest or private state root. Programmatic launches can use `NSWorkspace.OpenConfiguration.environment` with the existing integration variables. Finder and Spotlight cold launches do not receive that per-call environment. Warm activation of an already isolated app is useful but is not a cold-launch pass. Use a disposable guest user/home, or first validate an isolated bootstrap fixture that preserves the intended process/bundle identity. Do not launch an unmodified copied release into the VM user's ordinary Slate state and call it isolated.

Each row needs commands, readback, and fresh screenshot references where appearance or prompts matter. Until those results exist, signing policy, permission continuity, automatic refresh, and clone savings remain open. The evidence gathered here is sufficient to make the next VM experiments specific; it is not completion of milestone 0 or milestone 1.


## Appendix: Milestone 0 empirical results

### Outcome and evidence boundary — 2026-10-19

**Platform experiments executed; product implementation and release qualification have not started.** The results support an independently running copied runtime, but invalidate the proposed hardened signing configuration and expose a permission-identity trade-off. Spotlight cold launch remains unverified. The App Management policy comparison had no denying control, so it cannot establish policy effectiveness. These limits must remain visible when deciding whether to proceed.

The [self-contained HTML explanation](../../artifacts/layout-apps-spikes-20261019/layout-apps-results.html) presents the consequences at a higher level. Evidence is under `../../artifacts/layout-apps-spikes-20261019/`: [VM command journal](../../artifacts/layout-apps-spikes-20261019/vm-commands.jsonl), [103 native command results and launch logs](../../artifacts/layout-apps-spikes-20261019/vm-results/), [screenshots](../../artifacts/layout-apps-spikes-20261019/vm-evidence/), probe source/hashes, packaging commands, and APFS measurements. Native fixtures ran in the leased `slate-term` VM on macOS 27.0.1 (`26A434`); host compilation and allocation tests used macOS 27.0 (`26A428`).

### Release, signing, identity, and lifecycle

- **Provenance:** the official 0.3.0 build 4 ZIP SHA-256 is `33a0e224112915ffbe2300d6022a437b6af1658c074372d65a3656e3a95cb0a7`. Strict deep verification, host stapled-ticket validation, and guest notarized Developer ID assessment passed. Quarantine was explicitly applied to the source for this controlled test and removed from generated bundles; no browser-download history is claimed.
- **Hardened failure:** bootstrap and direct-entry variants passed static validation but aborted loading Sparkle because the independently ad-hoc-signed executable/framework lacked matching Team IDs. See `followup-packaging.json` and `vm-results/evidence/hardnative.log`. No entitlement workaround was added.
- **Working comparison:** non-hardened copies ran simultaneously as independent processes with distinct bundle paths, native window ownership, sockets, and terminal sessions. The copied CLI helper returned zero. This covers loaded frameworks and the CLI, not execution of unused Sparkle updater helpers.
- **Isolation:** an initial `exec` bootstrap lost the expected Launch Services process association and was discarded for identity acceptance. Direct-entry fixtures used documented `LSEnvironment` only for test state/configuration isolation. Production still needs the typed manifest/startup context. The final ordinary Slate state/configuration hash comparison was unchanged.
- **Finder and identity:** after confirming the previous process had exited, Finder double-click started PID 20753 from the copied bundle. Its terminal returned `FINDER_COLD_OK`. Finder, Dock, and Cmd-Tab showed the custom W icon; the menu bar and native process metadata used the fixture name. Hard-coded in-app product strings still said Slate Terminal, as expected before section 4.4 is implemented. See `finder-cold-selected.png`, `finder-cold-runtime.png`, and `cmd-tab.png`.
- **Warm reopen and Quit:** programmatic warm reopen reused PID 19827. Native Quit plus the expected running-process confirmation terminated it while copied app PID 19741 and isolated signed parent PID 20699 remained alive and responsive to workspace RPC. No recipe/restoration/product lifecycle claim follows from these release-runtime fixtures.
- **Spotlight limitation:** UI searches for both the fixture and the Safari control displayed no results. Indexing was enabled; `mdls` reported the fixture identity and `mdfind` found its path. The host fallback could not open Spotlight through the available native UI tool (RBS error 5/POSIX 162); its bound desktop capture was unusable. This is an incomplete Spotlight check, not a copied-app failure or a pass. See `spotlight-no-result.png`, `spotlight-safari-control.png`, and `host-spotlight/outcome.json`.

### Permission continuity after actual changed code and a fresh process

Each row used its own fixture identities. V1 received the real named consent or Settings grant. V2 changed executable payload and sealed metadata, replaced the bundle at the same path, and started under a new PID. The stable predicate used the signing identifier, which equalled the bundle identifier in these fixtures. No publisher or Team ID was part of that predicate.

| Permission and observation | Default ad-hoc code-hash requirement after v2 | Explicit signing-identifier requirement after v2 | Independently compiled replacement using the stable identifier |
| --- | --- | --- | --- |
| Documents: read only the harmless 40-byte fixture | Prompted again; declined, then `EPERM` | Read succeeded without renewed consent | Read succeeded |
| Accessibility: another probe's real window title | Untrusted; AX error `-25211` | Trusted; window/title AX calls succeeded | Same successful operation |
| Full Disk Access: open then immediately close an existing protected path, never read its contents | `EPERM` | Open succeeded | Open succeeded |
| Notifications: authorization, post, delivered-notification ID | Authorization retained; new notification reported delivered | Retained; new notification reported delivered | Retained; new notification reported delivered |
| Finder Automation: official wildcard authorization API | Authorization retained (`0`) | Authorization retained (`0`) | Authorization retained (`0`) |

FDA used the existing system TCC database path only as an open/close permission probe; it never read database bytes. Both fixtures returned `EPERM` before the explicitly approved grants and succeeded after restart. An earlier nonexistent user-level path was rejected as an invalid probe. Both temporary FDA entries were removed afterward; restarting the formerly permitted stable fixture restored `EPERM`. See `fda-cleanup.png` and result `e7357848-02a7-44bc-a295-8cee3e7d916b`.

Automation has a narrower evidence boundary: Apple's wildcard preflight initially returned `-1744` (consent required), actual named Finder prompts were allowed, and post-grant/fresh-process checks returned `0`. A separate Finder comment mutation returned `-10006`, so successful mutation is **not** claimed. Earlier System Events name and Finder existence queries ran without consent and were not counted as grants. The matrix establishes Automation authorization continuity in this environment, not successful execution of every Apple Event. Notification delivered-ID readback is distinct from a verified visible banner.

The independently compiled variant demonstrates the consequence of identifier-only trust at the tested installed path. It does not establish arbitrary remote exploitation or permission inheritance across all paths/macOS versions. Default ad-hoc identity also did not reset every permission: notifications and Automation authorization survived here. Policy and UX must reflect the measured distinctions rather than promise that all grants either survive or disappear together.

### Atomic replacement, authority, and relaunch

A fresh native self-refresh probe with no Accessibility or App Management grant swapped v1/v2 using `renamex_np(RENAME_SWAP)` successfully. PID 20588 continued running v1 code, but a later path-based resource read returned **Resource v2**. Its cached `Bundle` path still named the installed location while `proc_pidpath` pointed to the retained staged executable. Atomic replacement therefore does not make old-process file access version-consistent.

Default `NSWorkspace` reopen returned the same old PID 20588. Setting `createsNewApplicationInstance = true` returned PID 20613; compiled marker and executable readback verified v2. Both briefly coexisted. The probe had no workspace leases, journal, plugins, or production startup, so this is a mechanism pass only. An immediate open after another fixture's exit request once returned `-600`; waiting for confirmed exit and retrying succeeded. A request to exit is not proof that the process has exited.

For cross-app replacement, a native probe signed with Apple Distribution Team `YWRT8FQN6F` and its own signing identifier replaced stopped targets with and without `NSUpdateSecurityPolicy.AllowProcesses`. Both swaps succeeded without a prompt. The App Management list was empty before and after, and the caller was not Accessibility-trusted. The policy target listed the actual probe identity as well as the parent identity. Because the no-policy control also succeeded, this does **not** prove the allowlist caused success or that it will resolve a denial. This certificate class and caller differ from Slate's Developer ID parent; the eventual native production path still needs verification. See `signed-caller-packaging.json`, `policy-caller-revision.json`, and `app-management-before.png`/`app-management-after.png`.

### Signed copy allocation

Three primary repetitions with four app pairs each measured the following additional physical allocation on an isolated APFS volume:

| Operation | Signed app | Settled old + staged pair |
| --- | ---: | ---: |
| Explicit byte copy | 38.004 MiB | 76.014 MiB |
| Foundation `copyItem` | 26.042 MiB | 52.075 MiB |
| Explicit clone | 26.037 MiB | 52.079 MiB |

Foundation retained about 31.5% savings after signing; explicit cloning added no meaningful saving. Supplemental 50-ms sampling saw transient peaks around 76.1 MiB for byte copying and 56.8 MiB for clone-based pairs. Non-hardened signing had essentially identical allocation. All 120 signed bundles passed strict deep validation. Same-volume APFS, small metadata/resource changes to the same runtime, and finite sampling limit extrapolation. See [measurement method](../../artifacts/layout-apps-spikes-20261019/clone-cost/README.md) and [summary](../../artifacts/layout-apps-spikes-20261019/clone-cost/summary.json).

### Consequences and next implementation gate

1. Decide whether losing Hardened Runtime protections is acceptable; otherwise revise packaging/signing. The tested hardened configuration cannot remain a required passing gate.
2. Decide between code-hash identity with measured grant renewal and identifier-only continuity with measured impersonation consequences. Do not quietly trade publisher identity for convenience.
3. Use Foundation copying. Budget for staged and retained copies; do not treat clone creation as near-zero update cost.
4. Implement maintenance-before-state lock ordering, state reservation during refresh, a pending handoff, revision validation, and a recovery journal. Plugin sync and all state writers begin only after exclusive ownership. Activate the verified lease owner rather than the first bundle-ID match.
5. Retain the old bundle until its recorded process identity exits. Delayed resource reads proved why the old coordinator must not resume normal runtime work after swapping.
6. Complete Spotlight in a working environment and verify the actual product caller, denial handling, startup races, interruption recovery, and plugin/state ownership after implementation. These are not passed by the standalone probes.

The [handoff design review](../../artifacts/layout-apps-spikes-20261019/probe/handoff-review.md) supplies the race/recovery cases. No interruption recovery or product concurrency pass is claimed. All owned VM processes were stopped, generated bundles were retained outside Applications, temporary task privacy grants were reset by exact fixture identifier, the two FDA entries were removed, and the owned VM lease was released. Existing Slate state/configuration hashes remained unchanged. No product feature code, commit, push, or publication was part of this investigation.


## Follow-up: packaging alternatives after the spike

The 2026-10-19 [alternatives investigation](../../artifacts/layout-apps-alternatives-20261019/alternatives.md) recommends a new prototype: a stable customized app shell with a private Developer-ID-signed runtime framework. Replacing compatible nested code can preserve the outer signature and default ad-hoc identity. A host static fixture confirmed unchanged outer code hash, valid strict signatures after a changed nested runtime, and rejection of a different nested requirement. It did not establish native loading or privacy-permission continuity.

The candidate keeps Hardened Runtime, uses the library-validation exception for the different signing identities, and proposes an OS library-load constraint for the allowed publisher and libraries. Its runtime copy remains private to each app. It revisits framework extraction without adopting the rejected dependency on mutable files inside the parent Slate app.

This is a research recommendation, not an accepted architecture change. The next gate is a minimal native shell/runtime prototype with real vendor signatures, load-denial controls, unchanged-shell permission continuity, and a changed-shell control. Existing implementation sections remain the previous proposal until that result is reviewed. See the investigation for the full comparison and limits.


## Follow-up: native stable-shell prototype

The 2026-10-19 [native prototype results](../../artifacts/layout-apps-stable-shell-20261019/results.md) strengthen the stable-shell candidate. Two customized shells ran independent AppKit windows. A stopped-app runtime V1→V2 replacement kept all outer signed files and the default ad-hoc code identity unchanged; a fresh process retained both tested Documents and Accessibility operations. Finder cold launch and independent native Quit passed. Changing and re-signing the shell itself lost those grants, confirming the intended update boundary.

Hardened Runtime remained enabled with the library-validation exception and a Team-ID library-load constraint. The signature preflight rejected a same-identifier ad-hoc runtime and a tampered resource; an independent control bypassed preflight and was still rejected by the OS library constraint. The V1/V2 fixture runtime used Apple Distribution signing. Loading the actual shipped Developer-ID-signed SlateTermCore framework also succeeded, but a complete production Developer ID runtime-update path remains unverified.

Recommendation: next extract the real shipping native runtime, including helpers and versioned resources, behind a stable bootstrap entry. This remains an architecture recommendation rather than completed product implementation. Full permission coverage, production updater authority/recovery, Spotlight, Gatekeeper/release qualification, and transitive dependency tests remain open. The native report also records a constraint-validator tooling failure that must be isolated before release automation; decoded constraints and actual positive/negative load behavior passed despite that validator failure.
