# Managed ZIP plugin packages

Status: implemented in the working tree. See [current contract](plugins.md#managed-zip-packages) and [verification status](api-extension-progress.md#managed-zip-plugin-packages) for actual checks and VM blockers. The design/sequence below records the refactor baseline, not a claim that unexecuted integration gates passed.

## Outcome and boundaries

Installing a plugin means importing a ZIP into Slate's application-support directory. Slate owns both the archive and the extracted resources. The original ZIP and its source/download directory can be deleted without affecting the installed plugin, including after an app restart.

- ZIP only; no custom extension, loose-manifest registration, or directory/development registration mode.
- Require `plugin.json` at the ZIP root. Bundle the plugin's HTML, scripts, images, and other local resources alongside it.
- Keep registration and enabled state in a readable JSON file beside the managed packages.
- No migration, legacy-format readers, automatic conversion, or backward-compatibility aliases for old manifest inputs. Existing debug plugins must be repackaged and installed manually.
- Do not bundle, install, discover, or resolve external runtimes/dependencies. An absolute executable such as `/bin/sh` or `/usr/bin/python3` remains an explicit external prerequisite.
- Do not change plugin trust, bridge permissions, command supervision, scope, or manual background-service activation.
- This work must not automatically delete old registrations, downloads, plugin data, settings, shortcuts, or workspace snapshots.

“Self-contained” here means Slate manages all packaged plugin files, not that it guarantees offline operation or supplies interpreters. Existing HTTPS and managed-loopback panel sources remain supported inside packaged manifests.

## Current implementation: what actually needs changing

Registration is already file-based, not opaque storage:

- `Native/ApplicationSettings.swift` sets `base` to `~/Library/Application Support/SlateTerm`, with the existing `SLATE_TERM_STATE_DIR` override for isolated tests.
- `Native/WorkspaceHost.swift` constructs `PluginCatalog(directory: settings.base/state)`.
- `Sources/SlateTermSettings/PluginCatalog.swift` writes `state/plugins.json`. Schema 3 contains full decoded registrations, `disabledPlugins`, and `enabledServices`.
- `Sources/SlateTermSettings/PrivateJSONStore.swift` writes sorted-key JSON through an atomic rename, with private directory/file permissions. It is currently compact, not pretty-printed. Atomic replacement is not an fsync/power-loss guarantee.

There is no package import today:

| Area | Current implementation / required change |
| --- | --- |
| Manifest and static assets | `Sources/SlateTermCore/PluginRegistration.swift`: `PluginRegistration.parse`, `PluginSource`, `PluginProcessSpec`, and `PluginAssets`. Static roots, executable paths, and working directories currently require absolute paths. Separate portable manifest validation from installed runtime resolution. |
| Command declarations | `Sources/SlateTermCore/PluginCommand.swift`: commands also require absolute executable/directory paths. Apply the same package-relative contract as panel processes and background services. |
| Host registration | `Native/WorkspaceHost.swift`: synchronous `.pluginsRegister` accepts a JSON `manifest`, validates the static entry, saves the catalog, and retires previous runtimes. Replace manifest registration with asynchronous ZIP preparation and a serialized install commit. |
| Removal and enable/disable | `changePluginRegistration` persists before retiring resources and uses workspace transitions for forced pane closure. Extend removal to retire managed files safely; disabling must not remove files. Preserve confirmation and revision checks in `changePluginFromSettings`. |
| Native UI | `registerPlugin()` opens `.json`, decodes the manifest, asks for trust, and calls `plugins.register`. `Native/SettingsWindow.swift` has Register labels and a `--manifest` example. Select ZIPs and confirm the exact staged package instead. |
| CLI | `Sources/SlateTermCLI/SlateTermCLI.swift` reads/decodes JSON locally for `register` and offline `validate`. `PluginPersistenceCLI.swift` rejects unrelated registration flags. Change both option validation paths to the package contract. |
| Public contract | `Sources/SlateTermCore/AutomationAPI.swift`, `Native/WorkspaceAPI.swift`, `Native/DividerOperations.swift`, and the generated adapters in `Native/PluginPane.swift`. Update discovery, routing, method classification, and parity tests together. |
| Static runtime | `Native/PluginPane.swift` constructs `PluginSchemeHandler` directly from `registration.source.path`. Feed it only an installed, resolved managed root. Preserve `plugin://<id>/`, main-frame bridge binding, and `PluginAssets` containment/read limits. |
| Executable runtimes | `Native/PluginCommands.swift`, `Native/PluginInstance.swift`, and `Native/BackgroundServiceGeneration.swift` pass executable/arguments/directory into `PluginProcess`. `Native/BackgroundServices.swift` owns service generations. All three need the same resolver and package-generation lifetime ownership. |
| Persistent plugin values | `Native/PluginPersistenceAPI.swift` uses `state/plugin-data-v2`; panel state belongs to workspace records. These are user data, not package contents. Leave their locations and retention semantics unchanged. |
| Dependencies/build | `Package.swift` currently has no ZIP reader. Introduce one shared archive implementation usable by app and offline CLI validation; verify linkage through `slate-term.xcodeproj/project.pbxproj`. |

The repository's `AGENTS.md` explicitly permits breaking unreleased development formats without migration machinery. Existing absolute-path fixtures, including the Lisa plugin outside the app project, are authoring examples to repackage manually, not formats to support indefinitely.

## 1. Package and path contract

Example ZIP contents (no enclosing folder):

```text
plugin.json
web/index.html
web/app.js
web/assets/icon.png
scripts/list-dir.py
```

Example portable manifest:

```json
{
  "id": "tools",
  "title": "My Tools",
  "source": { "kind": "directory", "path": "web", "entry": "index.html" },
  "commands": [{
    "id": "list-dir",
    "title": "List Directory",
    "executable": "/usr/bin/python3",
    "arguments": ["-I", "{pluginRoot}/scripts/list-dir.py"],
    "timeoutSeconds": 10
  }]
}
```

Path rules:

1. `source.path` is relative to the installed package root; `"."` means that root. Reject absolute static roots and parent traversal. `source.entry` remains relative to that static root.
2. `process`, `service`, and command `directory` are package-relative; omitted or `"."` means the installed package root. This intentionally replaces the current inherited app working directory behavior.
3. An executable is either an explicit absolute external prerequisite or an explicit package-relative path such as `./bin/tool`. Do not introduce PATH lookup, shell expansion, or dependency discovery. Validate local executable existence/type/execute permission during preparation.
4. Arguments remain literal except for a narrowly defined `{pluginRoot}` prefix: expand a standalone token or `{pluginRoot}/<relative-path>` to the generation's absolute content root. Validate the relative suffix against traversal. This supports script/resource arguments even with a non-root working directory. Do not rewrite arbitrary substrings, absolute argument strings, shell snippets, or environment values.
5. Preserve the existing exact `{port}` argument replacement for panel HTTP processes, independently of package-root resolution. Add authoritative `SLATE_TERM_PLUGIN_ROOT` to all three launch environments after reserved variables are stripped; scripts may use it explicitly.
6. Validate path-bearing fields centrally: no NULs, backslashes, empty components, `..`, or absolute paths in relative fields. Allow the explicitly documented root `"."` and leading `./` executable form; normalize them once. Resolve and verify containment beneath the immutable generation root.
7. Installation must validate referenced static entry files and local executable/directory paths. It cannot infer which arbitrary strings or script contents reference external files; authors must package their local resources and use this path contract. External-runtime availability remains a launch-time prerequisite, not a bundling task.

Introduce a portable `PluginManifest` representation and a single resolver producing the existing runtime-facing `PluginRegistration` (or an equivalent explicitly resolved type). Share contribution/identity validation rather than maintaining two independent parsers. Never persist resolved absolute paths or mutate the archived manifest to bake in an installation location.

## 2. Managed storage and readable registry

Use `settings.base/plugins`, not the `.app` bundle, Downloads, the config directory, or a temporary directory:

```text
~/Library/Application Support/SlateTerm/
├── plugins/
│   ├── registry.json
│   ├── packages/
│   │   └── tools/
│   │       └── <installation-uuid>/
│   │           ├── package.zip
│   │           └── contents/
│   │               ├── plugin.json
│   │               ├── web/...
│   │               └── scripts/...
│   └── .staging/<operation-uuid>/...
└── state/...                       # workspace and retained plugin data stay here
```

Each successful import has a fresh host-generated installation UUID. Never derive filesystem destinations from the uploaded filename, ZIP directory wrapper, or an unchecked manifest ID. Generation directories are immutable to Slate after publication and retain both the imported ZIP and its validated extraction. Runtime uses extracted files; it never reads resources from the original location or extracts on every launch.

Proposed `registry.json`:

```json
{
  "schemaVersion": 1,
  "plugins": [
    {
      "id": "tools",
      "installationID": "bb4fcb94-3520-4338-90bc-4e1dcecabd0a",
      "enabled": true,
      "archiveSHA256": "<sha256-of-managed-package.zip>"
    }
  ]
}
```

- The registry records installed identity, selected generation, integrity metadata, and explicit enabled state. The portable manifest in `contents/plugin.json` supplies contributions/title; do not duplicate resolved registrations in JSON.
- Derive all package paths from validated ID/UUID fields. No caller-selected install destination and no download-path dependency in the registry.
- Keep the existing maximum of 64 installed plugins, enforce unique IDs, and sort records by ID. Bound registry/manifest reads.
- Retain `PrivateJSONStore` ownership, symlink rejection, private permissions, and atomic-write guarantees. Add an optional pretty-print formatting setting for this store rather than changing every other JSON file's formatting. Use sorted keys, indentation, and a trailing newline for the registry.
- Background services are currently manual/session-only (`BackgroundServices.swift`). Do not carry the old catalog's `enabledServices` persistence into the new schema or interpret plugin `enabled` as permission to start services at launch. Remove obsolete persisted-service consumers/tests as part of this breaking format change; preserve explicit start/stop APIs.
- Readable does not mean live-editable: the app is the sole writer under its state-directory lease. Document that manual inspection is safe, but edits require quitting and restarting; no watcher or merge/conflict editor in this refactor.
- Startup reads only the new registry. Missing registry means no installed packages; never import the old `state/plugins.json`. Leave that file untouched. Invalid registry bytes are preserved and reported, never silently overwritten with an empty catalog.
- Validate each referenced installed manifest and root before exposing its contributions. Surface missing/corrupt packages as unavailable with diagnostics in Settings/list output, without losing their persisted enabled choice or preventing healthy packages from loading. Enabling a broken package fails until repaired by explicit replacement/reinstall.

Add a filesystem-owning `PluginPackageStore` in `SlateTermSettings`; keep `PluginCatalog` focused on registration/enabled-state persistence and runtime views derived from installed records. Both receive explicit roots for isolated tests.

## 3. ZIP inspection and preparation

Use a shared ZIP reader, not Finder automation or unchecked `unzip`/`ditto` extraction. Proposed implementation: a narrowly wrapped system `libarchive` ZIP reader, linked through a small SwiftPM C support target and used by `SlateTermSettings`. Enable ZIP support only; do not accept other libarchive formats. Verify macOS SDK/build availability in the first implementation phase before host integration.

The wrapper must iterate entries and stream bytes into host-created files. Never let the archive library materialize arbitrary entry paths itself. Native install/validation performs disk/decompression work off the main actor; final catalog publication is serialized on the host.

Initial explicit bounds, centralized for discovery/tests:

- 128 MiB maximum compressed ZIP, enforced while copying the input.
- 10,000 entries, 512 MiB actual total extracted bytes, 64 MiB per regular file.
- 256 KiB manifest, preserving the current manifest bound.
- 32 path components and 1,024 UTF-8 bytes per entry path.
- Keep the existing 16 MiB static asset serving bound; extraction limits do not expand WebKit serving permissions.

Reject encrypted/unsupported archives, truncation/checksum failures, non-ZIP inputs renamed `.zip`, missing root manifest, and multiple manifest entries. No implicit wrapper-folder stripping. Reject absolute paths, `..`, backslashes, NULs, duplicate/conflicting paths, case/Unicode-normalization collisions, symlinks, hard links, devices, sockets, and other special entries before writing them. Refuse overwrite and traversal through a file/symlink; containment checks must happen before extraction, not after an unsafe extractor has run. Treat archive reader warnings/errors as validation failures, and enforce actual streamed byte limits rather than trusting ZIP headers.

Use private staging directories and host-selected regular-file destinations. Normalize permissions to owner-only directories/files, preserving only owner-executable intent for packaged executables; do not restore ownership, setuid bits, arbitrary extended attributes, or archive permission modes. Preserve normal executable trust/platform failures rather than bypassing macOS protections. No install hooks, package managers, imports, script execution, or backend activation during validation/install.

## 4. Install, replacement, removal, and failure semantics

### Prepare, then publish

1. Capture caller/operation context. Copy the selected regular `.zip` into private staging with a bounded read. The staged snapshot, not the caller's mutable input, becomes the source of truth.
2. Inspect/extract that exact copy, parse the manifest, validate local references, and compute its digest. Resolve paths against the eventual generation root, not a staging location that will disappear.
3. For native UI, show plugin identity and trust warning from this staged snapshot. Cancel discards staging. Do not reread a different source archive after consent. CLI/API calls are explicit trusted install requests and do not open confirmation dialogs.
4. Return to the serialized host commit boundary. Revalidate caller liveness, cancellation, supplied guards, catalog generation, identity, duplicate/replacement policy, and active panes after every asynchronous/confirmation boundary. Hold package-write serialization across competing operations; never let an earlier preparation overwrite a newer install.
5. Rename the complete staged generation into its final same-volume location. Atomically write the candidate registry selecting it. Do not publish new catalog state, stop old runtimes, or emit success events before that write succeeds. Preflight required event publication using the existing operation/event patterns.
6. Accept the new in-memory catalog, invalidate old header/runtime generations, rebuild menus/settings, and publish `host.plugins.changed`. Installing does not create a pane or start a process. Return the selected installation ID and enabled state.

On validation, copy, rename, or registry-write failure, retain old catalog bytes, contributions, enabled state, and running work. Remove only the new unreferenced staging/generation where safe. A completed filesystem write is not a rollbackable workspace transaction; do not claim all file/process effects are atomically reversible or power-loss durable.

### Replacement

- Duplicate ID requires explicit `replace: true` / `--replace`.
- Keep the existing requirement that this plugin's visible panes are closed before replacement; do not add forced replacement or silently close panes.
- Preserve the plugin's enabled choice, saved data/settings/shortcuts, but do not restart old commands or services on the new package.
- Retire old command/panel/service generations using existing supervision. Keep the old package generation on disk until owned processes and asset readers have released it; process cleanup can remain pending after the public invocation ends.
- Add generation leases/references shared by these runtimes and deferred package cleanup. Never delete an old script/resource tree merely because `remove()` initiated asynchronous process shutdown.

### Disable and uninstall

- Disable changes registry state and stops/closes work under the existing force/confirmation contract; retain ZIP and extraction so enable works without the download.
- `plugins.unregister` removes the registry record using existing workspace-transition preflight/persistence ordering, then retires the runtimes and schedules archive/extraction deletion once cleanup is confirmed. Removal affects managed package files only, not original downloads or retained user data.
- Cleanup failures after a committed replacement/removal are reported as pending diagnostics, not as an uncommitted registration failure that callers should blindly retry.
- Cleanup operates only on validated, unreferenced children of this store's staging/packages roots. Never follow links or recursively remove a caller-supplied path.

### Interruption and corruption

The registry is the commit pointer. A crash before its update leaves the old installation selected plus an unreferenced new directory; a crash after it leaves a complete new generation selected plus possibly old cleanup candidates. Never select a half-extracted directory. Scan only managed orphan/staging candidates for cleanup under the exclusive state lease. Retain a generation if prior owned-process cleanup cannot be confirmed; do not assume losing an in-memory runtime reference proves the process stopped. Do not use orphan scanning to discover/register packages automatically.

Do not automatically repair from Downloads, overwrite corrupt registry bytes, or synthesize registrations from old debug manifests. Surface actionable errors and allow explicit replacement. If a saved workspace references a no-longer-installed/broken type, preserve the existing workspace restoration failure/preservation behavior rather than introducing an unrelated workspace migration.

## 5. Native, CLI, and shared API contract

Keep existing management method names to avoid gratuitous command-family churn, but replace their inputs completely:

```sh
slate-term plugins validate --package /absolute/path/tools.zip
slate-term plugins register --package /absolute/path/tools.zip
slate-term plugins register --package /absolute/path/tools.zip --replace
slate-term plugins disable tools --force
slate-term plugins enable tools
slate-term plugins unregister tools --force
```

- `plugins.register { packagePath, replace?: boolean }` performs managed installation. Reject the old `manifest` payload and unknown fields. Require a host-readable absolute local ZIP path; no URL fetch, archive base64 payload, or configurable extraction destination. CLI resolves its local relative input to an absolute path before sending it.
- Add `plugins.validate { packagePath }` for trusted socket/page/service clients. It shares bounded preparation with installation but neither changes the registry nor grants trust nor launches code. CLI `validate` stays offline and uses that same library against disposable temporary staging, never the user's app-support root.
- Validation reports portable manifest/identity/digest; install/list report identity/title, installation ID, enabled choice, availability/diagnostic, and managed location. Document structured invalid-package, conflict/in-use, unavailable, write-failed, and cleanup-pending outcomes. Use existing error constants where appropriate; never include archive bodies or secrets in errors/events.
- Update `AutomationMethod` family/routing/mutation classification, discovery metadata/version, public schemas/docs, and generated `workspace.rpc` exposure together. `plugins.validate` is a read/inspection operation despite temporary I/O; registration remains a mutation. Existing app/workspace guards and caller-lifetime rules still apply.
- Native Settings uses **Install Plugin…**, a ZIP picker, and the same prepare/commit implementation as the API. Remove `--manifest` instructional text and explain that removal deletes installed code but retains saved data. Keep enable checkbox and existing removal confirmation behavior.
- Installation/validation require arguments, so no new parameterless Cmd-K install action is needed; existing Settings navigation remains the picker route. Existing contributed commands/header buttons/shortcuts continue to derive from enabled, available installed registrations.
- No transport-specific package installer, registered-page privilege exception, host-GUI automation, or implicit service activation.

## 6. Implementation sequence

1. **Portable model and archive boundary.** Add package manifest/path resolver, archive reader support target/wrapper, bounded ZIP preparation, and focused parser/extraction tests. Prove the chosen reader's streamed limits, link/type detection, checksum failures, and build linkage before adding UI.
2. **Managed store and registry.** Add `PluginPackageStore`, installed records, pretty JSON registry persistence, startup validation/diagnostics, generation commit/cleanup ownership, and failure-injection tests. Replace catalog schema directly; do not read/migrate the old file.
3. **Host and runtime integration.** Route register/validate through `WorkspaceHost.routeAdmitted` async preparation plus serialized publication; replace the synchronous manifest case. Thread resolved generation/root ownership through static panels, command invocations, HTTP panel processes, and service generations. Extend unregister without weakening `WorkspaceTransition` persistence/publication ordering.
4. **Clients, native controls, and authoring.** Update API discovery, generated adapters, CLI option rejection, offline validation, Settings picker/trust flow, test-only replacement-during-confirmation hooks, examples, and fixtures. Update `docs/plugins.md`, `docs/agent-api.md`, relevant background-service/persistence docs, and `skills/slate-terminal/references/building-plugins.md`. Load the plugin-authoring skill before editing examples; packaging must copy actual UI-kit resources rather than depend on links to the checkout. Document `zip -r tools.zip plugin.json web scripts` from the package root; no new packager command is required.
5. **Verification.** Convert integration fixture creation from JSON registration to ZIP creation, add a download-deletion regression, then run focused and full gates. Update the capability/progress docs with implemented/tested/deferred status only when implementation actually exists.

Do not leave a loose-manifest registration escape hatch while converting fixtures. Audit all `plugins.register`, `--manifest`, direct `PluginCatalog` construction, and schema-3 catalog assumptions, including `WorkspaceHost` debug hooks and CLI persistence flag validation.

## 7. Acceptance tests

### Model, ZIP, and store tests (host unit tests)

Extend `PluginRegistrationTests`, `PluginCommandTests`, `PluginCatalogTests`, service catalog tests, and CLI tests; add dedicated package/path/archive tests:

- Static-only, command-only, service-only, mixed, and URL/managed-server manifests install under the new contract. Header/layout contributions retain validation.
- Source, entry, executable, directory, and root-token resolution use the installed generation. CWD defaults to package root consistently in all runtimes. `{port}` and reserved-environment filtering are unchanged.
- ZIP-only/root-manifest rules and every extraction rejection/size bound above, including collisions on a case-insensitive filesystem, deceptive metadata, actual streaming expansion, and truncated/corrupt archives.
- Registry is pretty readable JSON with explicit `enabled`; it round-trips with private permissions, bounded reads, and no original-path references. Missing/invalid packages produce diagnostics; corrupt registry bytes are not overwritten.
- Duplicate/replacement policy, disabled-state preservation, disable retaining files, uninstall retaining user data, and no-op enable/disable not rewriting bytes/emitting events.
- Inject failures at copy, extraction, rename, registry replacement, publication preflight, and cleanup. Failed precommit work leaves old bytes/runtime untouched; postcommit cleanup failure leaves the correct selected generation and a truthful pending status.
- Crash-shape fixtures cover staged-only, final-but-unreferenced, selected-new/retained-old, and removed-but-not-yet-cleaned trees. Cleanup never follows links or removes referenced/leased packages.
- Old `manifest` API payloads, `--manifest`, loose JSON, unknown fields, and legacy registry formats are rejected/not loaded. The old catalog is never read or deleted.

### Native/runtime and parity tests (VMPal only)

Update `scripts/verify-plugins.py`, `verify-plugin-lifecycle.py`, `verify-plugin-commands.py`, `verify-plugin-services.py`, `verify-background-services.py`, `verify-plugin-header-buttons.py`, persistence/settings gates, and API parity fixtures as applicable. Add/register a focused package-install gate in `scripts/verification_gates.py` if a separate gate is useful.

The critical end-to-end test:

1. Create a ZIP plus its authoring files under an isolated simulated Downloads directory, distinct from `SLATE_TERM_STATE_DIR`.
2. Install it through the production CLI/API and assert the managed ZIP, extraction, and readable registry exist.
3. Delete the original ZIP **and** the complete authoring directory.
4. Open the static panel; verify HTML, modules, nested assets, and bridge operation. Run a command that reads a packaged resource and exercise packaged HTTP/backend and manual-service scripts.
5. Restart Slate against the same isolated state root and repeat. Verify enabled/disabled choices survive and background services do not start automatically.
6. Replace from a second ZIP; delete that source too. Verify the new resources execute, old leased resources remain until cleanup, and failed replacement leaves the working install intact.
7. Disable/re-enable without the source ZIP; uninstall and confirm managed files eventually disappear while saved data/settings/shortcuts remain.

Also test native cancellation/trust consent, replacement during confirmation/preparation, invalid/stale guards/callers, simultaneous install/remove requests, in-use pane refusal/forced removal, and equal discovery/results across CLI, page bridge, and native service clients. No ordinary browser/subframe gains plugin privileges.

Use `bash scripts/verify-model.sh` and `bash scripts/build-app.sh` on the host; discover/select native gates with `python3 scripts/verify-vm.py --list` and run them in the VM. Include the existing plugins/lifecycle/commands/services/persistence/header-button, background-services, settings-window, API-parity, and worker/process gates. Native visual changes require fresh rendered review in the VM. Finish implementation with `bash scripts/verify-all.sh`; report actual gate results and anything unverified. None of those implementation checks are claimed by this planning document.
