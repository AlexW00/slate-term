# Revised plan: one API, trusted clients

Status: source-grounded plan, independently reviewed before runtime edits; two concrete guard/lifetime corrections incorporated below. Supersedes the administrative/page/service permission matrices and bearer-credential requirements in earlier plans. Review baseline: `f8d1284`. The common API was checkpointed as `20ba881`. Token-free service transport, focused headless checks and the single owned-app parity batch are now implemented/verified; see [progress](api-extension-progress.md) for exact evidence and residual limits.

## User outcome and boundary

Powerful user-built plugins, commands, terminal agents and managed services use **one automation API**, with multiple clients—not separately maintained APIs or capability tiers. The registered-plugin bridge, CLI and service client must discover and invoke the same operations. Differences are transport, caller defaults, lifetime/cancellation, and resource availability.

Registered plugin main frames are trusted controllers. Ordinary websites, unregistered origins and subframes still receive no bridge. Same-user native code is not OS-sandboxed; a second bearer secret does not establish a meaningful security tier when native plugin backends already receive the administrator socket.

Keep existing manual service start/stop/list/status/logs and resource ownership. Do not add automatic startup, enable/disable preferences, restart/backoff, hidden panes, maximize UI, new storage lifetimes, divider work or a new RPC/IDL framework. Preserve `pane.zoom`, visibility/renderability checks, guards, budgets and no-automatic-replay behavior.

## Source findings

| Current location | Problem / reusable foundation |
| --- | --- |
| `Native/WorkspaceAPI.swift` | `apiMethods(plugin:)` and `describeAPI(plugin:)` independently project method/command access and screenshot capability. |
| `Native/WorkspaceHost.swift` | `callAsync`/`call` already implement common host operations, but the plugin adapter keeps a second method switch, an allowlist check and indirect administrative denial. Service controls also reject non-administrative origins. |
| `Native/ServiceAPI.swift` | Separate method list, descriptor and scoped dispatcher restrict services and duplicate existing reads. |
| `Sources/SlateTermCore/CommandContract.swift` | `pluginAccessible` classifies permissions; argument/context metadata remains useful. |
| `Native/PluginPane.swift` | Correct registered-origin/main-frame/document binding and cancellation boundary; a generic `workspace.call` already exists. Its convenient method-name lists can drift. Its isolated bridge token protects the document boundary and is **not** the service bearer being removed. |
| `Sources/SlateTermCore/ServiceSession.swift`, IPC client/server, CLI `Connection` | Service bearer tokens, secret comparison and a separate authenticated handshake add a second permission tier. Same-peer negotiation and expected public identity checks remain useful. |
| `BackgroundServiceGeneration`, `BackgroundServices`, `PluginControlConnection`, `PluginCommands` | Retain host-bound generation identity, delegated endpoint selection, readiness deadline, request cancellation,16 reservations, exact owned-job cleanup and bounded logs. Remove token creation and readiness-as-permission checks. |
| `EventControl` / `SettingsLifecycle` | Causation audience and directed recipient identity are useful context. They must not become an unoverrideable trusted-client visibility tier. |
| Workspace model, renderer and persistence | No separate hidden-pane implementation exists. Removed its proposed API/phase/requirements; ordinary zoom/visibility code is untouched. |

## 1. Single method contract and dispatch path

Introduce a small Core method catalog (typed method identifier plus public/internal classification, operation family and context/parameter policy), reusing `CommandRegistry`/`CommandContract` for workspace and contributed commands. Do not add a schema compiler or duplicate business implementations.

- One shared host API entry parses the method/parameters, resolves caller defaults and explicit targets, freezes those targets, validates target-dependent guards against those resolved targets, admits once and calls existing authoritative operations. Preserve existing native-observation settlement before final target/guard checks. Do not validate a page-default request against the unrelated active tab.
- CLI socket, registered bridge and generation endpoint forward into that entry. Remove the plugin/service allowlists and parallel dispatch switches; service management remains an ordinary operation family.
- `api.describe.methods`, command discovery and capability metadata come from that catalog for every trusted client. Caller identity/context may be reported separately, but not as a different capability `surface`.
- Remove permission decisions based on `pluginAccessible`. If retained for wire compatibility, it is deprecated and uniformly true for public commands; it must not control dispatch/discovery. Keep argument requirements and workspace-independent targeting metadata.
- Generic `slate-term rpc METHOD` and `workspace.call(METHOD,…)` access every public catalog method. Existing typed CLI/JS conveniences remain thin adapters. Generate namespace method inventories/SDK constants from the catalog where practical; check remaining aliases against it, rather than keeping another authoritative list.
- Internal shell telemetry and integration-only debug controls remain explicitly non-public protocol/integration operations for **all** clients. Do not accidentally advertise debug helpers or remove shell-session/run-key validation.

The catalog is an admission/discovery contract, not a decorative list: unregistered public names cannot bypass it through a legacy switch. A dispatch-coverage check must catch a catalog entry without an implementation and a public implementation omitted from discovery. Prefer typed/exhaustive family routing; retain existing operation helpers instead of rewriting unrelated behavior.

## 2. Context is not permission

Use one host-created immutable caller context: public origin, causation audience, optional pane/tab, plugin namespace/instance, optional service owner, and a live-caller validator. Request data cannot assign origin or ownership.

Common resolution order: explicit inputs → validated caller defaults → the operation's documented fallback or missing-target error. Preserve frozen/revalidated targets across awaits. Never silently replace stale supplied context with current focus. Do not inject pane/tab fields into global methods that do not accept them.

- Page requests can default to their calling pane/namespace/instance. Explicit valid targets/namespaces may override those defaults, just as for other trusted clients.
- Service and external CLI requests do not invent a page instance. Operations with no such context require explicit resource selectors, or use the same documented active-context fallback as other clients—not a separate service prohibition.
- `plugins.settings.get/patch` support the same explicit `id` on every client. `settings.get` remains the legacy applied-value alias, with a caller namespace default where available.
- Existing `storage.get/set/delete` and automatic `pane.title` become common operations with explicit plugin-instance/pane selectors and page defaults. Missing/wrong resource kind is a typed context error, not a privilege denial. Storage remains **logical-instance-scoped**, not a new service/app storage namespace.
- Automatic titles are **view/document-scoped**, not logical-instance-scoped. A self-page call defaults to its bound current document. Cross-view/CLI/service targeting must carry the public `expectedViewId`/`expectedDocumentId` pair; extend shared guard handling to `pane.title`, validate the live target identity using existing automation/navigation lifetime machinery and revalidate immediately before setting the title. Do not apply the caller's document defaults to an explicitly different target. A stale title update must not rename a successor document after navigation; views sharing an instance retain independent titles.
- Service controls are callable by any trusted client. Starting another service creates an independently app-managed lifetime, not an implicit child-service tree. Contributed commands keep the initiating service owner and are canceled with that generation.
- Self-closing/unregistering clients may lose their response after a committed effect; preserve unknown-outcome/no-replay semantics rather than promising rollback.

## 3. Event routing and causation

Keep typed page/service recipient identities and generation/view-bound causation references. Remove the assumption that causation audience is a permission tier for reading events.

One shared poll query supports explicit recipient selection: all directed events, a page instance, or a service generation. Caller-context defaults may keep page/service subscriptions relevant to themselves; **every trusted client can explicitly select the same all/targeted observation**. Explicit tab/topic filters are not forbidden based on caller kind. Document defaults and use the same resolver for every transport.

`events.emit` is one common operation with the same accepted routing fields and validation for every trusted client; provenance is host-stamped from caller context, never copied from params. A service source needs a truthful typed service identity, not a fabricated page instance. Keep host-topic restrictions, size limits and value-free settings invalidations. Event observation does not authorize reusing another client's causation reference: each delivery gets a reference for its current caller lifetime.

Per-owner/global feedback-loop admission, resource caps and document/generation liveness remain. They are documented operational safeguards, not method permission tables.

## 4. Remove service bearer credentials; retain public lifetime binding

Keep a dedicated private Unix endpoint per generation **as an ownership/cancellation boundary**, not a lower-privilege API. Reuse the ordinary same-user socket protections (0700 directory,0600 socket, peer UID check) and ordinary versioned hello.

- Remove `ServiceCredentials`, random token generation, `SLATE_TERM_SERVICE_TOKEN`, constant-time secret comparison, service-specific authentication flags and separate service-protocol authentication fields.
- Bind `ServiceIdentity` immutably in the endpoint's host closure. Never reconstruct the request owner from caller-supplied params/environment.
- The normal hello response may include the endpoint's **public** service identity. The bundled client checks it against inherited public app/plugin/service/generation context before dispatch. A stale/wrong endpoint or incomplete inherited context fails rather than silently changing ownership.
- Keep same-peer discovery/dispatch, no reconnect/replay, and exact owner validation when delegating command environments. Public `SLATE_TERM_SERVICE_*` identity fields are routing expectations, not authentication claims.
- Keep deliberate ordinary-child environment stripping and delegated A→CLI→B identity propagation. Remove secret-focused redaction/authentication code/tests, not lifecycle mismatch checks.
- Use the protocol session's handshake state rather than a second authentication state machine. Invalid repeated hello must invalidate negotiation consistently; retain bounded connection/queue/deadline behavior. Do not introduce unrelated transport compatibility changes.
- Readiness is health/lifecycle acknowledgement, **not an API privilege unlock**. Remove the bootstrap capability allowlist and ready-only command delegation. Keep the readiness timeout and duplicate-ready idempotence.
- Define `service.ready` once in the common catalog. Resolve the current generation from the service caller default or an explicit service/generation selector available to any trusted client. Validate the exact live generation before acknowledgement; missing/retired context is a typed error. No separate hidden service RPC API.

Stopping retires the endpoint and requests first, then owned commands and process groups. Keep unconfirmed-cleanup reservations, cancellation-independent cleanup and the existing manual manager's no-overlap rules. Do not remove page bridge document binding or causation references merely because they also use opaque values.

## 5. Cleanup and compatibility

- Finish canceled hidden-pane documentation cleanup; no runtime deletion is appropriate because that feature was never implemented.
- Remove obsolete service-only adapter/descriptor branches and permission-focused machinery/tests, replacing them with one shared dispatch implementation and positive parity tests.
- Update `AGENTS.md`, API/plugin/service/event docs and relevant earlier plan status notes: registered plugins are trusted; the old capability matrices and bearer requirement are superseded. Preserve historical evidence as historical, not current policy.
- Preserve existing method names, CLI commands and JS conveniences where possible. Avoid a broad rename. Document any new explicit selector needed to use a previously page-context-only operation from CLI/service.
- Existing plugins need no service token. Old inherited token-bearing service context is not silently promoted; restart using the current bundled client/context. No persisted credential migration exists.

## 6. Focused evidence and implementation order

1. **Review this plan now.** Resolve concrete authority/lifecycle/drift issues before runtime edits; one bounded read-only review, no GUI or nested delegation.
2. **Implement catalog/common dispatch and context resolution**, including formerly page-only operations and event query semantics. Add contract checks while replacing old privilege-denial assertions. Do not leave temporary divergent allowlists as the final state.
3. **Simplify service identity/IPC/CLI** and connect the generation endpoint to common dispatch. Remove the secret handshake and pre-ready permission gate without weakening ownership/cleanup.
4. **Headless checks first:** catalog uniqueness/discovery/dispatch coverage; alias inventory; guard/default resolution (including an inactive-tab page default); target-document title staleness and shared-instance/distinct-view titles; ordinary/service public hello parity, repeated-hello behavior including malformed pre-decode input, wrong/retired routing; delegated ownership and cleanup; readiness without a capability gate; explicit event selection independent of audience and caller-bound causation.
5. **One announced, batched owned-app fixture** after the build passes: compare normalized discovery for CLI/bridge/service; exercise representative reads and mutations through all three; formerly denied config/window/browser/service controls and settings targeting; explicit page storage/title targeting from CLI/service; event all/targeted modes; service startup mutation/ready, nested ownership/stop, stale generations/documents, ordinary-page/subframe rejection and zoom/visibility safeguards. Use isolated fixture data; avoid clicks, activation and screenshots. Adapt existing representative fixtures rather than launch the broad suite.
6. Record actual checks and residual gaps, update docs, and checkpoint with per-command unsigned Git configuration as authorized. No push. Do not roll into automatic startup/restart or new UI.

## Independent review disposition

One bounded read-only reviewer inspected this plan and the current host, bridge, guards and transport. No builds/tests/GUI/Git changes or delegation were performed. Two P2 plan gaps were identified and corrected:

1. Resolve and freeze caller-default targets **before** target-dependent guard checks, preserving inactive-tab page behavior rather than consulting current focus.
2. Externally targeted automatic titles need exact view/document identity, not only pane/logical-instance selection. Extend the existing public identity guards and retain immediate lifetime revalidation; storage remains instance-scoped.

The reviewer otherwise found the common catalog/dispatch, event-observation versus causation separation, and credential-free generation ownership consistent with the source without a larger framework. Implementation evidence for replacement of old capability denials, lifecycle regressions, malformed repeated hello, explicit event observation with caller-bound causes and pre-ready ownership is recorded in [progress](api-extension-progress.md). This does not claim a full sequential or visual certification.

Acceptance: same public discovery and capabilities for all trusted clients; one validation/dispatch definition; no service bearer secret or permission tier; no ordinary-web/subframe bridge; stale work stays rejected; owner cleanup survives requester disconnect; no hidden-pane feature; no fabricated full-suite/visual certification. The first useful milestone after review is the common catalog/dispatch boundary and headless drift tests, not a new feature backlog.
