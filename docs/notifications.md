# Notifications

Slate has one ephemeral notification policy for trusted API clients, command completion, and terminal OSC 9/777 requests. It does not monitor arbitrary processes or infer agent state from terminal output.

## Defaults and settings

```toml
[notifications]
automatic = true
minimum_seconds = 30 # integer 1–86400
tools = true
banners = "other_panes" # other_panes, other_apps, off
sound = false
command_details = false
```

**Settings → Notifications** edits these same live configuration keys. Apply/Revert, source preservation, external-edit conflicts and `config.patch` work as for other application settings; no terminal restart is required. Notification Settings is also a native menu, command-picker and configurable-shortcut action (`notifications.settings`).

- `automatic` enables completion notifications for shell commands lasting at least `minimum_seconds`. Success, failure and unknown exit status are eligible. Conventional SIGINT status 130 is suppressed. Completion comes only from Ghostty's shell-integration/OSC 133 command-finished callback, not a second notification from authenticated zsh reports. Shell integration must be available; unsupported shells, remote prompts and tasks inside persistent TUIs are not inferred. Background jobs detached with `&` are not tracked.
- `tools` enables explicit API/plugin/service and terminal OSC notifications, independent of the automatic threshold.
- The originating pane is considered focused only when selected in the key workspace window while Slate is active. Such a request is suppressed without creating unread state. A pane in another split or tab can notify even while Slate is active. Tab-level notifications use the selected tab as their focus boundary; app-level requests have no pane focus boundary.
- `banners = "other_apps"` additionally suppresses desktop presentation whenever Slate is active. `off` suppresses all desktop presentation. Both still retain unread notifications from nonfocused sources. Sound accompanies eligible native presentation only; there is no separate bell or focus-stealing effect.
- `command_details` optionally includes available shell-reported command text in automatic notifications. This can reveal secrets on a lock screen. It is off by default; ordinary completion text includes only outcome and elapsed seconds. Tool-supplied titles/bodies are always the caller's responsibility.

**Allow Desktop Notifications…**, shown only while permission has not yet been requested, is a native-user-initiated macOS permission request. Incoming API calls, automatic completion and escape sequences never prompt. If already denied, use the adjacent macOS Notification Settings button. Opening Settings or changing configuration through the API does not itself grant OS permission. This user-consent interaction is intentionally not a programmatic permission-prompt capability; every client can inspect authorization and edit notification policy.

macOS notification styles, Focus, lock-screen settings and sound settings decide final presentation. Slate cannot guarantee that a submitted request appeared, was heard or was read.

## Shared API and clients

```sh
slate-term notify --title "Build finished" --body "248 tests passed"
slate-term notify --title "Approval needed" --pane p2 --session-id SESSION
slate-term notifications list
slate-term notifications status
slate-term notifications dismiss --id NOTIFICATION_ID
slate-term notifications dismiss --all
slate-term notifications next
slate-term notifications open --id NOTIFICATION_ID
```

```js
const result = await workspace.notifications.post({
  title: "Build finished", body: "248 tests passed", key: "build",
  pane: "p2", expectedAnchorSessionId: sessionId
});
const outstanding = await workspace.notifications.list();
const status = await workspace.notifications.status();
await workspace.notifications.dismiss({ id: result.id });
await workspace.command("notifications.next");
```

Methods `notifications.post/list/dismiss/status` are in the shared discovery catalog (`api.describe.notifications`), generated page SDK and `workspace.rpc`. Registered pages, service generations and same-user socket/CLI clients use the same validation/dispatch and can select explicit targets. Ordinary web pages and subframes do not receive a bridge. Normal mutation admission and explicit event causation apply; notifications are not an exemption for feedback loops.

### Post

`notifications.post` accepts:

- Required `title`: nonempty string after sanitization, at most **256 UTF-8 bytes**.
- Optional `body`: string, default empty, at most **4096 UTF-8 bytes**.
- Optional `key`: nonempty string of at most **128 UTF-8 bytes**, without control characters. Replaces an outstanding notification from the same host-assigned source and destination lifetime. This is coalescing, **not** a durable idempotency key or a guarantee against duplicated side effects after a disconnect.
- Optional `pane` or `tab`; a supplied pair must agree. Pane targets capture the live content lifetime. A tab target has no implicit terminal-session claim.
- Optional `active:true`, exclusive with pane/tab, intentionally captures the currently selected pane. Without a target or caller context, requests are app-level; they do not silently choose the active pane.
- Applicable normal instance/session/workspace/layout guards. `expectedAnchorSessionId` requires a matching terminal pane. CLI `--session-id` spells this guard; stale inherited shell identities fail rather than selecting another pane. Unknown fields, arbitrary actions/URLs, invalid identities and unsupported guards are rejected.

Registered pages and services inherit their host-bound pane/tab context where available. The typed CLI inherits the launching pane/session and resolves current tab membership, rather than trusting its launch-time tab hint. `--active` intentionally drops inherited routing; explicit sibling targets do not inherit another terminal's session guard. Root socket callers without routing create app-level notifications. Source identity is stamped by the host (`administrative`, registered `plugin`, `service`, or native terminal protocol); a socket's environment is routing context, not verified process provenance.

Replies have `{id, disposition, reason, retained}`:

- `submitted`: the request was submitted to Slate's native delivery adapter, **not proof of OS display**. Native asynchronous submission failure subsequently changes the retained record to `failed` with `nativeSubmissionFailed`.
- `suppressed`: policy or authorization prevented submission. Reasons include `automaticDisabled`, `belowThreshold`, `toolsDisabled`, `sourceFocused`, `bannersDisabled`, `appActive`, `permissionDenied`, `permissionNotGranted`, `rateLimited` and `overloaded`.
- Disabled source categories, below-threshold/focused requests and rate/overload drops are not retained and return `id:null`. Banner suppression and denied/ungranted permission still create bounded unread state and return an ID.

Targets are frozen before asynchronous authorization inspection, then caller, guards and content lifetime are rechecked before acceptance. Closing/replacing a target while awaiting authorization fails with unavailable rather than attaching to its successor. No API operation requests OS authorization or automatically retries.

### List, dismiss and status

`notifications.list {}` returns at most **100 outstanding unread records**, oldest first. Each contains ID, sanitized title/body, optional key, host source, anchor, automatic flag, creation time in epoch seconds, disposition and optional reason. A pane anchor's tab is resolved from current topology. Anchor lifetime is opaque and is not a bridge credential. All trusted clients can inspect these records; they may contain sensitive tool-supplied text. This is not durable history, an atomic delivery log or a persistent inbox.

`notifications.dismiss` accepts exactly one of `{id}` or `{all:true}`. Dismissal is idempotent; unknown IDs return an empty `dismissed` array. It also withdraws pending/delivered native presentation. `notifications.status {}` returns `authorization` (`authorized`, `denied`, `notDetermined`, `unavailable`), current policy, outstanding count, capacity, delivery backend and persistence=false. List/status do not inherit target filters.

## Unread state and navigation

Unread source panes show a dot in the pane title, and their native tab shows a dot even if the pane bar is hidden. The tab badge decorates the current tab name without changing its stored manual name or native window title; renaming preserves the badge, and acknowledgement restores the unadorned name. `pane.inspect` and `workspace.snapshot` expose `unreadNotificationCount`. There is no notification-center window.

**Jump to Next Notification** (`notifications.next`) opens the oldest outstanding notification's source. It is available in Workspace, Cmd-K and configurable shortcuts, with no default shortcut. `notifications.open {notificationId}` is the parameterized command used by the CLI and native banner-click handler. Explicit source navigation cancels an active tab-rename sheet before focusing content; incoming notifications do not cancel drafts. App-level notifications bring Slate forward without claiming a pane source. Focusing a pane clears that pane's notifications; focusing a tab clears its tab-level notifications, not those of other panes. Opening/acknowledging withdraws native presentation too.

Navigation resolves a pane's current tab/window and reveals a zoom-hidden source without restarting content. Retained terminal/browser/pane- or global-scoped plugin moves preserve notification identity across tabs/windows. Recreated tab-scoped plugin content receives a new notification lifetime. A replaced/closed pane's records are discarded; clicking an expired ID fails rather than opening a replacement session or a different focused pane. Pending native adds and focus/dismissal are reconciled so late callbacks do not revive dismissed records. The native handler recognizes only this app epoch's own opaque notification IDs, and supports navigation/dismissal only—never arbitrary notification actions, commands or URLs.

State is discarded at app shutdown/restart. Normal shutdown withdraws the epoch's native notifications; next startup removes stale notifications for this state root left after an abnormal exit, without withdrawing another live instance's notifications. Oldest records and their presentation are evicted at capacity. No filesystem notification history is written.

## Terminal compatibility and bounds

```sh
printf '\033]9;Build complete\007'
printf '\033]777;notify;Build complete;248 tests passed\007'
```

OSC requests use the same focus, settings, sound, unread and navigation policy. Borrowed engine strings are copied before returning from the callback. Control/bidirectional formatting characters are removed; OSC text is clipped at Unicode-scalar boundaries to the shared bounds, with a generic title if needed. API inputs over the bounds are rejected rather than silently clipped. Rich OSC 99 actions/replies and process monitoring are not supported.

Host presentation admission is **5 requests/second with a burst of 10 globally**, plus **1/second with a burst of 5 per source/destination lifetime**, with at most 128 source-budget entries and 32 posts awaiting authorization. Authorization inspection is coalesced across posts, status requests and Settings into at most one native query at a time. Disabled/focused/short requests do not consume retained capacity. Ghostty additionally rate-limits OSC requests before the host callback: at most one per second globally, and identical content within five seconds may be dropped. These are best-effort attention signals, not reliable transport.

`host.notifications.changed` is a bounded, value-free invalidation containing the outstanding count; read list/status to resynchronize. It does not include title/body/command text. Events inherit admitted causation where applicable and remain subject to the existing journal's expiry and delivery guarantees.

## Verification

`swift test` covers policy boundaries, sanitization, coalescing, retention/rate bounds, catalog/default resolution and typed configuration editing. `scripts/verify-notifications.py` uses one owned app fixture for shared CLI/page/service operations, real Ghostty completion and OSC callbacks, replacement during an authorization wait, source indicators, navigation and Settings captures. Integration mode uses a deterministic delivery adapter and does not request permission or send real system notifications. Actual macOS authorization/banner/sound/lock-screen/Focus behavior must be checked separately with user consent; fixture success is not that certification.
