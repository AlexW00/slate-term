# Agent presence

When a coding agent acts on a pane through the CLI, Slate frames the smallest target it knows and shows a detached Liquid Glass pill with the agent's name and an optional short note. Every pill sits at the pane's bottom right, fully rounded and inset from the edges. Presence never affects request admission, authorization or the target of the agent's command. Clicking a navigable pill explicitly focuses its originating Slate terminal.

## Identifying an agent

```sh
export SLATE_TERM_ACTOR=claude          # once per agent session
slate-term terminal capture --pane p2 --note "reading failing test output"
slate-term web click --pane p3 --ref REF --note "submitting the form"
slate-term --help                        # --actor overrides the variable for one call
```

- `SLATE_TERM_ACTOR` or `--actor` names the agent: 1–32 ASCII letters, digits, `.`, `_`, `-` or `:`, starting with a letter or digit. `claude:reviewer` style labels are allowed; colors follow the part before `:`.
- `--note` is optional per call: one line, at most 80 characters (320 UTF-8 bytes), without control characters. `--note` without a valid actor is an error.
- An invalid inherited `SLATE_TERM_ACTOR` is ignored with a warning, so a bad export never breaks other calls. An invalid `--actor` is an error. Shell-integration hooks and `api describe` never send an actor.
- The CLI sends actor information in request metadata, next to `cause`: `"metadata":{"version":1,"actor":{"name":"claude","note":"…","home":"p1","origin":{"instanceId":"APP-EPOCH","sessionId":"TERMINAL-SESSION"}}}`. `home` is the launching pane from `SLATE_TERM_PANE_ID`; it disambiguates labels but is not sufficient for navigation. Optional `origin` binds it to `SLATE_TERM_INSTANCE_ID` and `SLATE_TERM_SESSION_ID`. Explicit action targets such as `--pane p2` never replace the launching identity. A different socket or explicit app instance does not inherit it.
- Only hosts advertising `api.describe.presence.version == 1` receive an actor. An older host silently gets the call without it. `presence.originVersion == 1` separately advertises session-bound navigation; hosts without it still receive the actor label/home, without `origin`.
- Background services never send an actor; `--actor`/`--note` fail in a service session.

Presence is strictly for agents that identify themselves. Only administrative clients (the CLI, or a raw same-user socket client) can supply an actor; `api.describe.presence.actorOrigins` says so. A call shows nothing when:

- it carries no actor (plain scripts, shell tools, people);
- it comes from a registered plugin page or background service (their metadata actor is ignored, and `presence.hold/release` fail for them with `-32602`);
- it carries a `cause` (event-caused work, so subscribers cannot loop on presence events);
- its activity belongs to the agent's own `home` pane (a split belongs to the new pane);
- the method does not act on one pane (for example `context.get`, `pane.inspect`, `workspace.snapshot`, settings, events, or terminal operation-handle queries).

Terminal calls use their resolved terminal pane, including contextual targets. Other pane actions require a pane target; successful splits use their returned pane ID.

Presence normally begins when the call is admitted, before the method validates its arguments, so a call that is then rejected still shows briefly. Splits begin presence only after success, on the newly created pane; failed splits do not highlight the source pane.

An agent that runs a plugin command through `command run` shows on that command's target pane as itself.

## What is shown

| Call | Frame and tag on |
| --- | --- |
| `terminal capture/history/historyExport/search/send/key/run/start/wait`, `panes send/capture` | The pane |
| `pane.title`, `plugins.panelState.patch/reset`, `browser.clearSiteData` | The pane |
| `web snapshot/screenshot`, `browser snapshot/screenshot/navigate/eval`, `web scroll` without a target, an unmatched `web wait` | The pane |
| `web click/fill/select/check/set-value/focus/key`, `web scroll` with a target, matched `web wait`, `browser click/fill/select/scroll/wait` | The element, using the action's returned `rect` |
| `command run` for `split.left/right/up/down` or `pane.split` | The newly created pane, after the split succeeds |
| `command run` for other pane-scoped commands | The pane |

All pills stay in a single bottom-right group, even for element actions. Only the highlight moves to the specific element. Pills are fully rounded native Liquid Glass containers, detached 14 pt from the content area's bottom and right edges (above a browser's native status strip). They overlay content without resizing the terminal. Empty overlay space remains click-through. A pill with no live origin is disabled and does not redirect focus. The `+N` overflow chip is only a summary, not a guessed navigation target.

- **Timing.** Every call shows for at least 5 s, then fades. A call that is still running keeps its tag. `terminal run/start`, waits and navigation that take longer than 0.5 s show a spinner and elapsed time, then ✓ or ✕ (`exit N` for a failing run) for 5 s. An adopted `terminal start` keeps its activity until the operation finishes, is rejected, or loses its session, even after the submitting client disconnects. Operation status/result/wait queries do not create separate activity.
- **Merging.** Calls from the same agent session to the same pane merge into one activity. The hold extends, the note updates when a call supplies one, and the frame pulses once.
- **Several agents.** Agents targeting the same pane or identical element bounds share one frame. Each agent gets an equal-width share of its gradient (halves for two, thirds for three), with smooth blends between colors in arrival order. Color changes fade over 250 ms, or update immediately with Reduce Motion. Different element bounds retain separate frames. Tags keep arrival order. From three tags up, or in panes narrower than 200 pt, tags shrink to the name (the newest keeps its note unless the pane is narrow). Tags that still do not fit fold into a `+N` chip.
- **Labels.** A tag shows the agent name. While two sessions of the same agent are active, each label gains its home pane, for example `claude · p1` and `claude · p7`.
- **Colors.** Known agents keep one color (`claude`, `codex`, `gemini`, `cursor`, `copilot`, `amp`, `opencode`, `aider`). Other names get a stable color from a separate palette.

## Holds

```sh
slate-term presence hold --pane p4 --ttl 60 --note "triaging the sprint board"
slate-term presence release --pane p4
slate-term presence list
```

`presence.hold` keeps a tag up across many short calls. Any call by that agent session to that pane refreshes it; the note stays the hold's note. The TTL defaults to 60 s, accepts 1–600 s and clears a hold an agent forgot to release. Holding your own pane is rejected. `presence.hold` and `presence.release` require an actor; without one they fail with `-32602`. `release` returns `released: false` when there was no hold.

`presence.list` returns `{visible, activities}`. Each activity has `activityId`, `actor`, `label`, `pane`, `canFocus` (whether its claimed app/session origin is live), `actionKind` (`read`, `write`, `run`, `wait`, `navigate`, `eval`, `command`, `hold`), `count`, `live`, `leased`, `element`, and optional `tab`, `note`, `home`, `result` and `leaseExpiresInMilliseconds`. At most 256 activities exist at once; a hold beyond that fails with `-32051`, and further calls simply show no presence.

## Clicking and focusing the agent

A pill is navigable only when its actor supplies a complete origin matching this app epoch and the current terminal session in its claimed home pane. At activation, Slate revalidates the activity, pane type and session, then resolves the pane's **current** tab/window. It reuses guarded `pane.focus` and `window.focus` operations, restores a minimized window, and activates Slate. Existing pane-zoom behavior is preserved. A command picker or tab-rename editor is dismissed/cancelled before navigation; a target window with a sheet is not navigated.

Missing/expired activities, absent origins, unknown/nonterminal homes, foreign app epochs, replaced sessions and closed origins produce no navigation. There is no fallback to current focus or contextual terminal history. A new terminal in the same pane slot cannot revive an old activity; calls from a new session form a separate activity.

```sh
slate-term presence list
slate-term presence focus --activity-id a42
```

The shared `presence.focus {activityId}` operation is a mutation available to CLI/socket, registered pages (`workspace.presence.focus({activityId}, options)` or `workspace.call`) and services. It returns `{focused:false}` for an unavailable origin/activity, or `{focused:true,paneId,tabId,windowId}` after accepting navigation. `activityId` is required, at most 64 ASCII letters/digits/hyphens/underscores; malformed/unknown payload fields fail with `-32602`. Optional `expectedInstanceId` and `expectedWorkspaceRevision` guards use the standard conflict behavior; other safety guards are rejected. Pin `expectedInstanceId` when retaining activity IDs across connections/app launches. No current-pane defaults are inherited. This argument-requiring action has no new parameterless shortcut or Cmd-K entry.

**External/self-declared agents:** any same-user CLI/socket client can claim an actor name. This is not authentication, and pretending to be an agent is not prohibited. Without a pane ID and matching app/session origin, it can still show activity on an explicitly targeted pane, but its pill cannot navigate. Public origin IDs are lifetime guards, not credentials; a trusted caller that deliberately supplies another live origin can claim it. An explicit `--pane` is the operation's target, not proof of where the agent runs. Plugin pages/services may navigate listed activities but still cannot claim actors or hold activity as an agent.

## Event

`host.presence.changed` is published when an activity begins and when it ends, never per call. The envelope carries the pane and tab. The payload is value-free: `activityId`, `phase` (`began`/`ended`), `actionKind`, `actor: {name, claimed: true}`, `pane`, `count`, `leased` and, on `ended`, an optional `result` (`ok`/`failed`). Notes are not in the journal; read `presence.list`. Registered pages see events for their own tab by default.

## Setting

**Settings → AI Agents → Show agent activity on panes** (`agents.show_activity`, default on) hides or shows the overlays. It is also available as `agents.activity.show|hide|toggle` in ⌘K and `command.run`, as `slate-term agent-activity show|hide|toggle`, and through `config.patch`. Hiding changes only the display: `presence.list`, holds and events keep working.

## Not yet supported

- A plugin cannot point at its own element for a `command run` it handles; such calls frame the whole pane.
- Element frames are short-lived and do not follow later scrolling.
