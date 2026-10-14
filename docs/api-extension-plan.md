# API extension plan: composable commands, agent context, and plugin automation

Status: **reviewed proposal, revision 3; no implementation authorized by this document**. Baseline: checkpoint `0d12f34`, plus inspection of current production sources. All new names, flags and response fields below are proposed. Review and approve the contracts before implementation. Unrelated saved-layout mockup work is not part of this plan.

## 1. What already exists — do not rebuild it

| Surface | Current capability | Actual gap |
| --- | --- | --- |
| Command invocation | `slate-term command list/run`; page `workspace.command(id, params)` | The registry does not represent every UI operation. Metadata lacks parameter schemas and consistent availability/discovery. Generic CLI `command run` currently accepts routing/force, not arbitrary action parameters. |
| Terminal identity | Shells receive `SLATE_TERM_PANE_ID`, `SLATE_TERM_TAB_ID`, `SLATE_TERM_SOCKET`, `SLATE_TERM_CLI`; CLI routing inherits pane/tab | Terminal launch does not currently export the app instance or terminal session ID. Environment is a launch snapshot, not live topology. |
| Executable plugin context | Commands receive app/plugin/invocation-related IDs, captured pane/tab, settings and CLI/socket environment | `SLATE_TERM_PLUGIN_INSTANCE` means a command run ID for commands but a logical plugin instance for panel services. Make these distinctions explicit without breaking existing variables. |
| Managed panel service context | Plugin ID, logical instance, app instance, scope; pane/tab variables where the scope has a unique owner | Tab/global services can back multiple views. They must not invent one current pane/view. |
| Page plugin identity | `workspace.plugin` already exposes plugin `id`, `instanceId`, `scope`, `viewId`, `paneId`; `workspace.context()` gets live context | Context distinguishes focused pane/active terminal, but does not present a uniform caller-versus-target identity or live neighbor summary. |
| Workspace inspection | `workspace.get`, `layout.get`, `tabs.list`, `panes.list`, `context.get`; registered pages can read workspace/layout through the allowlist | Topology is JSON with stable pane/tab/group IDs, but no typed workspace CLI, revisioned inspection envelope, native geometry or unified per-pane metadata/content discovery. |
| Terminal contents | Bounded `terminal.capture`, prompt-aware `run/wait`, input and session guards | Capture is the current screen, not full scrollback or isolated stdout. Preserve that distinction. |
| Browser interaction | `browser.get/navigate/snapshot/click/fill/select/scroll/wait/eval/screenshot` on CLI/socket | Host dispatch requires `BrowserPane`; rendered plugin panes lack a production equivalent. `PluginPane.evaluateForTesting` is not an API. |
| Appearance/settings | Native Settings; TOML file, `config.get/reload/validate` | No `config set/patch` or appearance command. Editing TOML plus reload works today; no direct page API for application settings. |
| Events | Bounded replay journal and native source attribution; broad workspace/context/plugin topics | No semantic operation events, command-job completion events, revisioned results, or interception hooks. |
| Plugin controls | Command-backed `headerButtons`, application-local shortcuts, page storage/settings | No always-running headless service lifecycle or command-only host storage API. |

Evidence: `Native/WorkspaceHost.swift` (`reconcile`, `context`, `callAsync`, `pluginCall`, `persistWorkspace`); `Native/{BrowserPane,BrowserAutomation,PluginPane,PluginInstance,PluginCommands}.swift`; `Sources/SlateTermCLI/SlateTermCLI.swift` (`Connection`, `Target`, `Commands`, `ConfigCommand`); `Sources/SlateTermCore/{CommandRegistry,Workspace}.swift`. Existing contracts are documented in [control](control.md), [automation](automation.md), [events](events.md), [configuration](configuration.md), and [plugins](plugins.md).

## 2. Architectural rules

1. **One operation implementation, several adapters.** Registry commands, typed CLI wrappers, approved bridge calls and native controls call shared host operations. Native drag/divider gestures also use the same commit/event boundary; do not expose `debug.*` or reimplement mutations in the CLI.
2. **Separate commands from reads and resources.** No-argument actions belong in menus/shortcuts/⌘K. Reads, parameterized mutations and resource import use typed APIs/CLI. Parameterized commands stay out of ⌘K until a proper native argument flow exists; fixed aliases such as `appearance.dark` remain discoverable.
3. **Discover capabilities rather than guess.** Add `api.describe` and richer command metadata: version, parameter/result schemas, target kinds, surface exposure, availability and reason, side-effect category, and retry semantics. Do not equate discovery with a security sandbox.
4. **Enforce exposure at dispatch.** The page bridge currently forwards `command.run`; new administrative commands must be denied there even if their direct RPC name is not allowlisted. Filter discovery and enforce command-level policy on invocation, not just UI visibility. Existing supported bridge commands retain their behavior.
5. **Capture identity, then revalidate.** Freeze explicit targets before asynchronous work/confirmation. Reject closed/replaced targets after suspension; never fall back to whichever pane is now focused. Layout changes, terminal sessions, WebKit views and documents have separate lifetimes.
6. **Bound every response and wait.** Keep current transport/event/WebKit limits unless explicitly revised and tested. Return truncation, unsupported/not-visible states and typed conflicts, not silent partial success. Never automatically retry mutations after an uncertain response.
7. **No generic transaction/workflow engine.** Atomicity means one validated host operation commits its authoritative model or does not. It does not undo terminal input, shell startup side effects, web clicks or arbitrary plugin code.

### Consistency and identity contracts

- Phase 1 must introduce revision tracking across **all existing authoritative mutation paths**, including legacy commands, native focus/type/title changes, divider/pane gestures and tab-group adoption, before exposing guarded inspection. Audit every model mutation/assignment and connect it to one host revision tracker; Phase 3 adds semantic operation intents/events on top, not the first reliable revision bookkeeping.
- Add an app-epoch-qualified workspace revision and per-tab layout revisions in a **new inspection envelope**, not by changing the legacy `layout.get` tree shape. Revisions are runtime tokens; restart invalidates them. A layout revision changes for topology, fractions, type/visibility changes, not focus or terminal output. A workspace revision additionally tracks grouping, focus and manual titles. No-op operations do not increment revisions.
- Initially identify a divider by `(tabId, splitPath, expectedLayoutRevision)`. A path without its matching revision is unsafe and rejected by new resize APIs. Stable split IDs can be a later storage/model migration if needed; do not implement both schemes now.
- New structural mutations require the expected affected revision(s), including source and destination groups/tabs where relevant. Native UI captures them at gesture/operation start. Existing commands remain compatible; optional guards may be added, and new atomic variants provide strict contracts.
- Return an operation ID, resulting revisions, affected IDs and explicit outcome. An operation ID is correlation, **not** an idempotency key. On disconnect, an operation may already have committed; inspect authoritative state before retrying.
- Revision validation, authoritative mutation and semantic event append occur in one non-suspending host commit section. Resource preparation may suspend, so repeat validation afterward. Model atomicity does not imply simultaneous rendered pixels, external process rollback or durable autosave.
- Preserve current best-effort workspace autosave. Report persistence failure separately from an accepted in-memory mutation; do not roll back a committed operation merely because autosave fails. Events describe authoritative in-memory commit, not disk durability.

## 3. Agent context, environment and inspection

### Environment contract

Keep `PANE` in canonical API/environment names; do not add redundant `PANEL_ID` aliases.

| Variable | Recommendation |
| --- | --- |
| `SLATE_TERM_SOCKET`, `SLATE_TERM_CLI` | Preserve. Local connection and executable discovery only; no global socket that guesses an app instance. |
| `SLATE_TERM_PANE_ID` | Preserve as stable launching/target slot ID. Explicit CLI target overrides it. A pane ID alone is not enough to identify an app or a replacement terminal session. |
| `SLATE_TERM_TAB_ID` | Preserve for compatibility, documented as a launch/captured hint. Resolve a live pane's current tab from the host rather than trusting this after movement. |
| `SLATE_TERM_INSTANCE_ID` | Also export to terminal shells. Preserve the existing app-instance meaning in command/service environments. CLI validates it when using inherited connection context. |
| `SLATE_TERM_SESSION_ID` | Add for terminal shells, using the existing native terminal session UUID, never the shell authentication token. New guarded CLI operations use it to reject successor sessions. |
| `SLATE_TERM_INVOCATION_ID` | Add for executable commands. Keep legacy `SLATE_TERM_PLUGIN_INSTANCE` behavior during a documented compatibility period; never silently change its meaning. |
| `SLATE_TERM_PLUGIN_ID`, `SLATE_TERM_PLUGIN_INSTANCE`, `SLATE_TERM_PLUGIN_SCOPE` | Preserve where applicable. Logical panel instance, view identity and command invocation identity remain distinct. |
| `SLATE_TERM_COMMAND_ID`, `SLATE_TERM_COMMAND_PARAMS`, `SLATE_TERM_PLUGIN_SETTINGS` | Preserve existing command launch snapshots. Settings are potentially sensitive; never echo the complete environment in inspection/events. |
| Geometry, neighbors, focused pane, current group and layout revision | **Do not export.** They change while a process runs. Obtain them through live inspection. |

No fake empty IDs for global services or ownerless commands. Omit inapplicable variables. Processes cannot update their ancestors' environment; moving a live pane must not require restarting its shell. Detached/tmux/background processes may inherit stale context; stale identity must produce an explicit error, not fall back to focus. No automatic environment propagation into SSH/remote machines.

Routing policy for the new CLI: explicit pane/tab > inherited pane > inherited tab > active workspace where the command permits it. A pane resolves its current tab; an explicitly supplied mismatched pane/tab is an error, while an inherited stale tab hint must not override a validated pane. An explicit different `--socket` must not reuse the old app's inherited identities: require explicit target or an intentional `--active` for target-dependent work in that case. This is a documented CLI safety change; old callers without identity guards remain supported by the server, not silently reinterpreted.

Host-owned identity variables must override or remove poisoned inherited `SLATE_TERM_*` values for every runtime kind, not just executable plugins. Do not forward a previous app/plugin's identities into a new terminal.

#### CLI target/session guard matrix

`--session-id` explicitly guards the **resolved target terminal** and takes precedence over an inherited session. `--active` is an intentional current-focus target and is mutually exclusive with explicit pane/tab targets. It drops inherited pane/tab/session routing, not the app-instance check for an inherited connection.

| Request on the inherited app connection | Target resolution | Session/anchor behavior |
| --- | --- | --- |
| No routing override, inherited terminal `p1/s1` | Live pane p1, deriving its current tab | Carry s1 for terminal operations; reject replacement/nonterminal p1 rather than resolving a different terminal. Targeted workspace mutations also carry an expected launching-anchor precondition for p1/s1. |
| Explicit `--pane p1` equal to inherited p1 | Explicit p1 | Retain s1 unless an explicit session guard overrides it; spelling the same pane explicitly must not accidentally remove protection. |
| Explicit `--pane p2` different from inherited p1 | Explicit p2 | Do **not** attach s1. Use explicit `--session-id s2` if supplied; otherwise preserve existing explicit-target behavior, documenting that delayed terminal work should supply its own guard. |
| Explicit `--tab t2`, no explicit pane | Resolve the requested tab's applicable focused/active-terminal target | Drop inherited pane/session; an explicit session guard checks the terminal actually resolved in t2. |
| Explicit contextual `--scope tab`, no explicit pane | Explicit tab first; otherwise current tab resolved from a supplied inherited pane-slot hint; otherwise a validated inherited tab alone (including tab-scoped services); then that tab's active terminal | Do not attach the launching session to another terminal. A supplied but stale pane anchor fails: never fall back to its old tab hint. A live inherited tab is sufficient when no pane anchor exists. With neither anchor, use the documented active-context fallback only for genuinely unanchored callers; never turn failed anchor validation into fallback. Explicit session guard applies to the resolved terminal. |
| Explicit `--scope global` or `--active`, without explicit pane | Active workspace at request admission | Drop inherited pane/tab/session; retain same-app check. Explicit session guard, if any, checks the selected terminal. Explicit pane targeting retains its established precedence over scope. |
| Explicit different socket while inherited app context exists | Require explicit pane/tab or intentional `--active` for target-dependent work | Drop all identities inherited from the old connection, including s1. Validate any explicitly supplied app/session guard against the new connection. Global unanchored reads may proceed without a pane. |
| No inherited identity (external client or app-level service) | Explicit routing or documented active-context fallback | Do not invent a caller/session. Use explicit guards returned by inspection for delayed operations. |

Phase 1 applies these optional server preconditions and new CLI inheritance rules to **existing** terminal send/key/capture/run/wait and pane send/capture wrappers, and to `command.run`/typed workspace mutations that inherit a launching terminal as their target anchor. Unanchored global reads are not forced to validate a dead launching pane. Validate an inherited anchor and resolve the target in the same host admission step, then revalidate after suspension; this is a precondition, not provenance authentication. A nonterminal page caller instead has its existing host-bound view/document lifetime. Never translate a terminal session guard into a WebKit document guard.

Add optional explicit app-instance and anchor guards to the new CLI contract. Negotiate identity-guard support through `api.describe`: if an old server cannot enforce a requested guard, fail with a compatibility error rather than sending a field it will silently ignore. Existing old clients remain supported. Test the matrix with poisoned environment values, reused pane IDs after app restart, live pane moves, replaced terminals, and explicit targeting of siblings.

In `--json` mode, failures should produce one bounded JSON error object on stderr and a nonzero exit status, with stable code, message, optional operation ID and outcome/conflict data; stdout remains reserved for successful JSON results. Do not mix ArgumentParser usage prose into machine errors. Preserve human stderr behavior without `--json`. A transport failure reports outcome unknown, not “not executed.”

Shell private variables such as `SLATE_TERM_CONTEXT_TOKEN` and `SLATE_TERM_RUN_KEY` remain integration internals, excluded from inspection, forwarding to plugin commands, logs and examples. Same-user socket access remains administrative; environment fields describe routing, not authenticated proof of a process's provenance.

### Public inspection surfaces

- `slate-term workspace get` wraps existing `workspace.get` unchanged. Add `workspace snapshot` / `workspace.snapshot` for an envelope containing app epoch, workspace/layout revisions, event cursor, groups, tabs and panes. Obtain authoritative metadata and cursor in one host turn. Geometry is explicitly a sampled native projection, not part of the model transaction.
- `slate-term context inspect --self` / `context.inspect` distinguishes **caller anchor**, requested target, focused pane, and active terminal. Return named `appInstanceId`, `paneId`, `tabId`, `groupId`, `sessionId`, `pluginInstanceId`, `viewId` and `invocationId` only when applicable, with an identity-source indicator. Socket callers can supply validated routing IDs but cannot manufacture host-authenticated plugin provenance. Bridge caller identity is bound to the actual view; an explicit target never changes who the caller is.
- `slate-term panes inspect --pane pN` / `pane.inspect`: type, manual/effective title, current tab/group, visibility/readiness, available content operations, current session/view/document identity and geometry availability. Default workspace snapshots contain IDs/types/titles/status, **not bulk terminal text, page DOM, settings or process environments**. Per-pane terminal context may include cwd/running state when explicitly requested; unknown remains unknown.
- Include pane rectangles in **tab-content points, top-left origin**, an explicit coordinate space and rendered-layout revision/availability. Neighbor lists use the same geometric ranking as native directional focus, with deterministic ties; disclose hidden/zoomed panes rather than pretending they occupy rendered space. If native projection is pending or unavailable, return null geometry/status, not fabricated zero rectangles.
- Content is opt-in and per pane: existing bounded terminal capture; shared web snapshot for browser/plugin views. Each result includes identities, sample time and truncation. Topology plus multiple content reads is **not an atomic screenshot of the world**; include expected identities and reject replacements between calls. Bound discovery output within transport limits and paginate any potentially unbounded resource list. Pagination uses an opaque, bounded cursor bound to app epoch, query/scope, workspace revision and stable ordering position. Every page must match that revision or fail with a restart-required conflict; do not retain unbounded server-side snapshots or concatenate different topology versions. The first page's event cursor is carried through enumeration so consumers subscribe from that boundary; journal expiry still requires resnapshot. Live status/geometry/content fields carry per-page sample times and are not frozen by the topology revision.
- Add ergonomic `workspace.inspect()`, `workspace.self()` and `workspace.panes.inspect(...)` bridge wrappers over the same host data. Preserve existing `workspace.plugin` and `workspace.context()` results. Live self context resolves tab/group after moves; a tab/global backend with several views must choose a view/pane rather than claiming a single location.

**Agent walkthrough (proposed):** inherit pane/app/session IDs → `context inspect --self` resolves current location → `workspace snapshot` identifies surrounding pane IDs and revisions → `panes inspect` discovers each pane's capabilities → explicitly capture a terminal or snapshot a web pane → interact using the returned session/view/document guards. An agent can do the same through an authenticated plugin page without inspecting private debug state.

## 4. Reuse browser automation for rendered plugin panels

Do not make plugin panels masquerade as BrowserPane, and do not copy the implementation.

1. Extract a compositional `WebPaneAutomation` helper from `BrowserPane`: the private content-world DOM helpers in `BrowserAutomation`, action validation (`BrowserAction`), result bounds, pending-operation registry, timeouts/cancellation, document/ref invalidation and visible-view screenshots. Both pane controllers own a helper for their own WKWebView.
2. Keep **navigation/UI/data-store ownership in the pane adapters**. BrowserPane retains its address bar, allowed HTTP(S)/about navigation and ephemeral per-pane store. PluginPane retains registered-origin restrictions, managed-service readiness, scoped stores, bridge credentials, document lifecycle and external-navigation blocking. Do not merge their WKNavigationDelegates or privilege policies into a permissive base class.
3. Introduce canonical `web.get/snapshot/click/fill/select/scroll/wait/screenshot` for an explicit web-capable pane. Existing `browser.*` routes continue to work and remain browser-specific compatibility adapters over the helper. No forced rename for existing scripts.
4. Define a single public **automation identity** `{viewId, documentId}` owned by the shared helper, used consistently by `pane.inspect`, `web.get`, web snapshots and new action preconditions. Its opaque document ID identifies the automation helper's current document epoch/native generation; it is **not** `PluginPane`'s bridge-correlation document ID. Initialize automation identity for a ready document independently of whether any page bridge call has occurred. Return `documentId: null` plus an explicit not-ready state while it is unavailable; do not substitute a bridge token or claim readiness. Ref identity is bound to both view and automation document. New selector-based mutating actions **require** expected automation identity from inspection; ref-based actions carry/check equivalent guards in the ref envelope. Existing `browser.*` keeps its compatibility behavior. Reject cross-view refs, stale documents, missing/ambiguous/covered/disabled elements, unavailable services and replaced panes. Navigation, BFCache restoration, process termination and type replacement invalidate pending work and the public automation identity.
5. Expose structured `web.get/snapshot/click/fill/select/scroll/wait` explicitly to registered plugin pages through `workspace.web`, using the existing authenticated main-frame bridge. Self is the default; other panes require explicit IDs. Registered plugins are already trusted workspace controllers: explicitly review this additional cross-pane capability rather than implying pane scope is a new security sandbox. Existing read/mutation target rules remain explicit and consistent across tabs.
6. Ordinary browser pages and plugin subframes get **no bridge**, even though the host can automate their main document. The automation content world must be distinct from the credential-bearing plugin bridge world. Never reveal bridge credentials through snapshots, evaluation or metadata.
7. Keep arbitrary JavaScript evaluation and screenshot **filesystem writes** socket-only. Existing browser eval remains compatible. General plugin-page eval is deferred: structured actions satisfy the initial request and reduce the new surface. Bridge snapshots return bounded JSON, not arbitrary local file paths.
8. Preserve current limits: main-document light DOM only, no iframe/shadow traversal, bounded text/elements, omitted password values, synthetic events rather than trusted hardware gestures, no guaranteed cancellation of already-submitted JS. Other text may contain secrets or malicious instructions; contents are untrusted data, not authority to execute commands.

**Acceptance:** round-trip identities from `pane.inspect` → `web.get` → snapshot → action, including plugin documents that never call the bridge, BFCache restoration and service restart. Run the same automation conformance suite against BrowserPane and a registered plugin fixture. Verify snapshot/ref/action behavior, navigation races, cached history, view replacement, cancellation, output caps and pending-slot release. Add plugin-origin/subframe/ordinary-browser negative tests; confirm service restart invalidates refs without changing registration identity. Existing browser behavior and panel service/storage scopes must remain intact.

## 5. Commands and methods to add

Legend: **C** = registry command via `command.run`; **R** = read RPC; **M** = dedicated mutation/resource RPC. **B** = registered page bridge exposure; **A** = administrative CLI/socket and native UI only. New C commands have no default shortcut unless separately chosen. Fixed no-argument aliases can appear in ⌘K; parameterized entries cannot execute without validated arguments.

### First delivery: discovery, appearance and application settings

| Proposed ID | Kind/surface | Inputs / behavior |
| --- | --- | --- |
| `api.describe` | R, A+B (filtered) | Versioned API/command schemas, capabilities, bounds and surface exposure. Extend `command.list` additively; never list unavailable administrative capabilities as callable from a page. |
| `workspace.snapshot`, `context.inspect`, `pane.inspect` | R, A+B | Revisioned metadata and self/target/capability discovery described above. |
| `config.patch` | M, A | Typed key/value changes plus expected config source revision; narrow writable schema, not arbitrary paths/TOML execution. Typed CLI `config set` is an adapter. |
| `appearance.set` | C, A | `{mode: light|dark|auto}`; persist through the shared settings writer. |
| `appearance.light`, `appearance.dark`, `appearance.auto` | C, A | Fixed aliases of `appearance.set`; immediately usable in ⌘K and shortcut settings. Avoid ambiguous “toggle” semantics while Auto exists. |
| `palette.list` | R, A | Bundled/custom palette names, validity and source category; no arbitrary directory listing. |
| `palette.import` | M, A | Explicit local path, existing color-only validation and collision-safe copy policy. Preserve current import/Apply distinction: import alone does not activate it. |
| `terminal.palette.set` | C, A | `{slot: light|dark, name}`; shared config writer. Does not restart terminals. |
| `terminal.font.set` | C, A | Application-wide configured font size; bounded/validated. Must not silently redefine Ghostty's existing pane-local font zoom. |
| `terminal.font.increase/decrease/reset` | C, A; optional follow-up | Clear “Application Terminal Font Size” titles; reset to documented app default. No default chord that steals terminal-local zoom. |
| `warnings.close.reset`, `warnings.type.reset` | C, A | Re-enable existing close/type confirmation policies. Do not add a general API to bypass future consent. |
| `plugins.settings.get/patch` | R/M, A+B; writes in Phase 2b | CLI supplies plugin ID; page always bound to its own namespace. Reads return own settings and an opaque write revision; patches use the path-aware writer specified below. Preserve existing page `settings.get`/`workspace.settings()` as compatible adapters. |

`config.get` should expose opaque source and applied revisions separately, plus validation/apply errors. Keep any file-content digest internal rather than exposing a hash of other plugins' potentially sensitive settings. Reuse `AppConfiguration.updating`, palette preparation, `ApplicationSettings` and native Settings save/reload behavior for their **supported application-key edits**. Do not create a second configuration store.

**Phase 2b dependency — plugin-settings writer:** the current updater addresses two-component application paths and does not implement arbitrary nested plugin edits. Do not route nested plugin settings through it unchanged, or serialize the whole namespace into an inline table that later blocks ordinary settings edits. Add a path-aware, comment-preserving structured writer as a separately reviewed extension before exposing `plugins.settings.patch`; this does not block Phase 2a appearance commands.

The proposed patch is a bounded list of `set`/`delete` operations with paths expressed as string arrays (quoted/dotted names are literal components) and an expected opaque write revision obtained from own-namespace reads. `set` replaces exactly the addressed value/subtree, not an implicit recursive merge; callers merge by patching individual children. `delete` of an absent path is a no-op. Reject empty paths/whole-namespace replacement initially and conflicting ancestor/descendant operations in one request. Accept strings, booleans, integers, finite floats, arrays and objects within existing aggregate settings limits; reject JSON null anywhere—deletion is explicit because TOML has no null value. Emit explicit nested tables/arrays of tables as appropriate, not an inline-table namespace. Preserve unrelated comments/keys; comments inside explicitly replaced/deleted subtrees need not survive. Invalid, inline or multiline source that cannot be edited safely is rejected without rewriting it. Whole-namespace replace and schema-generated forms are outside this phase. Tests must cover quoted plugin IDs such as `acme.tools`, nested tables, object/array values, deletion/null rejection, conflicts, and subsequent ordinary appearance edits. This includes upgrading the **native Settings/application writer**: its current `ConfigurationEditing` rejects every arrays-of-tables header (`[[...]]`). Phase 2b must route all supported settings-write paths through the same extended editor so emitted plugin tables/arrays remain editable by native Settings and appearance commands. Do not ship a writer that creates valid TOML another supported writer rejects solely because of its emitted grammar.

Serialize in-app writers; validate and prepare before replacing the config document; compare the latest on-disk source revision immediately before writing. Preserve comments/unrelated values; refuse unsupported inline/multiline edits or invalid source rather than replacing it with defaults. Conflict checks with non-cooperating external editors are best effort, **not a filesystem compare-and-swap guarantee**. A runtime-apply failure attempts rollback only while the written file is still ours; surface partial/uncertain persistence and applied state explicitly. A settings write is not an atomic transaction across the filesystem, Ghostty and every rendered view. Existing last-valid behavior must survive failures.

### Layout and native UI parity

| Proposed ID | Kind/surface | Inputs / behavior |
| --- | --- | --- |
| `pane.split` | C, A+B | Explicit pane-leaf or tab-root target, direction, new pane type, new-pane fraction and expected layout revision. Atomic topology/type creation; return pane ID and new revision/path. Existing `split.*` remain compatible 50/50 aliases. |
| `pane.move` | C, A+B | Source pane, destination pane, edge and revision. First delivery matches existing same-tab/unzoomed/minimum-geometry policy; preserve live contents. Cross-tab pane moves are a separate extension. |
| `layout.resize` | C, A+B | Tab, split path, expected revision and first-child fraction; typed CLI explains this convention. Validate both child minimum sizes; no zero-width hiding. |
| `pane.title.set`, `pane.title.clear` | C, A+B | Explicit pane/manual user title. Preserve normalization/length policy. Keep page `workspace.setTitle` as the separate automatic title API. |
| `tab.reorder`, `tab.detach`, `tab.move` | C, A+B | Stable tab/group IDs, zero-based destination index, expected workspace/group state and focus policy. Reuse native group synchronization. |
| `tab.detachCurrent` | C, A | Optional no-argument UI alias that captures the current tab and revision; no title-based targeting. |
| `window.list`, `window.get` | R, A | Explicit mapping of native presentation to current group/tab IDs and optional screen/frame metadata. Do not pretend a group ID is already a stable OS-window identity. |
| `window.focus` | C, A | Resolve a current window/group identity; distinguish selecting a tab from activating the application. |
| `window.frame.set`, `window.minimize`, `window.restore`, `window.fullscreen.set` | C, A; later | Require a separate native-window identity/geometry contract: display changes, coordinate units, offscreen clamping, async full-screen transitions and unsupported tiling states. Not prerequisites for core layout work. |

Fraction contract: `pane.split.newPaneFraction` always describes the newly created pane regardless of edge; conversion to first-child fraction is internal. `layout.resize.firstChildFraction` explicitly names the tree convention. All fractions must be finite, strictly between zero and one, and respect visible native minimum sizes after excluding dividers. If geometry is unavailable, return a typed failure or a clearly model-only validation mode; never promise a pixel-valid layout without checking geometry. Default split focus remains the new pane for compatibility; new APIs expose a validated `focus: new|preserve` option.

### Plugin/web/lifetime extensions

| Proposed ID | Kind/surface | Delivery |
| --- | --- | --- |
| `web.get/snapshot/click/fill/select/scroll/wait` | R/M, A+B | Shared WebKit automation; selectors/refs and lifetime guards, not native menu commands. |
| `web.screenshot` | R with local-file output, A | Explicit target/path, no page-controlled filesystem writes. |
| `plugins.service.start/stop/restart/enable/disable` | C, A | New background runtime only; do not silently change existing `plugins restart` panel-service semantics. |
| `plugins.service.list/status/logs` | R, A | Bounded status/log reads; service generation and failure/backoff state. |
| `plugins.storage.get/set/delete` | R/M, A; owned service binding later | Optional app-scoped command/service storage, distinct from existing pane/tab/global page instance storage. Namespace, quotas and lifecycle must be approved before adding this; scripts can use files meanwhile. |
| `pane.hide/show`, `panes.hidden` | C/R, A+B; gated phase | Session-preserving lifetime extension, not an alias for close or a zero-width split. |

Reserve the singular **`plugin.<plugin-id>.<local-command-id>`** prefix exclusively for contributed executable commands. Administrative IDs use `plugins.*` (plural) or another nonconflicting prefix. Do not retroactively reserve existing valid plugin IDs such as `service` or `settings`; add collision fixtures proving `plugin.service.start` still dispatches an installed plugin's own command.

Not a new-command backlog: `command.run/list`, settings opening, config reload, window/tab creation, pane copy-ID, close/focus/type, equalize/zoom, browser actions and terminal automation already exist. Do not duplicate them under inconsistent names. Saved-layout save/load/apply commands, arbitrary workspace replacement and launchers need their own design; the HTML mockup is not evidence of a production API.

## 6. Semantic events and causation

Introduce a shared host operation context: operation ID, native-assigned origin, target IDs, pre/post revisions and optional host-validated causation. It must cover menu/shortcut/CLI/page actions **and** native drag, divider and tab-group paths. Retain `host.workspace.changed` for compatibility.

Initial topics: `host.pane.created/moved/closed/type.changed/title.changed`, `host.layout.resized`, `host.tab.created/closed/reordered/moved`, `host.command.started/finished`, and `host.settings.changed` / `host.plugin.settings.changed`. Add visibility/service topics only with those phases. A split emits a pane-created event containing its split intent/result, not a second indistinguishable “created” lifecycle. Define one canonical event set for a compound operation and deterministic ordering, tied by operation ID. Divider dragging emits a semantic event at gesture commit rather than one journal event per pixel.

Events carry bounded operation-specific facts, not terminal text, DOM, settings values or entire layouts. Plugin-settings details go only to that plugin's eligible views/services (administrative socket observers retain their existing access); unrelated plugins must not receive namespace details through a global event. Existing logical-instance directed routing is not automatically suitable for headless services: add explicit recipient identity support in that phase.

A snapshot returns a cursor from the same host metadata boundary, allowing subscribe-after-snapshot without a lost change. Preserve replay expiry and restart errors; consumers resnapshot and tolerate redundant observations. Events are not durable jobs or exactly-once callbacks. A command completion may summarize partial external effects; absence of a success event does not prove nothing happened.

Automation feedback policy: event-triggered mutations carry a causation reference validated against a host-issued delivery context, not a freely trusted `source` field. Bound chain depth and per-plugin rate/admission, expose refusal diagnostics and provide disable/stop controls. Generic admin callers can always create independent root requests; indirect page/DOM side effects may also become new roots when the host cannot prove causation. Apply bounded per-plugin and global admission independently of chain tracking. This is accidental-loop containment, not a sandbox against trusted code. Do not enable automatic service event activation until attribution and resync rules are tested.

## 7. Background services, then hidden-pane lifetime

### Background services (separate from commands and HTTP panel servers)

- New optional manifest service declaration: one app-level headless service per plugin initially, with explicit start or **user-enabled** on-start activation. Registration alone must not auto-start a service. No arbitrary on-event activation in the first version.
- Reuse process-group supervision/log bounds/watchdog cleanup, not the mandatory HTTP-listener readiness check. Specify a small versioned readiness handshake and deadline; absence/failure is visible and bounded. Do not use a 295-second command as a daemon.
- Define stopped/starting/ready/backoff/failed/stopping/disabled states; capped restart attempts with backoff, explicit reset, disable/unregister/quit/crash cleanup, restart settings and failure visibility. Panel/command/service state are independently discoverable.
- An app-level service has no pane by default. Per-view requests/event payloads carry explicit targets. New authenticated service-session adapters bind plugin identity, generation, storage namespace and causation; do not promote claimed CLI environment fields to host provenance. Credential delivery, readiness protocol and bridge-equivalent method exposure require a focused protocol/security review before this phase starts.
- Service settings changes have a versioned notification. The process environment stays its launch snapshot; services fetch current own settings explicitly. Expired cursors/restarted app epochs require resnapshot, not silent skipping or replay of arbitrary external actions.
- Stopping a service cannot undo commands/side effects it already initiated. Define which owned pending requests/jobs are canceled, and test nested command ownership before shipping automatic activation.

### Hidden panes (requires its own lifecycle gate)

Retain the pane ID, terminal/WebKit content and live resources while removing it from the visible layout. Store hidden membership explicitly, not in the split tree with fraction zero. Preserve page instances and document lifetime deliberately; hiding is not navigation or closing. Hidden activities still consume resources and may have external effects.

Define a reattachment intent anchored to a live pane/root plus a validated fraction/revision; never replay an old layout snapshot over current work. Missing anchors produce a conflict with explicit caller-selected fallback. Hiding the last visible pane is rejected initially. Focus/active-terminal history excludes hidden panes, but explicitly addressed terminal operations may still target retained sessions. Web interaction requires a renderable visible view and must not silently reveal it. Inspection reports hidden/readiness/renderability truthfully.

Close-tab/window/quit and plugin-unregister policies must account for hidden running contents in termination warnings and cleanup. Saved restoration may remember configuration/visibility, **not promise survival of PTYs or WebKit documents across app restart**. Document memory limits and a user-visible list of hidden panes; do not silently evict live sessions.

### Interception hooks remain deferred

No before-operation/veto hooks in the above phases. Revisit only with a requirement that post-commit events and safe operations cannot satisfy. That design must resolve deadlines, deterministic ordering, reentrancy, failure/bypass policy, stale approvals, consent and cancellation; it is not implied by the event API.

## 8. Delivery sequence and acceptance gates

| Phase | Bounded deliverable | Required gate |
| --- | --- | --- |
| 0 | Agree schemas, command/RPC split, exposure matrix, identity/revision/error contracts and shared host mutation boundary | Contract review; compatibility fixtures for existing command IDs, raw layout reads and bridge calls. Reserve new error codes centrally, not ad hoc in each adapter. |
| 1 | Revision tracking for existing mutations, agent self context, environment additions, typed workspace/pane inspection, CLI JSON errors and discovery | Full target/session matrix; old-server guard negotiation; revisions change for legacy/native mutations before being advertised; revision-consistent pagination; unknown/no-workspace states, bounds and no secret-environment disclosure. |
| 2a | Shared application configuration writer, appearance aliases and palette operations | Native/CLI consistency, invalid-source protection, external-edit conflicts, disk/apply failures, correct bridge rejection through both direct RPC and `command.run`, no terminal restarts for live appearance changes. |
| 2b | Own-plugin settings patch API after the path-aware writer extension | Nested/quoted paths and tables, replace-versus-merge semantics, deletion and null rejection, aggregate limits, isolation, conflict tokens and subsequent application-setting edits. Separate from the first appearance delivery. |
| 3 | Shared mutation/event commit path; atomic split-with-type/fraction, move/resize, manual title and tab-group parity | Model invariant/rollback tests; revision conflicts after awaits; native gestures and API produce consistent results/events; content identity retained; safety/force/zoom/minimum-size rules; cursor loss and causation tests. |
| 4 | Shared web automation helper and plugin-panel interaction | Existing browser tests unchanged plus reusable conformance tests on both adapters and all origin/lifetime/privacy negatives. Can be scheduled after Phase 1 independently of Phase 3; do not make it depend on background services. |
| 5 | Explicit/user-enabled background service runtime | Separate service protocol review; real process crash/shutdown/unregister cleanup, restart caps, settings/event resync, ownership and loop containment. |
| 6 | Session-preserving hidden panes | Separate model/persistence design review; retain PTY/view identity, safe restore anchors, hidden-work close consent, memory bounds and visibility/inspection semantics. |
| Later | Native window geometry, optional app-font aliases, command/service storage, narrowly justified interception | Approve their concrete contracts independently; no automatic expansion of earlier phases. |

Each phase should be a reviewable change set with typed request/result tests, host/CLI/bridge dispatch tests, failure/cancellation/conflict tests, native regression coverage where applicable, documentation and examples. Run the sequential full suite after integration; inspect the actual source/binary verification manifest. No claim that this proposal's APIs have passed tests merely because the current baseline has.

The first useful implementation slice after approval is **Phases 0, 1 and 2a**: discover the API, identify/inspect the caller's workspace safely, and change appearance through the same path as Settings. Phase 2b is a separate settings-editor extension. Next deliver layout/events and shared web interaction; do not start services, hide/show or hooks in the first PR.

## 9. Review/approval checklist

The reviewer should challenge: environment staleness and app/session confusion; claims of atomicity; compatible response shapes; exposure via `command.run`; native gesture bypasses; information/content bounds; plugin bridge versus automation-world isolation; shared WebKit ownership; event loss/feedback loops; and hidden/service resource lifecycle. Confirm each proposed command is actually missing or an intentional typed wrapper, and that optional/deferred items are not silently bundled into the first delivery.

User approval is still needed before implementation, particularly for administrative-versus-page exposure, cross-pane structured web interaction, required revision guards on new structural operations, the cross-app CLI targeting safety change, and the service activation policy. Review findings and their disposition belong in `api-extension-plan-review.md`.
