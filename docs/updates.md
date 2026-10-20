# Software updates

**Slate Terminal → Check for Updates…** opens a native window with release notes before downloading. **Show Software Update** and **Check for Updates…** are also in Cmd-K and can receive configured shortcuts. Release notes stay readable while downloading, verifying, and waiting to install. The continuation row scrolls longer notes without changing the update.

Checking and downloading are explicit actions. Closing the window or pressing Escape hides it; reopening retains the current notes, scroll position, and operation. Cancel stops staging and returns to the available release. Only **Install and Relaunch** authorizes installation. In standard Slate, it checks unsaved layout drafts before starting installation. Canceling that draft confirmation leaves the update ready. Running-process confirmation occurs only when Sparkle actually asks the app to terminate, including for work started after installation consent. Canceling termination leaves the installation authorized and waiting for a later quit or retry. Once installation is authorized, Sparkle may finish on a later normal quit; it cannot be canceled by hiding the window.

## Shared API and clients

`api.describe.updates` describes the application-wide session. Native buttons, the menu, Cmd-K, CLI, registered page bridge, and trusted services share the same operations. Ordinary web pages and subframes have no bridge. Update actions do not inherit a pane target.

| Method | Parameters | Behavior |
| --- | --- | --- |
| `updates.openParent` | Optional `expectedInstanceId` | In a layout app, open the verified Slate Terminal parent |
| `updates.get` | Optional `expectedInstanceId` | Read state without a network request |
| `updates.show` | Optional `expectedInstanceId` | Open or focus the current window |
| `updates.check` | Optional `expectedInstanceId` | Show the window and begin a check when no update is active |
| `updates.download` | `updateId`, optional `expectedInstanceId` | Download the offered update after its notes are authenticated |
| `updates.cancel` | `updateId`, optional `expectedInstanceId` | Cancel a check/staging operation before installation |
| `updates.install` | `updateId`, `confirm: true`, optional `expectedInstanceId` | Install the verified ready update after normal quit safeguards |

All methods return the current snapshot. It contains `revision`, optional `updateId`, `phase`, `currentVersion`, `source` (`signedFeed` or `localParent`), optional `release`, `receivedBytes`, `expectedBytes`, optional `detail`, and `windowVisible`. `release` contains `id`, `version`, `build`, plain Markdown `notes`, `downloadURL`, `contentLength`, and the archive's base64 Ed25519 `signature`. Optional values can be absent. The phases are `idle`, `unavailable`, `checking`, `available`, `downloading`, `verifying`, `ready`, `installing`, `downloadError`, `verificationError`, `checkError`, and `current`.

Capture `updateId` from the current snapshot before download/cancel/install. A new check changes it. A stale identity fails with `-32050`; a disallowed phase fails with `-32051`; missing consent, missing identity, unknown fields, and unsupported guards fail with `-32602`. Installation revalidates identity and caller lifetime after its modal confirmation. Declining a pre-installation confirmation returns a ready snapshot without authorizing installation. In standard Slate, declining the later process-termination warning instead postpones quitting while installation remains authorized. Read state after ambiguous transport failure instead of replaying install.

```sh
slate-term updates check
slate-term updates get
slate-term updates download --update-id UPDATE_ID
slate-term updates cancel --update-id UPDATE_ID
slate-term updates install --update-id UPDATE_ID --confirm
```

Registered pages have `workspace.updates.get(options)`, `.show(options)`, `.check(options)`, `.download(updateId, options)`, `.cancel(updateId, options)`, `.openParent(options)`, and `.install(updateId, true, options)`. The options carry normal `{cause, signal}` transport metadata. Use `workspace.call` for explicit `expectedInstanceId`. Services call the same methods through their bound socket or CLI. No parameterless download/install picker commands are provided because those actions require a particular offered release and explicit installation consent.

`host.updates.changed` reports semantic phase, release, and window-visibility changes, with `beforePhase`, `phase`, `revision`, `updateId`, `version`, and `windowVisible` in its payload plus normal operation provenance. Download chunks do not produce events. Read `updates.get` for progress; after cursor expiry obtain a cursor, resnapshot, then resume polling. A later show request does not claim the original download's asynchronous events.

## Authentication and installation boundary

Sparkle 2.10.0 is pinned in the Xcode project. Both the feed and external notes require signatures, with no signature-expiry fallback. Offered releases must include signed external `.md`, `.markdown`, or `.txt` notes. Native notes render bounded Markdown without HTML or embedded web content; only HTTPS links can open. The archive is limited to its signed size and 512 MiB. HTTPS-only staging uses a private directory, no cookie/cache/credential storage, and exact-byte Ed25519 verification. Cancel and shutdown remove owned staging files.

Sparkle starts its external installer during its normal download flow, and that installer can complete on application quit. To keep pre-install consent meaningful, Slate stages and verifies its own first download while holding Sparkle's initial offer. **Ready** proves archive signature and length; it does not claim installation compatibility. Only explicit installation releases Sparkle's offer. Sparkle then downloads the archive again and performs its own signature, extraction, code-signing, and installation validation. This second download is intentional; no unsupported Sparkle internals or installer-file adoption are used.

A resumed Sparkle offer from an earlier session does not carry fresh installation consent. For valid metadata, Slate replies with `.skip` to discard an already downloaded offer or cancel an installation that had begun. Dismissing a downloaded offer preserves it for the next check; dismissing an installing offer could authorize installation on quit. The window explains that the earlier download was discarded or installation skipped and offers **Check Again**, without reporting a signature failure. Metadata or signature failures still report verification errors.

These SDK semantics are verified against [Sparkle 2.10.0’s choice handling](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUIBasedUpdateDriver.m#L264-L299): skipping a resumed download clears its cached data. An [explicit update check clears the skipped version](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Sparkle/SPUUIBasedUpdateDriver.m#L172-L185), allowing a fresh offer. The [public user-driver contract](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html) also documents dismissal preserving downloaded updates and skipping canceling installation. Local fixtures check Slate’s reply, explanation, retry state, and lack of installation consent; they do not exercise Sparkle’s cache cleanup against a real remote feed or prove a signed upgrade/relaunch.

Unconfigured builds report `unavailable` and make no update request. Production use requires the public key/feed build variables, matching private signing key, reviewed notes, Developer ID signing/notarization, and a separately published stable release. See [release provisioning and publication](releasing.md). Local fixture tests do not prove a real signed upgrade/relaunch.

## Layout-app updates

Layout apps use the same window and `updates.*` API with `source: "localParent"`. They never start Sparkle or request an update feed. The current runtime version comes from the loaded private framework. A compatible newer parent runtime produces `ready`; an unavailable or incompatible parent produces `unavailable`. File changes, activation and `updates.get/check` refresh this status. Local offers have empty `downloadURL` and `signature`, zero `contentLength`, and no fetched release notes.

**Restart to Update** uses `updates.install` with the captured `updateId` and `confirm: true`. It checks the caller, cancellation and selected parent revision again after normal quit confirmation. The shell acknowledges its restart helper before the app quits. The app then waits for the initiating transport to finish its reply. Registered pages acknowledge delivery after settling the request Promise; that wait is also bounded to five seconds. A socket caller that stops reading is disconnected after five seconds so it cannot outlive the restart helper. The helper waits for the original process to exit and opens the same app; startup verifies the pinned parent revision before copying runtime code. `updates.download` and `updates.cancel` are unavailable in this mode because there is no download or staging operation to cancel. **Later** hides the window without changing the local update status. **Open Slate Terminal** is also available in the layout app’s Cmd-K menu and through `slate-term updates openParent`.

Generated apps use the current bootstrap; this unreleased feature has no migration path for older development installations. Compatible runtime updates keep the existing signed shell. The restart helper must acknowledge readiness before the app quits.
