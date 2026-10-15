# Manual background services

A trusted registration may declare one app-level `service`, independently of its panel and contributed commands. A service needs no pane, web view, HTTP server, or synthetic terminal identity. Registration never starts it.

```json
{"id":"controller","title":"Controller",
 "service":{"executable":"/absolute/path/controller","arguments":[],"readyTimeoutSeconds":10}}
```

## Administrative controls

```sh
slate-term plugins service list
slate-term plugins service start controller
slate-term plugins service status controller
slate-term plugins service logs controller
slate-term plugins service stop controller
```

These wrap `plugins.service.list/start/status/logs/stop`. Except `list`, each requires `{id: PLUGIN_ID}`; only the optional `expectedInstanceId` guard is accepted. `list` takes no ID. They are administrative-only, including indirect invocation, and are not parameterless picker/shortcut actions. Existing `plugins.restart/status/logs` continue to refer to panel/command lifetimes, not these services.

**Current scope is manual and session-only.** Start does not persist startup permission. There is no enable/disable/restart control, automatic startup, or automatic retry/backoff yet. The shared manifest's `restartLimit` does not enable retries for this manual service runtime. After confirmed stop or failure, an explicit start creates a fresh generation and credential. Inspect state after transport failure; never replay a mutation automatically.

Status/list entries contain `pluginId`, `serviceId` (registration runtime), `generation` (nullable before first launch), `state`, `reason`, `mode:"manual"`, `pid` (nullable supervisor PID), `cleanupConfirmed`, and `reservationHeld`. States are `stopped`, `starting`, `ready`, `stopping`, `failed`. Start reports acceptance, not readiness; a duplicate starting/ready start returns the same generation. Start during cleanup conflicts (`-32050`). At most16 reservations are retained, including replaced registrations still cleaning up; exhaustion is `-32051`. Unconfirmed cleanup reports `failed/cleanupUnconfirmed`, retains its reservation, and blocks a successor rather than guessing that resources are gone. Repeated stop preserves that outcome. Stop may return `superseded:true` if the registration/generation changed while cleanup awaited.

Logs return separate `stdout` and `stderr` strings from the current/last attempt, each retaining up to64KiB of process output. They are administrator-only: a service may itself print secrets. Host status/events never insert credentials, arguments, environment, settings values, or output.

## Authentication and scoped access

The host supplies `SLATE_TERM_SOCKET`, `SLATE_TERM_CLI`, `SLATE_TERM_INSTANCE_ID` and the exact `SLATE_TERM_SERVICE_*` credential bundle. The bundled CLI authenticates and checks the expected app/service/generation before discovery or dispatch. Partial, foreign, or retired context fails closed (`-32059`), never as an administrator. Credentials are ephemeral; do not print, persist, or forward them to unrelated processes. Trusted same-user code is not sandboxed.

`api.describe` on that endpoint advertises `surface:"service"` and this intentionally narrow allowlist:

- `api.describe`, `workspace.snapshot`, `pane.inspect`;
- `settings.get` (applied own values), `plugins.settings.get` (own values/applied values/write revision);
- `events.head`, `events.poll` (one pending poll per generation);
- `command.list`, `command.run` (contributed `plugin.*` commands only);
- `service.ready` with `{version:1}`.

Own settings cannot be redirected to another plugin. `pane.inspect` requires an explicit pane; non-global snapshots require an explicit pane. Contributed commands may supply explicit pane/tab targets, otherwise they run unanchored—no active-pane fallback. Layout guards also require an explicit target. Service-started commands, including A→CLI→B nesting into a different command plugin, retain the service endpoint and owner. Stopping the service cancels those jobs, not unrelated administrator commands.

Global configuration, plugin/service/window administration, page storage, custom event emission, built-in workspace commands, terminal/web automation and settings writes are **not exposed in this slice**. Ordinary pages and subframes receive no service bridge. Broader controller access remains deferred rather than silently inheriting the administrator handler.

## Bootstrap and replay

Before readiness only the documented bootstrap reads and `service.ready` are available. Polls and contributed commands are unavailable (`-32051`) until ready.

1. Read all pages of `workspace.snapshot`, retaining its **initial** `eventCursor`.
2. Read current own settings through `plugins.settings.get`.
3. Acknowledge readiness: `slate-term rpc service.ready --params '{"version":1}'`.
4. Poll from that retained cursor, always retaining the returned batch cursor, even for empty batches.

Starting as well as ready generations receive directed own-settings invalidations. A settings change between step2 and readiness is therefore replayable; refetch authoritative values rather than executing an action per replayed notice. Snapshot conflicts (`-32050`) and expired history (`-32031`) require a fresh snapshot-first synchronization. Never replay external actions. The host cannot prove an author's external state is synchronized.

`targetService:{serviceId,generation}` is host-assigned routing, distinct from page `targetInstanceId`. Services cannot receive another service/page's directed facts. Administrators may monitor all. Delivered causation references are generation-bound; service and page mutations share their plugin's admission budget. Readiness remains available under exhausted mutation budgets.

## Teardown and events

Stop, process exit, readiness timeout, successful registration replacement/removal, and shutdown revoke the endpoint and cancel owned requests/jobs before stopping the service group. Accepted administrative cleanup survives requester disconnect. Failed catalog persistence does not retire the live service. Each launch uses the existing parent-death/process-group supervisor; deliberately daemonizing out of that group is unsupported.

`host.service.state.changed` facts contain bounded public status, operation attribution and current workspace revision. Starting/stopping intent is published before its external effects; later facts describe observed outcomes. This is not an atomic filesystem/process/journal transaction. Shutdown delivery is not guaranteed.

Verification: `verify-service-generation.sh` exercises native generations/manager without windows; `verify-background-services.py` batches production CLI, scoping, settings replay, nested command ownership, replacement and shutdown in one owned app. See `api-extension-progress.md` for actual results, not just available tests. Full lifecycle roadmap: [design](background-services-design.md).
