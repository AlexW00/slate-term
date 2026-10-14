# Plugin integration and hooks audit

Audit baseline: checkpoint `1f80bde`. This documents the supported API and missing integration points. It does **not** introduce a hook SDK, synchronous interception, or always-running headless plugins.

**Subsequent extension:** [manifest `headerButtons`](plugins.md#native-frame-buttons) now contributes command-backed buttons beside Close for all pane types, built-ins, or exact plugin widget IDs. This does not add arbitrary native view injection or a live JavaScript callback API.

## What works today

| Capability | Supported surface | Boundary |
|---|---|---|
| User-invoked behavior without UI | Manifest executable commands; native shortcut/menu; `command.run` | On demand; no startup activation. One invocation per command, bounded concurrency/runtime/output. |
| Macros / command composition | Script invokes multiple CLI/socket operations; page invokes multiple `workspace.command` calls | Useful orchestration is already possible. No declarative macro language, multi-command transaction, or automatic rollback. Failure can leave earlier steps committed. |
| Render custom content | Trusted directory or URL panel; optional managed HTTP process | Content lives inside a pane's web view. No arbitrary native toolbar/tab-strip/header/layout injection. Header automatic title is supported. A subsequent implementation adds declarative, command-backed native header buttons; see below. |
| Terminal automation | `terminal.send/key/capture/run/wait`, context and session IDs | Literal input and current-screen capture; authenticated prompt checks for `run`. Unknown shell state stays unknown. See `automation.md`. |
| Read workspace | CLI/socket `workspace.get`, `layout.get`, `panes.list`, `tabs.list`, `context.get`; allowlisted page calls | State is a current read, not a transaction with a previous event. |
| Change workspace | Existing built-in `command.run` actions | Not all native/model operations are public. See the [layout audit](layout-cli-audit.md). |
| Observe changes | `events.head/poll/watch`, page `workspace.subscribe` | Bounded replay journal, asynchronous and observational. Not an interception or exactly-once delivery system. |
| Publish extension context | `events.emit`, page `workspace.emit` | Native-assigned source attribution. Cannot forge `host.*` events. Directed delivery targets logical panel instances, not arbitrary command invocation IDs. |
| User preferences | `[plugins.<id>]`, command settings JSON environment, `workspace.settings()` | Plugins own semantic validation/defaults. No manifest schema or generated plugin-specific settings form. No dedicated settings-change topic yet. |
| Persist plugin data | Page `workspace.storage` scoped to pane/tab/global logical instance | Command-only plugins have no corresponding host key/value API. Trusted scripts can manage their own files; normal page scope/storage limits still apply. |
| Background activity | Managed panel service retained according to pane/tab/global scope | A global panel service starts on first panel use, not at app startup. No first-class headless service activation. A page subscription dies with its document. |
| Discover/invoke commands | `command.list`, `command.run`, native menus/shortcuts; subsequent Command-K picker | Commands contribute metadata and executable behavior, not in-process callbacks or arbitrary native UI. |

Plugins are trusted code, not a sandbox. The CLI/socket is a same-user administrative interface; the page bridge is a narrower allowlist. Trust does not imply an API exists for every native implementation detail.

## Observable is not interceptable

The current mutation path is:

```text
menu / shortcut / CLI / page command
  → host command dispatch
  → mutate a candidate Workspace
  → safety checks and native reconciliation
  → persist current model / publish workspace-change notification
```

`host.workspace.changed` is broad and currently carries `keyTabId`. It also occurs for focus changes and native tab synchronization. It does **not** identify “a split completed,” its initiator, before/after layouts, or an operation ID. A subscriber can reread state and issue another command, but that is a later operation that may race with other user/CLI changes.

Existing host topics cover workspace changes, terminal context, plugin registration, panel service state, and scoped plugin storage. Command-only job status is available through status/logs, but has no dedicated lifecycle event stream. No API runs a plugin callback before split, allows veto, rewrites arguments, or guarantees a callback after a specific mutation.

The events journal is bounded (1,024 events / 2 MiB); consumers must handle cursor loss and resynchronize. “After” must not be advertised as a durable job trigger or proof that every visual frame has rendered.

## Prioritized, scoped integration work

### 1. Improve observation before interception

The smallest broadly useful addition is **semantic post-commit events** for specific operations, emitted from shared host mutation paths. Start with pane creation/split/move/close and command-job completion, plus plugin-settings changes if live preferences are needed.

A proposed event should include an operation ID, relevant pane/tab IDs, resulting layout revision, and a small operation-specific payload (for a split: new pane, target, direction, fraction). Record the origin as native-assigned metadata; do not trust a caller-supplied provenance field. Avoid terminal text, settings secrets, or large snapshots in broadcast payloads.

Define “committed” as accepted authoritative state after successful reconciliation—not pixel presentation or power-loss durability. Preserve current journal/replay semantics. Consumers must tolerate multiple listeners, loss/resync, and follow-up commands. Add an origin/causation chain or another bounded recursion policy to prevent event-triggered macros looping indefinitely.

### 2. Add headless service lifetime only when there is a real continuous observer

A plugin reacting to every split while no panel is open needs a first-class background runtime; a 295-second command is not an appropriate substitute. Specify activation (explicit/on-start/on-event), disable/unregister behavior, bounded restarts and logs, shutdown/crash cleanup, settings updates, and how ready/failed state appears to the user. Reuse supervision, but separate service readiness from the existing mandatory HTTP-listener checks for panel servers.

### 3. Consider preflight hooks only for requirements observation cannot satisfy

Before a `beforeSplit`/veto API, decide:

- **Coverage:** native menus, shortcuts, CLI, page commands, future picker, drag/drop, and any direct native mutation paths. A command wrapper alone misses non-command UI operations.
- **Ordering:** deterministic registration order or explicit priority; whether multiple hooks see the original or rewritten arguments.
- **Deadline/failure:** small, enforced deadlines; whether timeout/crash allows or rejects the operation; user recovery/bypass and diagnostics.
- **Reentrancy:** do not hold a host mutation lock while awaiting a plugin that calls back into the same host. Reject or explicitly structure nested operations.
- **Concurrency:** freeze context, then revalidate the layout revision and targets after every await. Do not apply a stale approval to a different workspace.
- **Cancellation:** quitting, unregister, lost initiator, and native close-confirmation cancellation must release waiting work. Cancellation cannot undo an already committed effect.
- **Argument policy:** avoid unrestricted workspace rewrites. Prefer narrow, validated intents. Terminal-close consent remains host-owned.
- **Trust and availability:** trusted code still should not be able to accidentally stall every split indefinitely. Make installed interceptors visible and individually disableable.

Do not ship a broad synchronous hook bus to answer a single post-split use case. For the sidebar example, good layout primitives plus a user command may suffice; automatic behavior likely needs semantic events and a service, not veto power.

## Deliberate non-features

No arbitrary native view injection, in-process executable callbacks, declarative workflow language, global input interception, or catch-all “run code on any internal method” facility is recommended in this first expansion. Missing APIs should be added as validated, shared host operations, not access to internal debug methods.

## Evidence and confidence

Inspected `Native/{WorkspaceHost,PluginCommands,PluginInstance,PluginPane,EventControl,EventHub}.swift`, `Sources/SlateTermCore/{CommandRegistry,EventJournal,PluginRegistration}.swift`, and `docs/{plugins,events,control,automation}.md`.

Existing tests cover event cursor/routing/cancellation bounds, command supervision and routing, panel scope/storage, origin/document boundaries and external adapters (`verify-events.py`, `verify-plugin-commands.py`, `verify-plugins.py`, `verify-plugin-services.py`, `verify-extension-interop.py`). This is a source/API audit; no nonexistent hook behavior is claimed to have been tested.
