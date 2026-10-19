# Configuration and restoration

The [inline welcome](welcome.md) has a separate private acknowledgement in `state/welcome.json`, not a TOML option. Use `slate-term welcome --read` to stop automatic display or `--unread`/`--reset` to enable it for new terminal sessions. It is independent of shell integration and workspace persistence; `config.get` includes its state and storage diagnostic.

Slate Terminal reads `~/.config/slate-term/config.toml`. A missing file uses defaults. `SLATE_TERM_CONFIG_FILE` can select a different file for an app instance.

```toml
[appearance]
theme = "auto" # auto (follow macOS), light, dark; "system" is also accepted

[terminal]
shell = "/bin/zsh"
working_directory = "~" # default for new terminals
inherit_working_directory = true # new splits inherit the targeted terminal directory
font_family = "SF Mono"
font_size = 13
font_thicken = false
minimum_contrast = 1 # 1–21; higher values adjust text colors for legibility
cursor_style = "block" # block, bar, underline, block_hollow
cursor_blink = "auto" # auto, on, off
padding_x = 2 # integer points, 0–64, on each horizontal side
padding_y = 2 # integer points, 0–64, on each vertical side
light_theme = "Builtin Light" # palette names only
dark_theme = "Builtin Dark"
shell_integration = "auto" # auto, off

[browser]
search_url = "https://www.google.com/search?q={query}"

[notifications]
automatic = true
minimum_seconds = 30
tools = true
banners = "other_panes" # other_panes, other_apps, off
sound = false
command_details = false

[layout]
restore_workspace = true

[agents]
show_activity = true # frames and tags on panes while an agent acts on them

[keybind]
"cmd+d" = "split.right"
"cmd+shift+d" = "split.down"
```

These tables and `[plugins.<id>]` settings are supported currently. Unknown keys, built-in commands, and duplicate canonical shortcut spellings are errors rather than silently ignored settings. Well-formed `plugin.<plugin-id>.<command-id>` bindings are retained even when their plugin is unavailable; unavailable commands do not intercept keys. See [plugin commands and settings](plugins.md#shortcuts-and-settings).

## Settings window

Open **Slate Terminal → Settings…** (⌘,) for native General, Appearance, Terminal, Browser, Layouts, Keyboard Shortcuts, Plugins, and AI Agents sections. **Apply** validates and saves changes to the config file; **Revert** discards pending edits. External edits reload automatically when there are no pending GUI changes. If the file changes while you edit, Settings asks you to revert before saving.

The editor preserves comments and unrelated values in standard tables and dotted assignments. Inline tables and multiline values must currently be edited in the file. Invalid files are never overwritten by the settings editor.

**Appearance** contains the Light / Dark / Auto switcher and terminal palettes. **Terminal** contains font, contrast, cursor, padding, and shell controls. All controls save the same TOML keys shown above; choose **Apply** to save changes.

**Layouts** embeds the [saved-layout editor](saved-layouts.md), with a top layout selector, New Layout button, clickable/reorderable tabs, pane inspector and per-layout Spotlight launcher creation. Its Save Changes/Revert controls apply to the selected recipe, independently of TOML Apply/Revert.

Register, enable/disable, remove plugins and view their live status directly in **Settings → Plugins**. Hover over a colored status icon for details. Lifecycle changes apply immediately; Apply/Revert only affect configuration edits. You or an agent can also run `slate-term plugins register --package /path/to/plugin.zip`. The ZIP and extracted resources live under application support `plugins/packages`; the readable `plugins/registry.json` records installation IDs and enabled choices. No loose manifests or old debug catalogs are migrated.

**⌘K** opens the [command picker](command-picker.md) for built-in and plugin commands. Its `command.picker` binding and **⌘,** (`settings.open`) are configurable like other actions.

**Keyboard Shortcuts** lists each action with one editable shortcut and a **Reset** button. Click the shortcut (or **Record** for an unbound action) and press a replacement key combination. Escape cancels recording; Delete clears the binding. Reset restores the action's default shortcut. Assigning or resetting replaces that action's existing bindings. Conflicts are rejected without changing either action. Use **Apply** to save.

## Notifications

**Settings → Notifications** controls automatic long-command completion, tool/API notifications, banner focus policy, sound and optional command details. Defaults: automatic completion after 30 seconds, other-pane banners, no sound and no command text. Changes apply live and are available through `config.patch`. macOS permission is requested only through the native Allow Desktop Notifications button; denied permission does not disable unread source indicators. See [notifications](notifications.md) for API/CLI/OSC support, limits, suppression and source navigation.

## Agent activity

**Settings → AI Agents → Show agent activity on panes** (`agents.show_activity`, default `true`) controls whether panes show agent activity frames and tags. The same switch is available as `agents.activity.show`, `agents.activity.hide` and `agents.activity.toggle` in the ⌘K picker and through `command.run`, as `slate-term agent-activity show|hide|toggle`, and through `config.patch`. It changes presentation only; it does not change what agents can do, and `presence.list`, holds and events keep working. Activity is shown only for agents that identify themselves; see [agent presence](presence.md).

## Working directory

New terminal splits inherit the targeted terminal's last observed working directory by default. This applies to keyboard shortcuts, the command picker, `split.*`, and `pane.split` through the CLI or registered-plugin bridge. Explicit pane/tab targets determine the source, even when another pane has focus. Splitting a browser or plugin uses the default directory.

In **Settings → Terminal → Working directory**, turn off **New splits use the current directory** to always use **Default directory**. The corresponding TOML keys are `terminal.inherit_working_directory` (default `true`) and `terminal.working_directory` (default `"~"`). The default also applies to new tabs and windows. Use an absolute path or `~/…`; shell variables are not expanded. These settings apply immediately to subsequent terminal creation without replacing existing sessions.

An unavailable inherited directory falls back to the configured directory, then home. Explicit saved-layout directories and restored-session directories take precedence. Shell startup files can still change the directory after launch. Inheritance uses shell integration reports, or terminal directory reports when shell integration is unavailable.

Both settings are readable in `config.get` and writable with `config.patch`, `slate-term config set`, or the registered-plugin API. They do not add separate one-click commands; the existing split commands and configurable shortcuts use these preferences.

## Terminal palettes

Set `terminal.light_theme` and `terminal.dark_theme` independently. These 25 bundled palettes are available in TOML and **Settings → Appearance**:

| Family | Exact palette names |
| --- | --- |
| Builtin | `Builtin Light`, `Builtin Dark` |
| Catppuccin | `Catppuccin Latte`, `Catppuccin Mocha`, `Catppuccin Frappe`, `Catppuccin Macchiato` |
| Solarized | `iTerm2 Solarized Light`, `iTerm2 Solarized Dark` |
| Dracula | `Dracula` |
| Nord | `Nord`, `Nord Light` |
| Gruvbox | `Gruvbox Light`, `Gruvbox Dark` |
| TokyoNight | `TokyoNight`, `TokyoNight Day` |
| Atom One | `Atom One Light`, `Atom One Dark` |
| GitHub | `GitHub Light Default`, `GitHub Dark Default` |
| Rose Pine | `Rose Pine`, `Rose Pine Dawn` |
| Ayu | `Ayu Light`, `Ayu Mirage` |
| Everforest | `Everforest Light Med`, `Everforest Dark Med` |

### Custom palette files

TOML accepts **names only**, not paths or `.conf` extensions:

```toml
[terminal]
light_theme = "Ayu Light"
dark_theme = "My Dark"
```

Custom names resolve to `<config directory>/palettes/<name>.conf`. With the default config location, `My Dark` means `~/.config/slate-term/palettes/My Dark.conf`. If you use `SLATE_TERM_CONFIG_FILE` or CLI `--file`, the palettes folder belongs beside that config file. Names can contain spaces and Unicode; they must fit in 128 UTF-8 bytes and cannot contain path separators, colons, control characters, or start with `.` or `~`. Bundled names are reserved.

In either existing palette dropdown, choose **Select Custom Palette…**. The file picker imports the validated colors into the config's `palettes` folder, adds the resulting name to both dropdowns, and selects it in the dropdown you used. **Apply** saves that name to TOML. Canceling the picker leaves the selection unchanged. The source file is never modified; the imported copy remains available even if you Revert the selection or remove the source file.

Imports use the source filename without its extension, saved as `<name>.conf`. Importing the same named colors again reuses the copy. Different colors with the same name, or a name reserved by a bundled palette, get a suffix such as `My Dark-2`; no existing palette is overwritten. You can also place a file in the palettes folder yourself and reopen Settings or reload configuration to list it.

Custom files use a **color-only subset of Ghostty's theme format**, not TOML:

```ini
# Background and foreground are required.
background = #102a2c
foreground = #dcfce7
cursor-color = #86efac
cursor-text = #102a2c
selection-background = #235347
selection-foreground = #ffffff
palette = 0=#102a2c
palette = 1=#f87171
# Add more palette entries as desired, from 0 through 255.
```

Supported keys are `background`, `foreground`, `cursor-color`, `cursor-text`, `selection-background`, `selection-foreground`, and repeated `palette = INDEX=COLOR` assignments. Colors must be six hexadecimal digits, with an optional `#`; indices are decimal integers from 0 through 255. Unspecified colors use the renderer's defaults. Blank lines and whole-line `#` comments are accepted. Inline comments, quoted/named colors, duplicate keys or indices, and non-color settings are rejected. Files must be regular UTF-8 files no larger than 64 KiB.

Both selected palettes are validated, including the inactive mode. `slate-term config validate --file ...` resolves names and checks the files offline without importing or creating snapshots. Unknown names, paths, and invalid palette contents do not overwrite TOML when applying through Settings. On a failed reload, the live settings remain unchanged; an invalid startup configuration reports the error and falls back to defaults.

The app gives Ghostty validated, app-managed color snapshots under `state/palettes`, **never a raw user palette file**: full Ghostty themes can contain commands and other non-color options. Imports and snapshots contain normalized color assignments, without source comments. These snapshots keep the last applied palette stable even if its file changes or a later reload fails. After editing a file in the config's `palettes` folder, choose **Workspace → Reload Configuration** or run `slate-term config reload`; palette files are not watched automatically. Palette changes do not restart terminal sessions. A reload that changes the resolved colors publishes `host.appearance.changed` to plugins.

## Browser profiles

**Browser** shares one persistent website-data profile across all panes and workspaces. **Private Browser** creates a separate ephemeral store for each pane; closing or replacing it discards that store. Both use the search setting below. Workspace restoration preserves the pane kind and a normal browser's starting URL, but not its back/forward history. Private Browser URLs are never included in workspace snapshots; private panes reopen at a fresh blank page. Persistent website storage survives even when workspace restoration is disabled.

The profile's opaque WebKit identifier is kept privately at `state/browser-profile.json` under the app state directory; WebKit manages the actual profile files. Separate `SLATE_TERM_STATE_DIR` fixtures use separate profiles. Do not delete the identifier to clear data: use **Workspace → Browser → Clear Browser Data…**, also available in the command bar and configurable shortcuts. A native warning explains the effects before deleting. **Clear This Site’s Data…** works on focused Browser or Private Browser HTTP(S) pages. [Automation](automation.md#browser-profiles-and-website-data) documents precise site-group scope and noninteractive CLI/API equivalents.

Settings → Browser also provides **Clear All Browser Data…** and **Clear Site Data…**, using the same confirmed operations. For site clearing, choose an open Browser or Private Browser pane and use its URL or enter another absolute HTTP(S) URL. The selected pane determines the profile: normal panes share storage, while each private pane has its own storage. **Refresh Open Panes** updates the selector. This selector lists open panes, not an inventory of stored sites. Clearing runs immediately after confirmation and does not require **Apply**.

## Browser search

`browser.search_url` is an HTTP(S) URL template containing `{query}` in its path or query. Search text is percent-encoded before substitution. The default is `https://www.google.com/search?q={query}`. Address-bar input that looks like a URL navigates directly; other input searches. Local `file:///…` URLs, absolute paths (`/…`) and home-relative paths (`~/…`) open files directly, including paths with spaces or Unicode. HTML, images and videos use WebKit's native support; see [local-file navigation and read access](automation.md#browser-compatibility-api). Changes apply to existing browser panes.

## Reload and validation

```sh
slate-term config validate --file ~/.config/slate-term/config.toml
slate-term config get
slate-term config reload
```

Validation is offline and never modifies the file. An explicitly supplied missing file is an error; an absent default file uses defaults. `get` and `reload` connect to the app through the usual socket selection. Reload is also a registry command (`command run config.reload`) and a Workspace menu item.

The app watches both the file and its parent directory, handling in-place writes, atomic editor replacement, deletion, and recreation. Invalid edits retain the last successfully applied settings. Inspect `config get` or **Slate Terminal → Configuration & Workspace Status** for errors. Replacing the parent directory itself is not currently tracked; restart the app after doing that.

- Font family/size, text thickening, minimum contrast, cursor defaults, appearance, palettes, and keybindings update without replacing terminal surfaces or PTYs. Font sizes are finite numbers from **1 to 256 points**; minimum contrast is a finite **1–21** ratio (1 leaves colors unchanged). Text thickening uses Ghostty's native macOS font rendering.
- `light_theme` and `dark_theme` accept the [bundled palettes or custom color-only files](#terminal-palettes) above. Defaults remain Builtin Light/Dark. Auto follows macOS; `config get` reports Auto canonically as `"system"` for compatibility.
- Cursor shape and blinking are defaults: terminal programs can override them with escape sequences, and shell integration normally uses a bar at the prompt. `cursor_blink = "auto"` preserves Ghostty's default blinking and allows DEC mode 12 to control it; `on`/`off` set an explicit default (programs can still override it with DECSCUSR).
- Padding is symmetric on each axis, in whole points from **0 to 64** (Slate Terminal's supported range). Padding changes apply to **new terminals**, following the pinned engine's behavior; existing panes are not recreated. Large padding leaves less room for terminal cells in small panes.
- Shell, shell-integration, and padding changes apply to new terminals. `restartRequired` reports differences from launch settings; running shells are not killed or restarted automatically.
- `shell` names a regular executable file by absolute path, not a command with arguments. It is started as a login shell (`-l`). Spaces and quotes are supported. The pinned engine's automatic integration parser cannot safely handle dollar signs, backticks, or backslashes in an executable path: use `shell_integration = "off"` for those paths.
- Automatic integration recognizes the shell by its executable name:

  | Shell | State, cwd, exit status, command text | `terminal run`, startup commands | How Slate loads its hooks |
  | --- | --- | --- | --- |
  | zsh | yes | yes | Redirects the engine's zsh startup directory, then sources the user's `.zshenv` |
  | bash 4.4+ (for example Homebrew bash) | yes | yes | Exports `PROMPT_COMMAND` with a one-line bootstrap that runs at the first prompt, after the user's startup files, then stops exporting it |
  | bash 3.2–4.3, including Apple `/bin/bash` | yes | no: refuses with a reason | Same bootstrap; on Apple bash it also loads the engine's bash script, which the engine does not inject there |
  | fish 3.1+ | yes | yes | Starts fish with `--init-command`, which runs after `config.fish` |

  If a bash startup file replaces `PROMPT_COMMAND` instead of appending to it, the shell runs without Slate's integration. bash marks its prompts through `PS0`, `PS1` and `PS2` and re-adds those marks after other prompt hooks; a run is refused, never guessed, when they are missing or `promptvars` is off. Shells inside tmux or screen never report for the pane. fish integration is skipped for a state directory whose path contains quotes, `$`, backticks or backslashes. Hooks deliver reports from a detached helper, so a prompt never waits for a busy app.

## Shortcuts

Modifiers are `cmd`, `shift`, `alt`, and `ctrl`. Keys can be single characters or `left`, `right`, `up`, `down`, `return`, `escape`, `tab`, `space`, and `plus`. Modifier ordering and supported literal/named aliases are canonicalized. OS-owned global shortcuts remain outside the app's control. Native equivalents support shifted symbols; avoid assigning different commands to spellings that your keyboard layout maps to the same physical chord.

Default navigation shortcuts:

| Action | Shortcut | Command |
| --- | --- | --- |
| Select tab 1–9 in the current window group | ⌘1–9 | `tab.select1` … `tab.select9` |
| Next / previous tab (wraps) | ⌘⇧] / ⌘⇧[ | `tab.next` / `tab.previous` |
| Focus left / down / up / right pane | ⌃⌥H / J / K / L | `focus.left` / `focus.down` / `focus.up` / `focus.right` |
| Browser back / forward | ⌘[ / ⌘] | `browser.back` / `browser.forward` |
| Browser address bar | ⌘L | `browser.focusAddress` |
| Browser reload | ⌘R | `browser.reload` |

Navigation and site-clearing commands apply to the focused Browser or Private Browser pane. Clear Browser Data is app-wide and does not require browser focus. Selecting a tab number that does not exist does nothing.

Workspace actions are grouped into **Tabs**, **Browser**, **Split Pane**, **Focus Pane**, and **Layout** submenus. Numbered tab selection has its own submenu. The target-specific `pane.focus` and `tab.focus` commands remain available through the CLI/API rather than appearing as no-op menu items.

| Workspace action | Shortcut |
| --- | --- |
| New tab / window | ⌘T / ⌘N |
| Close pane / tab | ⌘W / ⌘⇧W |
| Split right / down | ⌘D / ⌘⇧D |
| Split left / up | ⌘⌥D / ⌘⌥⇧D |
| Focus adjacent pane | ⌘⌥← / → / ↑ / ↓ (also the H/J/K/L bindings above) |
| Maximize / restore pane size | ⌘⇧Return |
| Equalize pane areas | ⌘⇧E |
| Reload configuration | ⌘⇧R |

**Move Tab to New Window** uses the configurable ⌘⌃N binding. Fixed native menu shortcuts: **Configuration & Workspace Status** ⌘⇧,; **Reset Close Warnings** ⌘⌥,. Explicit workspace keybindings take priority over these fixed shortcuts. The former Pane menu and its ⌘⌃1–9 type-switch shortcuts have been removed.

Change pane types from the dropdown beside the type in each header. The confirmation explains that switching back cannot restore the discarded state. Its **Don’t show again** preference persists independently of close warnings; restore it with **Slate Terminal → Reset Pane Type Warnings**. Click a pane title or invoke **Rename Pane…** (`pane.rename`, bindable with no default shortcut) to open an anchored popover. Return/Rename saves; Escape, Cancel, or clicking outside cancels.

Overrides merge with the command registry's defaults. To remove a default registry shortcut:

```toml
[keybind]
"cmd+d" = "unbound"
"cmd+alt+d" = "split.right"
```

**Rename Tab…** (`tab.rename`) and **Reset Tab Name** (`tab.title.clear`) are in Workspace → Tabs, Cmd-K and shortcut settings, without default bindings. Names are workspace state, not TOML: see [tab naming and automation](layout-api.md#tab-names).

Application shortcuts run before pane input. Be careful with unmodified character bindings: they deliberately intercept normal typing. Standard macOS menu actions are separate from the registry's workspace shortcuts.

## Close warnings

[Warning preference setters](api-parity-first-pass.md#warning-preferences) provide strict Boolean `warnings.close.set` / `warnings.type.set` commands and `slate-term warnings close|type --suppressed true|false`. Existing reset commands remain supported; these preferences never waive API `force` requirements.

The native termination dialog includes **Don’t ask again**. Checking it and choosing **Terminate** suppresses subsequent close/quit prompts for this app state directory, including after restart. Choosing **Cancel** does not save the checkbox. **Slate Terminal → Reset Close Warnings** restores prompting.

This preference is stored privately in `state/suppress-close-warning.json`, separately from TOML and workspace restoration. Missing or unreadable preferences default to showing warnings; read errors appear in configuration status. CLI/API destructive commands still require `--force` when a process may be running, regardless of this UI preference. Pane-type replacement remains immediate; only the disabled menu explanation was removed.

## Workspace files

The app saves the validated model to:

```
~/Library/Application Support/SlateTerm/state/workspace.json
```

The state directory is private (0700); snapshots have mode 0600 and are replaced atomically. `SLATE_TERM_STATE_DIR` changes the base directory. Autosave follows model mutations, focus, divider changes, and native tab-group changes.

Restoration preserves pane/tab/group IDs, counters, tab order, split trees/fractions, focus history, optional manual tab names, and each pane's `headerVisible` setting. Missing/null tab `manualTitle` means the default `Slate Terminal`; noncanonical/invalid non-null names reject the snapshot rather than silently rewriting it. Old snapshots without that field default to shown; non-Boolean values (including null) are rejected. Visibility follows the pane slot through moves, zoom/restore and type changes. Newly created panes start with their bar shown. Use Workspace → Show Pane Bar or Search Commands to recover a hidden bar; show/hide/toggle are bindable commands with no default shortcut. Hiding cancels an open rename draft without saving; show the bar first to use native rename/type/move controls. Programmatic title changes work while hidden. It starts **new shell processes** in the last observed working directories (home if a saved directory has disappeared or is inaccessible). It also restores normal-browser starting URLs and windowed frames per tab group, fitting frames to currently connected screens. It does **not** replay startup commands, persist terminal output, restore live processes, private-browser URLs, back/forward stacks, full-screen mode, or minimization. URLs use the existing safe browser schemes, never executable JavaScript or embedded credentials. A missing local page reports the normal browser loading error. Location changes and window movement/resizing coalesce saves at 250 ms; ordinary workspace changes and orderly quit also save. Abrupt termination can lose the most recent unflushed changes. Runtime metadata is saved atomically with topology in the same private snapshot, not in saved-layout recipes. Invalid metadata or unavailable registered pane types suspend restoration rather than silently replacing the original file. `api.describe.workspaceRestoration` advertises these semantics to CLI, pages, and services; `config.get.workspace` reports persistence failures. No separate save/restore command or shortcut is added: the existing `layout.restore_workspace` preference controls all clients and native operations.

Closing the last window leaves the app running. **New Window** (⌘N) and **New Tab** (⌘T) remain available without a terminal window, including from Settings. Clicking the Dock icon reopens a workspace window. If the saved workspace is empty at launch, the app opens one fresh terminal while preserving the saved identity counters.

Plugin panel identity, saved view state and starting configuration also live in the workspace snapshot (schema 2). Shared plugin data is stored separately and survives panel closure, unregister and restoration being disabled. Old development workspace schemas are rejected/preserved; to start fresh, move `state/workspace.json` aside while Slate is stopped. Old instance-scoped data files remain untouched/unused. See [plugin persistence](plugin-persistence.md).

With `restore_workspace = false`, the app neither loads nor overwrites the existing snapshot. Re-enabling it begins saving the current workspace; it does not replace the live workspace with the old file.

A corrupt or incompatible startup snapshot is preserved unchanged. The app opens a recovery workspace with autosave suspended and reports the error. Repair or move the old file and restart to resume normal restoration. Do not edit a healthy snapshot while the app is running.

Autosave is best effort. An in-memory command can succeed when a filesystem write fails; the app's status menu and `config get` → `workspace.error` report that failure. Built-in workspace mutation replies also report a path-free `workspacePersistence` status: `saved`, `failed`, `disabled`, `suspended`, or `notRequired` for registry-only work. Model acceptance and published events are not rolled back after an autosave failure; do not replay a mutation just because its save failed. The reply captures its own save result even if a separate native editor completion saves again before the reply is sent. A single-writer file lock rejects concurrent app instances sharing one state directory; use separate state directories for independent instances. The lock releases on process exit, including an abrupt exit. Atomic replacement protects readers from partial JSON; power-loss durability is not guaranteed.
