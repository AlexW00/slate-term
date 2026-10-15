# Theme API for plugins (proposal)

Status: **proposed, not implemented.** The [plugin design system](../design-system/INDEX.md) already targets this contract. Until the host implements it, `slate-theme.js` falls back to `prefers-color-scheme` and the defaults in `slate.css`.

## Goal

Plugin pages and other trusted clients can read the terminal's resolved colors and font, and learn when they change. A page that uses the design system then follows palette and light/dark changes without code of its own.

## What exists today

- `config.get` returns palette **names** (`terminal.light_theme`, `terminal.dark_theme`) and `appearance.theme` (`system`, `light` or `dark`). It returns no colors and not the effective light/dark state.
- `palette.list` lists names and validity. `palette.import` and `terminal.palette.set` change palettes.
- Bundled palettes are never parsed; their Ghostty theme files are passed to the renderer. Custom `.conf` palettes are validated but stored only as normalized source text.
- Ghostty chooses the active palette from the system appearance. `WorkspaceHost` observes `NSApp.effectiveAppearance`, but this only updates Ghostty; nothing is published.
- `host.settings.changed` fires after config applies, without changed keys. Nothing fires when the system appearance flips in Auto mode, and custom palette files are not watched.
- Plugin web views get no theme styling. They show WebKit's default white background until the page paints.

## Proposed contract

### `appearance.get` (read)

Public catalog method. Available to the CLI (`slate-term appearance get`), the socket, services and the page bridge (`workspace.call("appearance.get")`).

```json
{
  "revision": 14,
  "tone": "dark",
  "systemAppearance": "dark",
  "setting": "system",
  "slot": "dark",
  "paletteName": "Catppuccin Mocha",
  "palette": {
    "background": "#1e1e2e",
    "foreground": "#cdd6f4",
    "cursor": "#f5e0dc",
    "cursorText": "#1e1e2e",
    "selectionBackground": "#f5e0dc",
    "selectionForeground": "#1e1e2e",
    "ansi": ["#45475a", "#f38ba8", "…16 entries"]
  },
  "font": { "family": "SF Mono", "size": 13 },
  "minimumContrast": 1
}
```

- `slot` is the configured palette slot in use (`light` or `dark`), resolved from `setting` and `systemAppearance`.
- `tone` is the palette's own lightness, derived from the background's relative luminance. Styling must use `tone`, not `slot`, because a user can put a dark palette in the light slot.
- `palette` contains the **resolved** colors as lowercase `#rrggbb`. Bundled palettes are parsed from the bundled theme files, and unspecified slots are filled with the renderer's defaults. The values must match what the terminal draws. Reading them back through `ghostty_config_get` is one way to guarantee that.
- `revision` increases when any field changes. A no-op apply does not increase it.
- The result contains no paths or other configuration.

### `host.appearance.changed` (event)

A host event published after the effective theme changes. Causes include an appearance setting change, a system light/dark flip in Auto mode, a palette slot change, a config reload that changes resolved colors, and a terminal font family or size change.

- Payload: `{ "revision": 15, "tone": "light", "slot": "light" }`. Clients re-read `appearance.get` rather than treating the event as a snapshot, following [events](events.md).
- Untargeted and global, so every tab's plugin instances and services receive it.
- Publish once per effective change, coalescing a burst such as a reload that also flips the slot.

### Page integration

1. **Document-start injection (recommended).** The host adds a user script to registered plugin views. It sets the `--st-*` variables from the [design system](../design-system/slate.css) plus `data-appearance` and `color-scheme` on `<html>`, before the page's own scripts run. On a change, the host re-runs it in each live plugin view. Pages then need no theme code, and there is no flash of the wrong colors.
2. **Web view background.** Set the plugin web view's under-page background to the palette background, so loading and overscroll do not flash white.
3. **Bridge helper.** Add `workspace.appearance.get()` and `workspace.appearance.onChange(handler)` as a thin wrapper over the method and event, for canvas and chart code.

With step 1, `slate-theme.js` becomes a fallback: it keeps working for pages that are not plugins and for hosts without injection.

The injected variable names are part of the contract:

| Variable | Source |
| --- | --- |
| `--st-bg`, `--st-fg` | `palette.background`, `palette.foreground` |
| `--st-cursor` | `palette.cursor` |
| `--st-selection-bg`, `--st-selection-fg` | `palette.selectionBackground`, `palette.selectionForeground` |
| `--st-ansi-0` … `--st-ansi-15` | `palette.ansi` |
| `--st-font-mono` | `font.family`, followed by monospace fallbacks |
| `--st-font-mono-size` | `font.size - 1` px, clamped to 10–16 |

Semantic tokens such as `--accent` and `--surface` are **not** host contract. They live in `slate.css`, so the design system can evolve without host changes.

## Implementation notes

- Add `appearance.get` to `AutomationMethod` with `.read` admission and the `appearance` family. Add CLI `appearance get [--json]`, discovery metadata and parity tests across CLI, socket and bridge, as required by `AGENTS.md`.
- Parse palettes into a typed model: `TerminalPalette` already validates the keys; extend it to parse bundled theme files too.
- Publish the event from `applyAppearance`, the `effectiveAppearance` observation, and the settings apply path when `changedKeys` includes `appearance.theme`, `terminal.light_theme`, `terminal.dark_theme`, `terminal.font_family` or `terminal.font_size`.
- Test: CLI and bridge results agree; Auto mode flips publish one event; no-op applies publish none; a dark palette in the light slot reports `tone: "dark"`; injection runs only in registered plugin main frames, never in browser panes.

## Open questions

- Should a palette file edited in place trigger the event? This needs palette file watching, which `configuration.md` currently excludes.
- Should the payload include the native chrome colors (header, separator) for plugins that want to match the pane header rather than the terminal?
