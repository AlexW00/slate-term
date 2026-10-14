# Workspace events

The app owns a bounded, in-memory journal. Every event has a resumable `cursor`, increasing `sequence`, `topic`, wall-clock `timestampMillis`, native-assigned `source`, optional `tab`/`pane`/`targetInstanceId`, and JSON `payload`. Order by sequence, not timestamp. Events are not persisted across app launches.

```sh
slate-term events head
slate-term events watch --topic 'host.context.*'
slate-term events emit --topic build.finished --payload '{"exitCode":0}' --tab t1
slate-term events poll --after CURSOR --topic 'build.*' --limit 20 --wait-milliseconds 0
```

`watch` writes one compact event JSON object per line until interrupted or an error occurs. `poll` returns `{cursor, events}` once; it waits up to 20 seconds by default, or returns immediately if matching retained events exist. `--wait-milliseconds` accepts 0–25000; watch requires a positive wait. Event filter flags are explicit: inherited terminal pane/tab variables are not automatically applied to event commands.

Topics use dot-separated lowercase ASCII components beginning with a letter, followed by letters, digits, `_` or `-`; at most 128 bytes. Filters accept exact topics or a trailing namespace wildcard, such as `build.*`. Repeat `--topic` to OR filters. Omit topics to receive all events. Invalid filters are rejected, not widened.

## Cursors and recovery

A cursor is `<app-epoch UUID>:<sequence>`. Omitting `after` starts at the current head, not the retained beginning. `<epoch>:0` requests replay from the beginning if it is still retained.

The returned batch cursor includes scanned nonmatching events. Always retain the **batch cursor** when building a polling client, including empty batches. A bounded batch never advances past an unreturned matching event.

Restarted or expired cursors fail with JSON-RPC error `-32031`. Invalid/future cursors fail validation. Neither the CLI nor plugin SDK silently skips history. To recover:

1. Obtain a new cursor with `events.head`.
2. Read the current workspace/context or your application's state.
3. Resume from that cursor, tolerating redundant state refreshes during replay.

Obtaining the cursor before the state read avoids missing a change between them. The journal is not a durable job queue or an exactly-once delivery system.

## Sources and routing

The native envelope identifies `{kind:"host"}`, `{kind:"client"}`, or `{kind:"plugin",type,instanceId}`. Clients and plugins cannot choose their source or publish under `host.`. Do not treat a payload's arbitrary fields as provenance.

Unix callers are same-user administrators and can monitor the journal, including directed events. Explicit `tab` and `pane` fields on their publications are routing metadata. Plugins publish with the current native view's actual tab/pane and registered instance identity.

Logical pane/tab plugin instances subscribe within their owning tab by default; global instances observe all tabs. Optional pane/topic filters narrow delivery. A plugin cannot widen its owning-tab filter or override its native recipient identity. This contextual routing is not a sandbox: registered plugins are explicitly trusted with terminal and workspace control.

`targetInstanceId` directs an event to a live logical plugin instance, including all its subscribed visible views. Matching directed delivery bypasses tab/pane filters, but not topic filters; other plugin instances cannot receive it. Untargeted events with absent tab/pane fields broadcast through the corresponding filters.

## Plugin API

```js
const stop = await workspace.subscribe(async event => {
  // Refresh authoritative state; avoid assuming events are durable snapshots.
  const context = await workspace.context();
  render(context);
}, {
  topics: ["host.context.*", "host.workspace.*"],
  onError(error) { showResyncRequired(error); }
});

await workspace.emit("build.finished", { exitCode: 0 });
await workspace.emit("review.requested", { file: "README.md" }, {
  targetInstanceId: recipientId
});
stop(); // cancels the outstanding native poll, not just future callbacks
```

Options also accept `after`, `limit`, `waitMilliseconds`, `tab`, and `pane`. Handlers run sequentially; slow handlers can outlive retained history and receive an explicit error. A failed subscription stops and calls `onError` if supplied.

Generic bridge calls accept cancellation:

```js
const controller = new AbortController();
const pending = workspace.call("events.poll", {
  topics: ["build.*"], waitMilliseconds: 25000
}, { signal: controller.signal });
controller.abort(); // rejects with AbortError
```

Cancellation releases suspended work; it cannot undo a synchronous command already performed. Closing/replacing a view, navigating to a new document, or leaving a page ends its outstanding requests/subscriptions. After a cached history restoration, establish new subscriptions from the page's `pageshow` handler. The SDK uses `slate-document-*` DOM events for public generation correlation without changing page markup; the privileged bridge credential remains isolated from page code.

## Native topics

- `host.workspace.changed`: model/layout/focus/native-tab changes; read `workspace.get`/`context.get` for current state.
- `host.context.changed`: authenticated shell reports or terminal-engine metadata changes. Includes session/sequence identifiers, not the command text; read context for details.
- `host.plugins.changed`: successful registration/unregistration.
- `host.plugin.state.changed`: native service state, instance ID and type.
- `host.plugin.storage.changed`: changed key, directed to the owning logical instance after successful persistence.

## Bounds

Retention is at most 1,024 events and 2 MiB; each encoded event is at most 16 KiB. Batches contain at most 128 events and 512 KiB. There are at most 128 pending native polls, 64 topic patterns per filter, and 32 outstanding bridge calls per view. Cancellation still works when all bridge slots are occupied. Overload is explicit rather than silently dropping matching events. Disconnecting a Unix peer cancels its suspended poll.
