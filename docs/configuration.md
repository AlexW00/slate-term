# Configuration and restoration

Slate Terminal reads `~/.config/slate-term/config.toml`. A missing file uses defaults. `SLATE_TERM_CONFIG_FILE` can select a different file for an app instance.

```toml
[appearance]
theme = "auto" # auto (follow macOS), light, dark; "system" is also accepted

[terminal]
shell = "/bin/zsh"
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

[layout]
restore_workspace = true

[keybind]
"cmd+d" = "split.right"
"cmd+shift+d" = "split.down"
```

These tables and `[plugins.<id>]` settings are supported currently. Unknown keys, built-in commands, and duplicate canonical shortcut spellings are errors rather than silently ignored settings. Well-formed `plugin.<plugin-id>.<command-id>` bindings are retained even when their plugin is unavailable; unavailable commands do not intercept keys. See [plugin commands and settings](plugins.md#shortcuts-and-settings).

## Settings window

Open **Slate Terminal → Settings…** (⌘,) for native General, Appearance, Terminal, Browser, Keyboard Shortcuts, and Plugins sections. **Apply** validates and saves changes to the config file; **Revert** discards pending edits. External edits reload automatically when there are no pending GUI changes. If the file changes while you edit, Settings asks you to revert before saving.

The editor preserves comments and unrelated values in standard tables and dotted assignments. Inline tables and multiline values must currently be edited in the file. Invalid files are never overwritten by the settings editor.

**Appearance** contains the Light / Dark / Auto switcher and terminal palettes. **Terminal** contains font, contrast, cursor, padding, and shell controls. All controls save the same TOML keys shown above; choose **Apply** to save changes.

Register plugins and view their live status directly in **Settings → Plugins**. You or an agent can also run `slate-term plugins register --manifest /path/to/plugin.json`. Plugin registrations remain in the separate plugin catalog.

**Keyboard Shortcuts** lists each action with one editable shortcut and a **Reset** button. Click the shortcut and press a replacement key combination. Escape cancels recording; Delete clears the binding. Reset restores the action's default shortcut. Assigning or resetting replaces that action's existing bindings. Conflicts are rejected without changing either action. Use **Apply** to save.

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

The app gives Ghostty validated, app-managed color snapshots under `state/palettes`, **never a raw user palette file**: full Ghostty themes can contain commands and other non-color options. Imports and snapshots contain normalized color assignments, without source comments. These snapshots keep the last applied palette stable even if its file changes or a later reload fails. After editing a file in the config's `palettes` folder, choose **Workspace → Reload Configuration** or run `slate-term config reload`; palette files are not watched automatically. Palette changes do not restart terminal sessions.

## Browser search

`browser.search_url` is an HTTP(S) URL template containing `{query}` in its path or query. Search text is percent-encoded before substitution. The default is `https://www.google.com/search?q={query}`. Address-bar input that looks like a URL navigates directly; other input searches. Changes apply to existing browser panes.

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
- Automatic integration depends on the engine's shell support. In particular, it intentionally does not inject integration into Apple's `/bin/bash`. Production-path zsh is covered by the runtime gate; other shells are not yet independently verified.

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

Browser commands apply only to the focused browser pane. Selecting a tab number that does not exist does nothing.

Workspace actions are grouped into **Tabs**, **Browser**, **Split Pane**, **Focus Pane**, and **Layout** submenus. Numbered tab selection has its own submenu. The target-specific `pane.focus` and `tab.focus` commands remain available through the CLI/API rather than appearing as no-op menu items.

| Workspace action | Shortcut |
| --- | --- |
| New tab / window | ⌘T / ⌘N |
| Close pane / tab | ⌘W / ⌘⇧W |
| Split right / down | ⌘D / ⌘⇧D |
| Split left / up | ⌘⌥D / ⌘⌥⇧D |
| Focus adjacent pane | ⌘⌥← / → / ↑ / ↓ (also the H/J/K/L bindings above) |
| Toggle pane zoom | ⌘⇧Return |
| Equalize pane areas | ⌘⇧E |
| Reload configuration | ⌘⇧R |

Fixed native menu shortcuts: **Terminal / Browser type** ⌘⌃1 / ⌘⌃2; **Move Tab to New Window** ⌘⌃N; **Configuration & Workspace Status** ⌘⇧,; **Reset Close Warnings** ⌘⌥,. Registered pane types receive the remaining ⌘⌃3–9 slots in menu order; additional types remain available through the menu. Explicit workspace keybindings take priority over these fixed shortcuts.

Pane types can also be changed from the dropdown beside the type in each header. The confirmation explains that switching back cannot restore the discarded state. Its **Don’t show again** preference persists independently of close warnings; restore it with **Slate Terminal → Reset Pane Type Warnings**. Rename a pane only by clicking its title once and editing inline.

Overrides merge with the command registry's defaults. To remove a default registry shortcut:

```toml
[keybind]
"cmd+d" = "unbound"
"cmd+alt+d" = "split.right"
```

Application shortcuts run before pane input. Be careful with unmodified character bindings: they deliberately intercept normal typing. Standard macOS menu actions are separate from the registry's workspace shortcuts.

## Close warnings

The native termination dialog includes **Don’t ask again**. Checking it and choosing **Terminate** suppresses subsequent close/quit prompts for this app state directory, including after restart. Choosing **Cancel** does not save the checkbox. **Slate Terminal → Reset Close Warnings** restores prompting.

This preference is stored privately in `state/suppress-close-warning.json`, separately from TOML and workspace restoration. Missing or unreadable preferences default to showing warnings; read errors appear in configuration status. CLI/API destructive commands still require `--force` when a process may be running, regardless of this UI preference. Pane-type replacement remains immediate; only the disabled menu explanation was removed.

## Workspace files

The app saves the validated model to:

```
~/Library/Application Support/SlateTerm/state/workspace.json
```

The state directory is private (0700); snapshots have mode 0600 and are replaced atomically. `SLATE_TERM_STATE_DIR` changes the base directory. Autosave follows model mutations, focus, divider changes, and native tab-group changes.

Restoration preserves pane/tab/group IDs, counters, tab order, split trees/fractions, and focus history. It starts **new shell processes**: no command replay, terminal-output restoration, or working-directory/window-geometry restoration is implemented yet. Unknown web/view types retain their IDs and layout as placeholders. Registration and placeholder resolution belong to the subsequent plugin phase.

Closing the last window leaves the app running. **New Window** (⌘N) and **New Tab** (⌘T) remain available without a terminal window, including from Settings. Clicking the Dock icon reopens a workspace window. If the saved workspace is empty at launch, the app opens one fresh terminal while preserving the saved identity counters.

With `restore_workspace = false`, the app neither loads nor overwrites the existing snapshot. Re-enabling it begins saving the current workspace; it does not replace the live workspace with the old file.

A corrupt or incompatible startup snapshot is preserved unchanged. The app opens a recovery workspace with autosave suspended and reports the error. Repair or move the old file and restart to resume normal restoration. Do not edit a healthy snapshot while the app is running.

Autosave is best effort. An in-memory command can succeed when a filesystem write fails; the app's status menu and `config get` → `workspace.error` report that failure. A single-writer file lock rejects concurrent app instances sharing one state directory; use separate state directories for independent instances. The lock releases on process exit, including an abrupt exit. Atomic replacement protects readers from partial JSON; power-loss durability is not guaranteed.
