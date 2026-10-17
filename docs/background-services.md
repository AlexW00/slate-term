# Manual background services

A trusted registration may declare one app-level `service`, independently of its panel and contributed commands. A service needs no pane, web view, HTTP server, or synthetic terminal identity. Registration never starts it.

```json
{"id":"controller","title":"Controller",
 "service":{"executable":"/absolute/path/controller","arguments":[],"readyTimeoutSeconds":10}}
```

## Shared API and manual controls

CLI, registered-plugin bridge and services use the **same automation API**, discovery and command inventory. There is no service permission tier or separate method allowlist. Generic clients are `slate-term rpc METHOD`, `workspace.call(METHOD, params, options)` and the generated `workspace.rpc[METHOD]` functions. `workspace.methods` comes from the same catalog as `api.describe.methods`.

```sh
slate-term plugins service list
slate-term plugins service start controller
slate-term plugins service status controller
slate-term plugins service logs controller
slate-term plugins service stop controller
```

These wrap `plugins.service.list/start/status/logs/stop`, available to every trusted client. Except `list`, each requires `{id: PLUGIN_ID}`; only the optional `expectedInstanceId` guard is accepted. `list` takes no ID. They are not parameterless picker/shortcut actions. Existing `plugins.restart/status/logs` continue to refer to panel/command lifetimes, not background services.

**Current scope is manual and session-only.** Start does not persist startup permission. There is no enable/disable/restart control, automatic startup, or automatic retry/backoff. The shared manifest's `restartLimit` does not enable retries for this runtime. After confirmed stop or failure, an explicit start creates a fresh generation. Inspect state after transport failure; never replay a mutation automatically.

Status/list entries contain `pluginId`, `serviceId` (registration runtime), `generation` (nullable before first launch), `state`, `reason`, `mode:"manual"`, `pid` (nullable supervisor PID), `cleanupConfirmed`, and `reservationHeld`. States are `stopped`, `starting`, `ready`, `stopping`, `failed`. Start reports acceptance, not readiness; duplicate starting/ready starts return the same generation. Start during cleanup conflicts (`-32050`). At most16 reservations are retained, including replaced registrations still cleaning up; exhaustion is `-32051`. Unconfirmed cleanup reports `failed/cleanupUnconfirmed`, retains its reservation, and blocks a successor rather than guessing that resources are gone. Repeated stop preserves that outcome. Stop may return `superseded:true` if registration/generation changed while cleanup awaited.

Logs return separate `stdout` and `stderr` strings from the current/last attempt, each retaining up to64KiB. Trusted clients can read them; authors should not print secrets. Host status/events never insert arguments, environments, settings values or output.

## Public identity, not bearer authentication

Each generation has a private same-user Unix endpoint (0700 directory,0600 socket, peer UID check). Its host closure binds the actual owner immutably. Neither request params nor environment claims determine ownership. This is lifecycle tracking, not an OS sandbox against trusted same-user code.

The host supplies `SLATE_TERM_SOCKET`, `SLATE_TERM_CLI`, `SLATE_TERM_INSTANCE_ID`, `SLATE_TERM_SERVICE_ID`, `SLATE_TERM_SERVICE_GENERATION`, and `SLATE_TERM_SERVICE_PLUGIN_ID`. These are public routing expectations. There is **no service bearer token**. Every endpoint uses the ordinary hello request:

```json
{"protocolVersion":1}
```

A generation endpoint's reply includes `service:{appInstanceId,pluginId,serviceId,generation}` alongside the normal protocol/app versions. The bundled client validates inherited identity on this same peer before discovery or dispatch. Partial, foreign, retired or legacy token-bearing context fails (`-32059`); it never silently discards ownership by falling back to the root socket. Restart old children with the current bundled context. There is no persisted credential migration.

Invalid repeated hello invalidates negotiation on both endpoint kinds, including malformed requests that fail before decoding. Generation endpoints additionally close/discard malformed queued work. Each generation retains four peers, a two-second initial/idle deadline (not during active requests) and one pending poll. These are resource limits, not capability restrictions.

## Context and delegated ownership

Common resolution is explicit target → validated caller defaults → documented active-context fallback or missing-resource error. Page clients can default to their bound pane, namespace and instance; a service has no fabricated page identity. Examples:

- `plugins.settings.get/patch` accept an explicit `id`; service/page callers default to their own plugin ID. `settings.get` is the applied-value alias.
- `plugins.data.get/patch/reset` access durable data shared by plugin ID without any live panel; service callers default to their own plugin ID. `plugins.panelState.get/patch/reset` require an explicit plugin pane for unanchored services and reject focus fallback. Data invalidations broadcast across runtime scopes, including during startup; read data in the cursor-before-snapshot bootstrap. See [plugin persistence](plugin-persistence.md).
- Automatic `pane.title` targeting another view requires `pane`, `title` and paired `expectedViewId`/`expectedDocumentId` from `web.get`. Stale documents are rejected. Self-page `workspace.setTitle` remains compatible.
- Configuration, window controls, built-in commands, terminal/web automation, browser evaluation, screenshots and event emission use the same handlers for all clients. Ordinary websites and subframes still receive **no bridge**; arbitrary evaluation remains browser-only, not a plugin-document capability.

Service-started contributed commands, including A→CLI→B into a different command plugin, retain the original generation endpoint and owner. Stopping that generation cancels those jobs, not unrelated root commands. Starting another service creates an independently app-managed lifetime, not an implicit child-service tree. Ordinary children have inherited `SLATE_TERM_*` stripped; intentional delegated jobs receive only host-selected routing context.

## Readiness and replay

Readiness acknowledges health; it does **not** unlock API capabilities. Starting generations can mutate, poll and delegate commands. The readiness deadline still retires a generation that never acknowledges.

1. Read all pages of `workspace.snapshot`, retaining its **initial** `eventCursor`.
2. Read current settings through `plugins.settings.get`.
3. Acknowledge readiness: `slate-term rpc service.ready --params '{"version":1}'`.
4. Poll from that retained cursor, retaining the returned batch cursor even for empty batches.

`service.ready` is a common API method. The service caller supplies its default generation; any trusted client can explicitly pass `{version:1,serviceId,generation}`. The exact live generation is validated, and duplicate readiness is idempotent. Readiness/stop remain available under exhausted mutation budgets.

Starting and ready generations receive directed settings invalidations. A change between settings fetch and readiness is replayable; refetch authoritative values rather than execute an action per notice. Snapshot conflicts (`-32050`) and expired history (`-32031`) require fresh snapshot-first synchronization. Never replay external actions. The host cannot prove arbitrary external state is synchronized.

Event queries default to the caller's page/service recipient where present. Every trusted client can select `recipient:"all"`, `{instanceId}`, or `{serviceId,generation}`; `scope:"global"` removes a caller's default tab filter. Explicit tab/topic filters remain available. `events.emit` accepts `targetInstanceId` or `targetService:{serviceId,generation}` for live recipients. Source identity is host-stamped. Observation does not transfer causation references: each delivery reference stays bound to the actual caller lifetime. Page/service mutations share their plugin's admission budget.

## Teardown and evidence

Stop, process exit, readiness timeout, successful registration replacement/removal and shutdown retire the endpoint and cancel owned requests/jobs before stopping the service group. Accepted cleanup survives requester disconnect. Failed catalog persistence does not retire the live service. Each launch uses the existing parent-death/process-group supervisor; deliberately daemonizing out of that group is unsupported.

`host.service.state.changed` facts contain bounded public status, operation attribution and current workspace revision. Starting/stopping intent is published before external effects; later facts describe observed outcomes. This is not an atomic filesystem/process/journal transaction. Shutdown delivery is not guaranteed.

`verify-service-generation.sh`, `verify-service-commands.sh` and `verify-service-session.py` are headless lifecycle/routing gates. `verify-background-services.py` uses one owned app for three-client parity, settings replay, document guards, nested ownership, replacement and shutdown. See [progress](api-extension-progress.md) for actual results and residual gaps. The older [design](background-services-design.md) is historical; the [reviewed trusted API plan](trusted-automation-api-plan.md) supersedes its permission/token assumptions.
