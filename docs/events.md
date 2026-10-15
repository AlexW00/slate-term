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

## Causation and loop admission

Poll-delivered events carry an opaque `deliveryContext`. Pass it explicitly for event-triggered work:

```js
await workspace.command("pane.title.set", {pane: "p1", title: "Build finished"}, {
  cause: event.deliveryContext,
  signal: controller.signal
});
```

Mutation helpers accept a final `{cause, signal}` options argument; `emit` accepts these alongside its existing routing options. There is no implicit cause across awaits. CLI callers use `--cause DELIVERY_CONTEXT`; arbitrary contributed-command `params.cause` remains ordinary command data.

References bind retained lineage to an audience. Administrative references span same-user socket connections within this app epoch. Page references bind registration, instance, view and native document generation; another view—even of the same global instance—cannot reuse them. Navigation/restart retires that audience. Replay reuses a live reference without renewing its expiry; sibling work may reuse it without consuming it. References last at most five minutes and may be evicted sooner (4096 globally, 256 per audience). A causal chain permits depth eight. Accepted async work retains its lineage after reference expiry.

Automation admission allows 10 mutations/second with a burst of 20 per plugin ID across its views, plus 100/second with a burst of 100 globally, including administrators. Side-effecting requests are charged once through shared dispatch; admitted failures and successful no-ops are not refunded. Reads/resynchronization, native user actions, transport cancellation and authenticated shell telemetry/run-input delivery remain available. These are feedback-loop limits, not protection against trusted code deliberately starting new roots. Failure codes and refill information are documented in [control](control.md#failures-and-recovery); do not automatically replay mutations.

## Native topics

- `host.workspace.changed`: model/layout/focus/native-tab changes; read `workspace.get`/`context.get` for current state.
- `host.context.changed`: authenticated shell reports or terminal-engine metadata changes. Includes session/sequence identifiers, not the command text; read context for details.
- `host.plugins.changed`: successful registration/unregistration.
- `host.plugin.state.changed`: native service state, instance ID and type.
- `host.plugin.storage.changed`: changed key, directed to the owning logical instance after successful persistence.

## Workspace commit facts

Workspace changes now use a prepared model/revision/journal commit rather than discovering changes at autosave. Canonical facts include `operationId`, `actionKind`, `beforeWorkspaceRevision`, `workspaceRevision`, relevant pre/post layout revisions, and native-assigned `origin`. Host envelopes still have `source: {kind:"host"}`. The origin is `native`, `administrative`, or `plugin` (with bound plugin/instance/view IDs); request arguments cannot select it. Literal manual titles are not included.

Facts include `host.pane.created`, `.closed`, `.type.changed`, `.title.changed`, `.moved`; `host.tab.created`, `.closed`, `.moved`, `.reordered`; and `host.layout.resized`. Resize facts identify split paths, not entire trees. Displaced tabs receive reorder facts too. Legacy split aliases normalize to the same split intent. Compatibility layout/focus/tab-group/workspace notifications share the operation ID and revisions. No-op model changes emit no fabricated facts.

`api.describe.workspaceCommit` advertises the workspace commit/result contract and its current native-divider coalescing status. Built-in workspace mutation replies include `operationId`, `outcome` (`committed` or `unchanged`), `workspacePersistence` and the operation's own `workspaceRevision`, in addition to existing result fields. Raw reads and arbitrary contributed-command values are not wrapped. A native title draft ending during reconciliation can commit separately before the reply is sent: the reply still identifies its initiating operation, not the later native revision. Inspect again when a subsequent guard conflicts. For `window.focus`, an unchanged model does not imply unchanged native window presentation. Unregistering an unused plugin is committed registry work even when the workspace revision is unchanged.

`workspacePersistence` reports this operation's workspace snapshot save: `saved`, `failed`, `disabled` (restoration disabled), `suspended` (preserving a bad startup snapshot), or `notRequired` (registry-only unregister). A failed save does not undo accepted live state or its events and is not permission to replay the mutation. Filesystem diagnostics remain in application status rather than these page-accessible results. This status concerns only the workspace snapshot—not shell startup, WebKit, other files or power-loss durability.

Facts for one operation can span polls or exceed retained history. Atomic publication is not an atomic delivery guarantee; an old cursor can require explicit resnapshot recovery even when its filter matches none of a large batch.

**Phase 3b remains in progress.** Request metadata, delivery references and admission are separate capabilities advertised by `api.describe.causation`; correlation IDs alone do not imply support. Lifecycle capabilities have their own discovery entries below; final native-divider certification remains outstanding. Do not automatically turn every change into another mutation.

## Registered-command lifecycle

`api.describe.commandLifecycle` advertises `host.command.started` and `host.command.finished` for admitted registered-command invocations—not arbitrary shell activity. Start is published before spawning; completion is consumed once on success, exit/spawn/supervisor failure, timeout, cancellation or registration retirement. Shutdown closes jobs before the journal, but delivery is not guaranteed during teardown.

Facts retain `invocationId`, `commandId`, state, optional exit/signal/termination reason, captured historical target IDs, and admitted operation/origin/lineage. They never contain arguments, environment, settings, output or arbitrary diagnostic messages. Existing command results and log APIs are unchanged.

Start and finish sample equal before/after workspace/layout revisions at their own publication times. `launchWorkspaceRevision`/`launchLayoutRevision` separately identify launch state; unrelated intervening changes are not attributed to the command. A missing captured target has `targetAvailable:false` and null layout revisions; an unanchored command has null target availability. An accepted job retains its lineage even if its delivery reference expires or its initiating page retires.

## Configuration lifecycle

`api.describe.settingsLifecycle` covers configuration source and applied configuration—not the separate close/type-warning preference stores. `host.settings.source.changed` reports an observed source revision change, including comments or invalid source. `host.settings.changed` reports changed applied configuration only after successful application. A successful no-op fabricates neither change. External source observations use a separate native operation, even when a read notices them before the file watcher.

Global settings envelopes contain opaque operation/source/applied revisions and bounded validity/match/outcome flags. They deliberately omit initiating plugin/instance/view IDs, pane/tab, private parent details, specific intent and namespace paths. `host.plugin.settings.changed` is directed to each eligible logical instance of the changed namespace; it adds the plugin ID and changed **top-level** paths, never values. Paths are bounded to 32 entries and 4096 JSON-encoded bytes with total count and truncation; fetch current own settings rather than reconstructing them from these summaries.

Possible bounded publications are preflighted before source persistence/runtime effects. Actual outcomes are published afterward against the current journal; this is not an atomic transaction across the filesystem, runtime and journal. `host.settings.failed` contains observed source validity/match state and whether the intended source remains persisted when knowable. A rollback or external edit never invents successful application. Unreadable source is reported with null source revision and retained applied state. Reload/patch failures carry safe operation correlation; diagnostic strings and paths are not copied into event envelopes. Resnapshot before retrying uncertain writes.

## Bounds

Retention is at most 1,024 events and 2 MiB; each encoded event is at most 16 KiB. Publication and batch admission reserve 128 bytes per event for delivery metadata, reducing available payload space. Batches contain at most 128 events and 512 KiB. There are at most 128 pending native polls, 64 topic patterns per filter, and 32 outstanding bridge calls per view. Cancellation still works when all bridge slots are occupied. Overload is explicit rather than silently dropping matching events. Disconnecting a Unix peer cancels its suspended poll.
