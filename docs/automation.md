# Automation

[Software updates](updates.md) documents the shared `updates.*` session, CLI/page/service controls, release notes, and explicit installation consent.

All methods use the same local JSON-RPC interface as the bundled CLI. Pass a pane explicitly when targeting a particular surface. See [the control protocol](control.md) and [plugins](plugins.md) for connection and trust boundaries.

## Machine-readable contracts

`api.describe` retains its existing capability fields and adds `contracts` (catalog
version 1). It contains every public method, all built-in commands, a shared
`plugin.*` contributed-command template, reusable `$defs`, and the schema dialect,
custom formats and `x-*` constraint vocabulary. Each descriptor identifies input
and result schemas, supported guards, errors, availability, routing, admission and
retry semantics. Private authenticated shell methods are not public capabilities.

`command.list` and `api.describe.commands` retain their existing rows and add
`contractRef`, a JSON Pointer resolved from `api.describe.contracts`. The older
row `contract` remains picker/caller-default hints, not complete invocation
validation. For `command.run`, choose the command's descriptor (or its contributed
template) for the precise result shape. Plugin arguments are opaque; reserved
host guards still undergo host validation. A successful contributed command has
its own stdout/stderr tails, unlike terminal screen observations.

The catalog covers every public method and built-in command (checked by
package tests). It includes plugin data/panel state, presence, window controls and typed web input;
the removed `storage.*` methods are not restored. `contracts.requestMetadata`
separately describes the versioned request metadata object (including display-only
actor identity), not method parameters. Malformed metadata can return `-32600`
before dispatch.

Method input schemas apply **after caller defaults, before `contextPane` normalization**.
References resolve from the catalog, not from an isolated descriptor. For a
standard JSON Schema validator, bind a fragment as follows:

```js
const catalog = description.contracts;
const schema = {
  $schema: catalog.schemaDialect,
  $defs: catalog.$defs,
  allOf: [catalog.methods["terminal.run"].input]
};
```

Custom formats and `x-*` constraints require host-specific checks; ordinary JSON
Schema validation alone is not full admission. Availability can change between
discovery and execution. Discovery remains unpaginated and subject to the 1 MiB
transport/queue limits: a sufficiently large active command list can exceed them.
Correlation IDs are not idempotency keys; never automatically replay mutations.
See [API extension progress](api-extension-progress.md) for what is verified on current main.

## Inline welcome

`slate-term welcome` reads current copy without acknowledging it. `welcome --read` persists acknowledgement; `welcome --unread` (alias `--reset`) re-enables the native welcome in future terminal sessions. Shared API, page/service parity, persistence and error details are in [Inline welcome](welcome.md). It is shell-independent native content, not part of `terminal.capture` or terminal scrollback.

## Terminals

Terminal Find and bounded history reads/exports are documented in [MVP foundations](mvp-foundations.md#terminal-findhistory-slice--implemented-selected-verification-passed). `terminal.capture` reads the active screen; use `terminal.history` for retained output. Native Find and `terminal.search` share the engine's retained-history search.

```sh
slate-term terminal send --pane p1 --text $'printf "hello\\n"\r'
slate-term terminal key --pane p1 --key ctrl+c
slate-term terminal capture --pane p1
slate-term terminal run --pane p1 --command 'printf "hello\\n"; false'
slate-term terminal wait --pane p1 --contains 'READY' --timeout-milliseconds 5000
slate-term terminal wait --pane p1 --after-sequence 12
```

RPC names are `terminal.send`, `.key`, `.capture`, `.run`, `.wait`. Routing parameters are `pane`, `tab`, `scope` (`pane`, `tab`, `global`) and optional `sessionId`. A terminal pane is addressed directly; a browser/plugin pane anchors contextual terminal resolution. A retained terminal history is independent of web-view focus. Use `context.get` to read the current terminal/session and pass `sessionId` to reject work aimed at a replaced shell.

- **send:** `text` is literal UTF-8, including control bytes. It is not a shell command, shell quoting, or bracketed paste. Existing `panes send/capture` remain available.
- **key:** `key` names a logical US-ASCII key, with optional unique `ctrl+`, `alt+`, `shift+` modifiers. Ghostty encodes press/release using the terminal's current keyboard and cursor modes. Letters, digits, `space`, `enter`, `tab`, `escape`, `backspace`, `delete`, `insert`, `home`, `end`, `pageup`, `pagedown`, arrows and `f1`–`f12` are supported. Punctuation names: `minus`, `equal`, `left-bracket`, `right-bracket`, `semicolon`, `quote`, `backslash`, `comma`, `period`, `slash`, `backtick`. For example, `shift+equal` types `+`. Case is insignificant. Chords are limited to 128 UTF-8 bytes. Command/Super shortcuts belong to workspace commands, not this input API; arbitrary Unicode uses `send`.
- **capture:** returns current screen `text` and `truncated`. Retains at most the final 128 KiB of valid UTF-8. This is not a scrollback export or isolated command stdout. The `terminal` form also returns `paneId` and `sessionId`.
- **run:** `command` is a nonempty program in the pane's shell language (zsh, bash or fish), at most 16,384 UTF-8 bytes with no NUL. `pane.inspect` and `context.get` report the pane's `shell` and `runAvailable` once its first prompt is reported. Optional `shell` (`--shell` in the CLI) states the language the command is written in; a pane running another shell refuses with `-32041` and nothing is submitted. Requires authenticated shell integration and an idle prompt. A private line-editor widget checks the actual editing buffer and continuation state before claiming the queued command; an unfinished draft is refused without submitting it. zsh binds a session-specific key in the main/emacs/viins/vicmd maps; bash 4.4+ binds it in the emacs, vi-insert and vi-command keymaps and claims only at an empty primary prompt, never at a continuation prompt, inside `read -e`, or when its prompt marks are missing or `promptvars` is off; fish 3.1+ binds a private-use character in its default, insert and visual modes, checks the whole multi-line buffer and claims only at a command prompt. bash 3.2–4.3, including Apple's `/bin/bash`, report state but refuse runs (`runAvailable: false`). Replacing those bindings or removing the integration can make a run time out rather than guess. Shell reports travel on separate connections and may arrive out of order; a run completes on the prompt numbered directly after its own running report. If a later command's prompt arrives first, the run completes with `exitCode: null` rather than another command's status. Completion requires its unique preexec marker followed by a later prompt report, never a guessed output string or process name. Returns `paneId`, `sessionId`, `commandId`, `exitCode`, `text`, `truncated`. A nonzero command status is a completed RPC result; inspect `exitCode`, not the CLI's transport exit status. Text is the screen when completion is reported, not a promise that all output has rendered or a per-command stream. The eval wrapper can appear in shell history and terminal echo. Commands that replace/exit the interactive shell cannot complete through its next prompt.
- **wait:** with `contains`, waits for literal current-screen text (1–4096 UTF-8 bytes). This may match existing output: choose a unique marker when freshness matters. Without it, waits for an authenticated prompt; unknown shell state is rejected. Optional `afterSequence` requires a newer prompt and is incompatible with `contains`. Returns `matched`, pane/session IDs, and available report sequence/exit status.

Run/wait deadlines default to 30,000 milliseconds; range 1–295,000. At most one run per pane, 32 active runs plus startup reservations, 32 operation waiters and 32 screen/prompt waiters per app. Targets and session identities are frozen. Timeout or disconnect **stops waiting, not the user's command or operation tracking**. Explicitly send `ctrl+c` if interruption is intended; the process may handle or ignore it. Dedicated automation terminals avoid competing human/extension input; raw `send` deliberately makes no prompt-safety guarantee.

### Reconnectable operation handles

Use `terminal.start` for long-running commands. It has the same command/target safety checks as `run`, including the optional `shell` check and the `runAvailable` refusal, but returns `{commandId,paneId,sessionId}` after adopting the work, without waiting for completion. After adoption the terminal session—not the caller, connection, or plugin document—owns it. A delivery failure after adoption is retained in its status. Do not retry a start after an ambiguous transport error; inspect `terminal.operations` first.

```sh
slate-term terminal start --pane p1 --command 'make test'
slate-term terminal operations
slate-term terminal operationStatus --command-id UUID
slate-term terminal operationWait --command-id UUID --timeout-milliseconds 295000
slate-term terminal operationResult --command-id UUID
```

These spellings map directly to RPC methods. Handle reads accept `commandId`, not a live pane/tab/session or inherited context. Only `operationWait` also accepts `timeoutMilliseconds`; `operations` takes no parameters and lists retained status metadata without command text or output. `expectedInstanceId` is the only supported identity guard for these reads. A closed or replaced pane does not prevent inspecting its retained outcome.

Status includes IDs, `state`, optional `exitCode` and optional `failure`. States are `awaitingInput`, `submitted`, `running`, `capturing`, `completed`, `rejected`, `interrupted`, `trackingLost`, and `sessionLost`. `interrupted` means another shell command displaced tracking, not that this API sent an interrupt. `trackingLost` means delivery failed after the shell had claimed the line; it does not claim whether execution succeeded. Reports pair by sequence exactly as for `run`: a prompt that overtakes its running report is held, and only the prompt numbered running + 1 supplies `exitCode`. Failures are `editingBufferNotEmpty`, `submissionFailed`, `otherCommand` and `sessionLost`. Results and completed waits are repeatable and have the same bounded screen-result shape as `run`; this is not isolated stdout/stderr or tracking of background jobs after the shell returns to its prompt.

At most 128 records are retained in memory. Finished records expire 15 minutes after their final transition, or sooner when capacity pressure evicts the oldest finished record. Unfinished records are never silently evicted. Nothing survives an app restart or enters restoration/transcript files. Unknown/expired/evicted handles return `-32051`; pending or failed results return `-32042` (inspect status); wait timeout returns `-32024`; invalid parameters return `-32602`. A wait cancellation never forgets the operation or sends terminal input. Native input/interrupt controls are unchanged; these handle-based queries have no parameterless menu action.

Discovery is under `api.describe.terminalOperations`. On the branch, selected native/adapter, three-client and integrated VM checks passed; the port onto current main has host checks only until its VM gates run; full-suite and manual release certification are not claimed. See [MVP evidence](mvp-foundations.md).

Plugin equivalents:

```js
await workspace.terminal.key('ctrl+c', { pane: 'p1', sessionId });
const result = await workspace.terminal.run('printf "hello\\n"', {}, { signal });
await workspace.terminal.wait({ contains: 'READY', timeoutMilliseconds: 5000 }, { signal });
const handle = await workspace.terminal.start('make test', { pane: 'p1' });
await workspace.terminal.operationWait({ commandId: handle.commandId }, { signal });
const retained = await workspace.terminal.operationResult({ commandId: handle.commandId });
```

A plugin defaults to its declared context. Explicit terminal IDs override its terminal history. Aborting or replacing the plugin document releases its waits; an already adopted operation remains claimable by its authenticated shell and continues to be tracked. Tool-specific protocols and enriched context, including tmux integration, belong in extensions.

## Shared web panes

[First-pass web input](api-parity-first-pass.md#shared-web-input) adds guarded `web.focus`, `web.key`, `web.check`, and `web.setValue`, including synthetic-key limitations and typed-value validation.

`api.describe.webAutomation` advertises structured automation for browser and registered-plugin panes. The canonical RPCs are `web.get`, `.snapshot`, `.click`, `.fill`, `.select`, `.scroll`, `.wait`, and `.screenshot`, shared by all trusted clients. Socket requests require an explicit pane; the CLI accepts `--pane` or a validated launching pane, not `--tab`/`--active` alone. These parameterized operations are not menu/picker actions.

| Capability | Native menu / picker / shortcut | CLI / socket | Registered page |
| --- | --- | --- | --- |
| Structured `web` reads and DOM actions | No parameterless action | Yes | Yes, self or explicit pane |
| `web.screenshot` | No parameterless action | Yes, absolute output path | Yes, absolute output path |
| Direct `browser.navigate` / `browser.eval` RPCs | Navigation UI; no eval UI | Browser-only compatibility API | Same browser-only API |

```sh
slate-term web get --pane p2
slate-term web snapshot --pane p2
slate-term web fill --pane p2 --selector '#name' --text 'Hello' \
  --expected-view-id VIEW_ID --expected-document-id DOCUMENT_ID
slate-term web click --pane p2 --ref SNAPSHOT_REF
slate-term web screenshot --pane p2 --path /absolute/path/page.png
```

`pane.inspect` and `web.get` expose the same automation `{viewId, documentId}`. A document ID is null while unavailable; it is initialized from native document lifecycle independently of page bridge calls and is **not** a bridge credential/correlation ID. `web.get` also reports readiness, renderability, `screenshotReady`, bounded URL/title, sampling time and pending work. `screenshotReady` is sampled capture eligibility, not visibility or a reservation; it can be true while `renderable` and `pane.inspect.visible` are false. Pane content-operation discovery uses the canonical web names; existing `browser.*` methods remain available separately.

Selector-based click/fill/select and scroll without a ref require both `expectedViewId` and `expectedDocumentId`. A snapshot ref already binds its view and document; optional explicit guards must agree. Missing/partial/malformed guards fail closed. Refs are opaque: do not parse or construct them. Snapshot/wait reads may optionally carry guards. Cross-view refs, stale documents and replaced panes fail instead of retargeting. Read inspection again after a conflict; do not replay a mutation automatically.

Registered pages use the same implementation:

```js
const page = await workspace.web.get(); // self by default
await workspace.web.fill({selector: '#name', text: 'Hello',
  expectedViewId: page.viewId, expectedDocumentId: page.documentId});
const other = await workspace.web.snapshot({pane: 'p2'}); // explicit cross-pane target
```

Every helper accepts final `{signal, cause}` options. Cross-pane access is intentional for trusted registered controllers, not a new pane sandbox. Ordinary pages/subframes receive no bridge. Automation runs in a separate private content world; plugin origin restrictions, scoped data stores and bridge privileges stay in the plugin adapter. Browser navigation/address controls and persistent/private stores remain browser-owned.

`web.get` can report an unavailable or nonrenderable target. DOM operations (including `web.snapshot` and `web.wait`) still require a ready, visible rendered pane and never reveal it implicitly. `web.screenshot` also accepts a ready browser/registered-plugin pane in an **inactive native tab** when its web view remains attached to its owning window with settled layout and nonzero bounds. It captures the current web viewport without selecting a tab, changing focus, reloading or reparenting the view. On-screen visibility and geometry remain unchanged/unavailable for inactive panes. Discovery advertises `screenshotInactiveTabs`, `screenshotRequiresAttachedLayout`, `screenshotViewportOnly` and `domRequiresVisiblePane`.

Zoom-detached, unready, invalid/pending-layout, minimized and ordered-out window-group targets remain unavailable (`-32051`). Bounds/layout changes during capture fail rather than write a mismatched viewport (`-32050` when still otherwise eligible). Caller/target/document checks run before submission and again before writing output. Navigation, cached-history restoration, process exit and replacement invalidate pending work/refs; zoom/hiding alone is not document retirement. Screenshot output requires an explicit absolute local path for every client. Hidden content can have throttled timers/animation; capture does not make the document behave as visible. This is not full-page or universal native/terminal capture. There is no `web.eval` or canonical plugin navigation API; `browser.eval/navigate` remain browser-specific, available to CLI, registered-page and service clients.

Limits below apply to both adapters. Each view admits at most 32 logical DOM actions, including sleeping waits, and 32 outstanding platform submissions. Cancellation/timeout promptly releases callers but cannot cancel already-submitted JavaScript or snapshots: those submissions retain capacity until their callbacks or definitive process/view teardown. `pendingActions`, `pendingOperations` (caller continuations) and `pendingSubmissions` distinguish these lifetimes. An overload or uncertain response is not permission to retry a click.

## Browser profiles and website data

Choose **Browser** (`browser`) for one app-wide persistent profile, shared across panes/windows/workspaces and app restarts. Choose **Private Browser** (`private-browser`) for a fresh, isolated temporary store per pane. Both use the same address controls and automation APIs; neither has a plugin bridge. Plugins retain their separate stores. Trusted automation can act on signed-in Browser pages.

`browser.get` adds `type` and `persistent`. Workspace snapshots and saved layouts preserve the chosen pane kind, not a browser's open document/back-forward history. Saved-layout URLs can start either kind; opening a recipe does not copy a profile. Persistent website data is independent of `layout.restore_workspace`.

| Capability | Native menu / command bar / configurable shortcut | CLI / socket / registered page / service |
| --- | --- | --- |
| Clear Browser Data… (`browser.clearData`) | Always available; native warning, Cancel by default | No dialog; no payload arguments, clears only the persistent profile |
| Clear This Site’s Data… (`browser.clearSiteData`) | Available on an HTTP(S) browser page, including Private Browser; captures the pane/URL before a native warning | Explicit `url` required; browser `pane` required (or a trusted caller's captured pane default) |
| List stored sites (`browser.listData`) | Browser Settings lists the persistent profile's stored sites without requiring open panes | No arguments; returns `{storage:"persistent",sites:[string]}` |
| Remove a stored site (`browser.removeSiteData`) | Select a stored site in Browser Settings, then confirm removal | Explicit `site` from the stored-site list; no pane required |

```sh
slate-term panes type --pane p2 --type private-browser --force
slate-term browser clear-data
slate-term browser list-data
slate-term browser remove-site-data --site example.com
slate-term browser clear-site-data --pane p2 --url https://example.com/path
slate-term command run browser.clearSiteData --pane p2 --params '{"url":"https://example.com"}'
```

Canonical RPCs are `browser.clearData {}` and `browser.clearSiteData {pane,url}`. The same IDs work through `command.run`. Registered pages may use `workspace.browser.clearData({})` / `clearSiteData({pane,url})` or `workspace.call`. API invocation never opens a confirmation dialog, including through `command.run`. Unknown payload fields, invalid URLs, unsupported guards and stale targets fail closed; there is no `force` or implicit current-page URL in API calls. URLs must be absolute HTTP(S), without credentials. Optional app/workspace/layout guards use the common contract; DOM identity/session guards are not a website-store identity.

`browser.listData {}` returns sorted, unique WebKit record display names from the app-wide persistent profile. `browser.removeSiteData {site}` removes records whose display name exactly matches `site`; it never normalizes the name or infers an open pane. Use the returned name unchanged. It must be nonempty, contain no control characters, and fit within 16,384 UTF-8 bytes. Both methods ignore caller pane defaults and reject explicit pane/tab targets. They exclude private and plugin stores. Registered clients use `workspace.browser.listData({})` and `workspace.browser.removeSiteData({site})`. Listing is a read; removal is a noninteractive mutation. Neither is a command-picker action: listing is read-only, and removal requires a selected name. Private site clearing remains available through the existing pane-specific command.

Replies are `{cleared:true, scope:"all"|"site", storage:"persistent"|"private", host:string|null}`. Stored-site removal returns `scope:"site"`, `storage:"persistent"` and the exact supplied name in `host`. Site clearing uses WebKit's public-suffix-list domain-grouped website records: it can remove the parent site's data and other subdomains, across HTTP/HTTPS and ports, **not just one exact origin or path**. Unrelated domain groups and other stores are preserved. Clearing a site through any Browser pane affects the shared profile; clearing through a Private Browser affects only that pane.

These operations remove WebKit-managed cookies, caches and saved website storage. They do not close/reload pages, clear back/forward lists, erase live JavaScript state, or promise to reset every in-memory login/session. Open pages may recreate data; close them first when necessary. Only one clear per store is admitted at a time. Cancellation before submission prevents deletion; after WebKit accepts removal, disconnect/cancellation cannot roll it back. Discovery is under `api.describe.browserData`. `-32602` denotes invalid requests, `-32022` a closed/replaced pane and `-32020` a clear already in progress. No automatic mutation retries.

## Browser compatibility API

```sh
slate-term browser navigate --pane p2 --url http://127.0.0.1:8080/
slate-term browser navigate --pane p2 --url '/absolute/path/local page.html'
slate-term browser navigate --pane p2 --url file:///absolute/path/photo.png
slate-term browser snapshot --pane p2 --max-elements 128
slate-term browser fill --pane p2 --selector '#name' --text '日本語'
slate-term browser click --pane p2 --ref SNAPSHOT_REF
slate-term browser select --pane p2 --selector '#choice' --value first
slate-term browser scroll --pane p2 --y 600
slate-term browser wait --pane p2 --selector '#result' --state visible --timeout-milliseconds 5000
slate-term browser screenshot --pane p2 --path /absolute/path/page.png
```

`browser.navigate` accepts HTTP(S), `about:blank`, local `file:` URLs (empty host or `localhost`), absolute paths and `~/…` paths. Native address entry and saved-layout starting locations use the same local-file rules in Browser and Private Browser; the address bar still searches ordinary text. `api.describe.browserNavigation` advertises this support to all trusted clients, including registered pages/services using the existing `workspace.browser.navigate` API. There is no new parameterless picker action: use **Focus Address Bar** (⌘L).

Local HTML can load relative scripts, styles, images and media from its containing directory and descendants. Standalone images, videos and other formats display when supported by the system WebKit (for example PNG/JPEG/SVG and H.264 MP4); unsupported formats/codecs are not converted. Local HTML executes JavaScript: open only files you trust. Read access is scoped to the containing directory (or just the file for a file directly under `/`), not the filesystem root; WebKit's normal origin restrictions remain enabled. Directories are not browsable. Missing/unreadable files fail normally. Local pages never receive a plugin bridge, and plugin-origin rules are unchanged.

RPC names match CLI actions (`browser.snapshot`, etc.). These legacy browser-only adapters retain their existing admission semantics; use canonical `web.*` for the shared browser/plugin eligibility and identity contract. Element actions require exactly one unique CSS `selector` or snapshot `ref`. Ambiguous selectors fail instead of choosing the first match. Scroll's target is optional; omission scrolls the window. Distances are CSS pixels, bounded to ±10 million per axis.

Snapshots return URL/title, document identity, viewport/scroll geometry, visible text, interactive element metadata and `truncated`. Elements include reference, tag/approximate role, name, enabled state, rectangle and viewport intersection, plus relevant value/checked/expanded state. Password values are omitted. This is a bounded DOM summary, **not the platform accessibility tree**. Defaults: 128 elements (configurable 1–256), 4,000 visited elements, 2,048 visited text nodes, 16,384 UTF-16 text units and a 350,000-byte element budget. Names/values are clipped to 256/512 UTF-16 units. Truncation is reported. At most 2,048 weak element references are retained; refresh the snapshot if one expires.

Element actions (click, fill, select, check, setValue, focus, key, and scroll with a target) also return the acted-on element's `rect` (`x`, `y`, `width`, `height` in CSS pixels, viewport-relative after scrolling it into view) and the `viewport` size. A matched visible `wait` returns `rect` and `viewport` too. Slate uses them to frame the element for [agent presence](presence.md).

References are view- and document-scoped. Navigation, reload, cached-history restoration and pane replacement do not revive old references. A detached element cannot be mutated through its old reference. Helpers live in a retained private WebKit content world, not in the page's JavaScript namespace. Ordinary browser pages never receive `workspace` or the plugin bridge.

Click/fill/select reject hidden, disabled, inert or covered targets and scroll them into view. Fill supports text-like inputs, textareas and contenteditable elements; readonly fields are rejected. Input and change events are dispatched. Select validates every requested value before changing selection; values must uniquely identify enabled options. Up to 64 values of 4,096 UTF-8 bytes each; fill text is limited to 65,536 UTF-8 bytes.

Wait states: `attached`, `detached`, `visible` (default), `hidden`. Timeout is 0–10,000 milliseconds; zero performs one probe, not repeated waiting. Visibility means rendered, not necessarily inside the viewport. Navigation and pane closure invalidate pending operations; disconnect cancels waiting. Navigation has a 15-second deadline, evaluation/screenshot/actions generally 10 seconds. At most 32 active WebKit operations per pane; serialized evaluation results are capped at 900,000 bytes.

### WebKit limits

- Main-document light DOM only: no frame traversal or shadow-root selector language.
- DOM activation/events are synthetic, not trusted hardware input. User-gesture-gated APIs and anti-automation pages may reject them.
- Cancellation does not roll back an action or forcibly interrupt JavaScript already submitted to WebKit.
- Browser shares one persistent website store; Private Browser has a per-pane ephemeral store. Neither restores its live document/back-forward history from workspace JSON.
- HTTP(S), `about:blank` and explicit local files only; no URL credentials, remote file hosts, directory browser, download manager, remote debugging port, CDP compatibility, or privileged plugin API.
- `browser.eval --script ...` remains available for explicit page-world JavaScript. It must return a JSON-representable value; screenshots capture the web-view viewport, not an entire scrolling document.
