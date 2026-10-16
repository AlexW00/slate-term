# Agent presence

When a coding agent acts on a pane through the CLI, Slate frames the smallest target it knows and shows a tag with the agent's name and an optional short note. Presence is display only. It never affects admission, authorization, routing or focus.

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
- The CLI sends both in request metadata, next to `cause`: `"metadata":{"version":1,"actor":{"name":"claude","note":"…","home":"p1"}}`. `home` is the launching pane from `SLATE_TERM_PANE_ID`, used only to tell two sessions of the same agent apart.
- Only hosts advertising `api.describe.presence.version == 1` receive an actor. An older host silently gets the call without it.
- Background services never send an actor; `--actor`/`--note` fail in a service session.

Presence is strictly for agents that identify themselves. Only administrative clients (the CLI, or a raw same-user socket client) can supply an actor; `api.describe.presence.actorOrigins` says so. A call shows nothing when:

- it carries no actor (plain scripts, shell tools, people);
- it comes from a registered plugin page or background service (their metadata actor is ignored, and `presence.hold/release` fail for them with `-32602`);
- it carries a `cause` (event-caused work, so subscribers cannot loop on presence events);
- it targets the agent's own `home` pane;
- the method does not act on one pane (for example `context.get`, `pane.inspect`, `workspace.snapshot`, settings, events), or its pane is only implied by `--tab`/`--active`.

Presence begins when the call is admitted, before the method validates its arguments, so a call that is then rejected still shows briefly.

An agent that runs a plugin command through `command run` shows on that command's target pane as itself.

## What is shown

| Call | Frame and tag on |
| --- | --- |
| `terminal capture/send/key/run/wait`, `panes send/capture` | The pane |
| `web snapshot/screenshot`, `browser snapshot/screenshot/navigate/eval`, `web scroll` without a target, an unmatched `web wait` | The pane |
| `web click/fill/select/check/set-value/focus/key`, `web scroll` with a target, matched `web wait`, `browser click/fill/select/scroll/wait` | The element, using the action's returned `rect` |
| `command run` for a pane-scoped command | The pane |

Pane tags hang from the bottom edge of the pane header at the top right. Element tags sit above the element's frame. Overlays are drawn above pane content, take no clicks or focus and never change a terminal's size.

- **Timing.** Every call shows for at least 1.6 s, then fades. A call that is still running keeps its tag. `terminal run`, waits and navigation that take longer than 0.5 s show a spinner and elapsed time, then ✓ or ✕ (`exit N` for a failing run) for 1.3 s.
- **Merging.** Calls from the same agent session to the same pane merge into one activity. The hold extends, the note updates when a call supplies one, and the frame pulses once.
- **Several agents.** The frame becomes a gradient through their colors in arrival order. Tags keep arrival order. From three tags up, or in panes narrower than 200 pt, tags shrink to the name (the newest keeps its note unless the pane is narrow). Tags that still do not fit fold into a `+N` chip.
- **Labels.** A tag shows the agent name. While two sessions of the same agent are active, each label gains its home pane, for example `claude · p1` and `claude · p7`.
- **Colors.** Known agents keep one color (`claude`, `codex`, `gemini`, `cursor`, `copilot`, `amp`, `opencode`, `aider`). Other names get a stable color from a separate palette.

## Holds

```sh
slate-term presence hold --pane p4 --ttl 60 --note "triaging the sprint board"
slate-term presence release --pane p4
slate-term presence list
```

`presence.hold` keeps a tag up across many short calls. Any call by that agent session to that pane refreshes it; the note stays the hold's note. The TTL defaults to 60 s, accepts 1–600 s and clears a hold an agent forgot to release. Holding your own pane is rejected. `presence.hold` and `presence.release` require an actor; without one they fail with `-32602`. `release` returns `released: false` when there was no hold.

`presence.list` returns `{visible, activities}`. Each activity has `activityId`, `actor`, `label`, `pane`, `actionKind` (`read`, `write`, `run`, `wait`, `navigate`, `eval`, `command`, `hold`), `count`, `live`, `leased`, `element`, and optional `tab`, `note`, `home`, `result` and `leaseExpiresInMilliseconds`. At most 256 activities exist at once; a hold beyond that fails with `-32051`, and further calls simply show no presence.

## Event

`host.presence.changed` is published when an activity begins and when it ends, never per call. The envelope carries the pane and tab. The payload is value-free: `activityId`, `phase` (`began`/`ended`), `actionKind`, `actor: {name, claimed: true}`, `pane`, `count`, `leased` and, on `ended`, an optional `result` (`ok`/`failed`). Notes are not in the journal; read `presence.list`. Registered pages see events for their own tab by default.

## Setting

**Settings → AI Agents → Show agent activity on panes** (`agents.show_activity`, default on) hides or shows the overlays. It is also available as `agents.activity.show|hide|toggle` in ⌘K and `command.run`, as `slate-term agent-activity show|hide|toggle`, and through `config.patch`. Hiding changes only the display: `presence.list`, holds and events keep working.

## Not yet supported

- A plugin cannot point at its own element for a `command run` it handles; such calls frame the whole pane.
- Element frames are short-lived and do not follow later scrolling.
