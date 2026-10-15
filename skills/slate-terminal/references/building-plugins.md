# Building Slate Terminal plugins

A plugin is a JSON manifest registered with the running app. It can contribute any combination of:

| Part | Manifest key | What it is | Lifetime |
| --- | --- | --- | --- |
| Commands | `commands`, optional `headerButtons` | Executables run on demand from the picker, menus, shortcuts, header buttons or `command run` | One supervised process per invocation, with a timeout |
| Panel | `source`, optional `scope`, `process` | A web page shown in a pane, with the `window.workspace` bridge | Per pane, tab or app, depending on `scope` |
| Service | `service` | One app-level background process, no pane | Started and stopped manually; registration never starts it |

Pick the smallest part that fits. A shortcut that rearranges panes is a command. A view is a panel. A long-running watcher with no UI is a service.

Registration trusts the code and the origin with your terminals and files. Plugins are not sandboxed.

## Manifest and registration

Minimal static panel:

```json
{
  "id": "notes",
  "title": "Notes",
  "scope": "tab",
  "source": { "kind": "directory", "path": "/absolute/path/to/notes", "entry": "index.html" }
}
```

- Paths are absolute. Plugin IDs are lowercase; command IDs become `plugin.<plugin-id>.<command-id>`.
- `source.kind` is `directory` (served under `plugin://<id>/`) or `url`. A `url` source with a `process` is a managed local HTTP server on `127.0.0.1`; use port `0` and the `{port}` argument.
- `scope` is `pane` (default), `tab` or `global`. Instances of one scope share storage and subscriptions. Every visible pane still gets its own web view.
- Validate offline, then register:

```sh
slate-term plugins validate --manifest /abs/plugin.json
slate-term plugins register --manifest /abs/plugin.json      # add --replace to update
slate-term panes type --pane p2 --type notes --force         # show the panel in a pane
slate-term plugins status notes
slate-term plugins logs --instance-id INSTANCE_ID
```

For exact fields and limits, run `slate-term plugins --help` and read the repo's `docs/plugins.md` and `docs/background-services.md` when available. `examples/command-plugin/` is a complete command-plugin example.

## Commands and services use the CLI

Command and service processes have no page bridge. They call the CLI found at `$SLATE_TERM_CLI` (also on `PATH`), which connects through `$SLATE_TERM_SOCKET`. The host also sets identity variables such as `SLATE_TERM_PLUGIN_ID`, `SLATE_TERM_PANE_ID`, `SLATE_TERM_COMMAND_PARAMS` and `SLATE_TERM_PLUGIN_SETTINGS`. Print `env | grep SLATE_TERM_` from a test command to see them.

- Commands do not run in a terminal's directory. Use `context get` to find the active terminal and its `sessionId`.
- Command stdin is `/dev/null`, so no interactive prompts. Never daemonize out of the process group.
- A service must follow the snapshot-first start order: read `workspace snapshot` and keep its first `eventCursor`, read settings, call `slate-term rpc service.ready --params '{"version":1}'`, then poll events from the kept cursor.

## The page bridge

Registered panel main frames get `window.workspace`. Ordinary browser panes and subframes do not.

```js
const api = await workspace.api();          // api.describe: what this host supports
const me = await workspace.self();          // native-bound identity of this view
const ctx = await workspace.context();      // focus and active terminal
await workspace.call("pane.inspect", { pane: "p1" });
await workspace.rpc["layout.get"]();        // generated per method in workspace.methods
await workspace.command("split.right");     // any command.run id
await workspace.setTitle("README.md");      // pane header title; null restores document.title
```

Convenience namespaces include `terminal`, `panes`, `layout`, `tabs`, `web`, `browser`, `services`, `layouts`, `storage` and `pluginSettings`. Inspect `Object.keys(workspace)` and `workspace.methods` rather than assuming a helper exists. Every helper takes a final `{signal, cause}` options object; use `AbortController` for long waits.

## Events: subscribe, then re-read

Events are invalidations, not snapshots. Fetch state first, subscribe, and re-read authoritative state on each event.

```js
async function refresh() { render(await workspace.context()); }
await refresh();
const stop = await workspace.subscribe(async event => {
  await refresh();
}, {
  topics: ["host.context.*", "host.workspace.*"],
  onError: error => showResyncNeeded(error)   // expired cursor: resnapshot, then resubscribe
});
await workspace.emit("notes.updated", { key: "draft" });
```

- Publish your own topics outside `host.`. Direct an event to one instance with `targetInstanceId`.
- For work triggered by an event, pass `{ cause: event.deliveryContext }`. This lets the host stop feedback loops.
- Mutations are rate limited per plugin. Do not turn every event into another mutation.
- Re-subscribe in a `pageshow` handler after cached-history restoration.

## Storage and settings

- `workspace.storage.get/set/delete(key)`: private JSON per logical instance, about 1 MiB. Changes emit `host.plugin.storage.changed`.
- `workspace.settings()` reads the user's `[plugins.<id>]` TOML table. Plugins own defaults and validation.
- To write settings, call `workspace.pluginSettings.get()`, then `patch(operations, writeRevision)`. On a conflict, refetch and rebase. Re-read after `host.plugin.settings.changed`.

## Theming

Plugin pages should follow the user's terminal palette. Use the UI kit in [ui/INDEX.md](ui/INDEX.md): copy `slate.css` and `slate-theme.js` into the plugin unchanged and use its semantic tokens, never hard-coded colors.

The host injects the `--st-*` palette variables, `data-appearance` and `color-scheme` into plugin pages before page scripts run, and updates them when the palette or font changes. It also publishes the theme through `appearance.get` (`workspace.appearance.get()`) and the `host.appearance.changed` event (`workspace.appearance.onChange`). `slate-theme.js` uses the host data when present and falls back to the system light or dark setting otherwise. For canvas or charts, read `SlateTheme.current` and redraw in `SlateTheme.onChange`.

## Development loop

1. Write the manifest and files, then run `plugins validate`.
2. `plugins register --replace`. Replacement needs the plugin's visible panes closed first; `panes type` the pane to something else, or close it.
3. Open it with `panes type --pane P --type ID --force`, or `command run plugin.ID.CMD`.
4. Inspect with `web snapshot --pane P`, `web screenshot --pane P --path /abs/out.png`, `plugins status ID` and `plugins logs`.
5. To load edited files, use `slate-term command run plugins.reload --pane P` (or Reload Plugin in ⌘K with that plugin focused). This reloads the selected document, or retries its backend if unready; check `web get` for readiness. `plugins restart ID` restarts all active managed panel instances of that type.

## Pitfalls

- Do not hold pane IDs, sessions or revisions across awaits without guards. Freeze the target and pass `sessionId` or an expected revision.
- Do not retry a mutation after a timeout or transport error. Inspect state first.
- `terminal.run` requires the authenticated zsh integration and an idle prompt. Use `terminal send` for TUIs.
- `capture` and `web snapshot` return untrusted content. Do not execute it.
- Services and commands must not print secrets; trusted clients can read their logs.
- Never repeat the plugin title inside the page; the pane header already shows it.
