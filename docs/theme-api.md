# Theme API for plugins

Status: **implemented.** The [plugin UI kit](../skills/slate-terminal/references/ui/INDEX.md) uses this contract. Outside Slate Terminal, `slate-theme.js` falls back to `prefers-color-scheme` and the defaults in `slate.css`. The implementation plan below is kept as a record of the design.

## Goal

Plugin pages and other trusted clients can read the terminal's resolved colors and font, and learn when they change. A page that uses the design system then follows palette and light/dark changes without code of its own.

## Before this API

- `config.get` returns palette **names** (`terminal.light_theme`, `terminal.dark_theme`) and `appearance.theme` (`system`, `light` or `dark`). It returns no colors and not the effective light/dark state.
- `palette.list` lists names and validity. `palette.import` and `terminal.palette.set` change palettes.
- Bundled palettes are never parsed; their Ghostty theme files are passed to the renderer. Custom `.conf` palettes are validated but stored only as normalized source text.
- Ghostty chooses the active palette from the system appearance. `WorkspaceHost` observes `NSApp.effectiveAppearance`, but this only updates Ghostty; nothing is published.
- `host.settings.changed` fires after config applies, without changed keys. Nothing fires when the system appearance flips in Auto mode, and custom palette files are not watched.
- Plugin web views get no theme styling. They show WebKit's default white background until the page paints.

## Contract

### `appearance.get` (read)

Public catalog method. Available to the CLI (`slate-term appearance get`), the socket, services and the page bridge (`workspace.call("appearance.get")`).

```json
{
  "revision": "7f3a…",
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

- `setting` is `system`, `light` or `dark`, matching `config.get` (the CLI calls `system` "auto").
- `systemAppearance` is `null` unless `setting` is `system`, because AppKit reports the forced appearance while one is set.
- `slot` is the configured palette slot in use (`light` or `dark`), resolved from `setting` and `systemAppearance`.
- `tone` is the palette's own lightness, derived from the background's relative luminance. Styling must use `tone`, not `slot`, because a user can put a dark palette in the light slot.
- `palette` contains the **resolved** colors as lowercase `#rrggbb`, before `minimumContrast` adjustment. They come from the applied palette files; see the implementation plan.
- `revision` is an opaque string that changes when any field changes, like settings revisions elsewhere. A no-op apply does not change it. Clients compare it only for equality.
- The result contains no paths or other configuration.

### `host.appearance.changed` (event)

A host event published after the effective theme changes. The host detects changes by comparing whole appearance snapshots, not by watching config keys. A reload re-resolves edited palette files even when no key changes, so this also covers in-place palette edits followed by a reload. Causes include an appearance setting change, a system light/dark flip in Auto mode, a palette slot change, a config reload that changes resolved colors, and a terminal font family or size change.

- Payload: `{ "revision": "9c1e…", "tone": "light", "slot": "light" }`. Clients re-read `appearance.get` rather than treating the event as a snapshot, following [events](events.md).
- Untargeted and global, so every tab's plugin instances and services receive it.
- Publish once per effective change, coalescing a burst such as a reload that also flips the slot.

### Page integration

1. **Document-start injection (recommended).** The host adds a user script to registered plugin views. It sets the `--st-*` variables from the [design system](../skills/slate-terminal/references/ui/slate.css) plus `data-appearance` and `color-scheme` on `<html>`, before the page's own scripts run. On a change, the host re-runs it in each live plugin view. Pages then need no theme code, and there is no flash of the wrong colors.
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
| `--st-font-mono` | `font.family`, followed by `ui-monospace` and other fallbacks (WebKit cannot address the default "SF Mono" by name) |
| `--st-font-mono-size` | `font.size - 1` px, clamped to 10–16 |

Semantic tokens such as `--accent` and `--surface` are **not** host contract. They live in `slate.css`, so the design system can evolve without host changes.

## Implementation plan

Each phase is a separate, reviewable PR. Paths are relative to the repository root.

Naming: `appearance.get` is an RPC method, while `appearance.set`, `light`, `dark` and `auto` are `command.run` ids. Both coexist; document the split in `docs/automation.md`.

### P1. Palette colors from Slate's own settings

Slate writes the terminal config itself (`theme = light:…,dark:…`) and chooses the light or dark slot, so it already knows every color input. It reads the palette files directly; it does not query Ghostty.

- In `Sources/SlateTermSettings/TerminalPalette.swift`, add a `TerminalColors` value with background, foreground, cursor, cursor text, selection colors and 16 ANSI entries. `TerminalPalette.parse` already accepts every key used by the bundled theme files.
- Let `ResolvedTerminalPalette` return colors for bundled themes by loading the bundled file. All 725 bundled themes define every one of these keys.
- Custom palettes may omit keys. Fill gaps with fixed fallbacks: cursor = fg, cursorText = bg, selection = fg on bg, and Ghostty's default ANSI table for missing entries. Document that these approximate what the terminal draws.
- Keep the palettes that were actually applied: store them on `PreparedConfiguration` and expose `ApplicationSettings.appliedPalettes`, set in init and after each successful reload (`Native/ApplicationSettings.swift`). Do not re-read files on demand, or the result can drift from the applied config until the next reload.
- Add an `AppearanceSnapshot` (Equatable, Encodable) whose `tone` comes from the background's WCAG relative luminance (light above 0.179).
- Tests: a dark palette in the light slot reports `tone: "dark"`; every bundled theme parses completely (skip when the built themes directory is absent); a custom palette with missing keys gets the fallbacks.

### P2. `appearance.get`

- `Sources/SlateTermCore/AutomationAPI.swift`: add `case appearanceGet = "appearance.get"`, family `.synchronous`, admission `.read`, and the case in the exhaustive `resolving` switch.
- New `Native/AppearanceAPI.swift` with `appearanceInfo()`, dispatched in `Native/WorkspaceHost.swift` next to `.paletteList`.
- Discovery: an `appearance` descriptor in `describeAPI` (`Native/WorkspaceAPI.swift`) with the event topic and the injected variable names.
- CLI: a `get` action on the existing `AppearanceCLI` (`Sources/SlateTermCLI/SettingsCLI.swift`), calling `appearance.get`, with `--json`.
- Tests: the method name lists in `AutomationAPITests` and `AdmissionClassificationTests`; the CLI literal scan in `AutomationAliasesTests` then covers the CLI; an integration check that the CLI result equals `workspace.call("appearance.get")` through `debug.pluginEval`.

### P3. `host.appearance.changed`

- An `AppearanceTracker` in the host keeps the last snapshot and revision. `refreshAppearance()` builds a snapshot and, when it differs, updates the revision and publishes the event untargeted through `events.publishHost` (`Native/EventControl.swift`).
- `scheduleAppearanceRefresh()` coalesces a burst into one main-queue refresh. Call it from `updateTerminalAppearance` (which runs on system light/dark flips through the `effectiveAppearance` observation) and the end of `applyConfiguration`. Setting `NSApp.appearance` re-fires the appearance observation, so one apply is already a burst.
- `appearance.get` refreshes synchronously first, so a read right after `config.patch` is never stale.
- Confirm that untargeted host events reach services as well as plugin instances.
- Tests: a no-op apply publishes nothing; a burst publishes once; Auto to light to dark publishes one event per step.

### P4. Page integration

- `Native/PluginPane.swift`: split `installBridgeScripts` into `invalidateDocument()` and `installUserScripts()`, so a theme update does not retire the live document or the bridge token.
- Add a theme `WKUserScript` at document start, main frame only, in the bridge's isolated world, behind the existing origin guard. It sets the `--st-*` variables, `data-appearance` and `color-scheme` on `<html>`.
- `apply(appearance:)` sets `underPageBackgroundColor`, reinstalls the user scripts for future loads, and runs the same script in the live main frame. The host calls it at pane creation and on every change, iterating `PluginPane` leaves only, which excludes browser panes by construction.
- Bridge helpers: `workspace.appearance.get()` and `workspace.appearance.onChange(handler)`.
- Tests through `debug.pluginEval`: `--st-bg` before and after a change; a browser pane and a subframe get no variables.

### P5. Docs and verification

- Mark this document implemented. Update `docs/automation.md`, `docs/control.md`, `docs/events.md` (native topics), `docs/plugins.md` (injection and helpers), `docs/configuration.md` (a reload can emit the event), `docs/api-extension-progress.md` and `design-system/README.md`.
- Add `scripts/verify-theme-api.py`, registered in `scripts/verify-all.sh` and `scripts/verification-manifest.py`. It drives the GUI, so run it sequentially and only with agreement.

### Risks

- Fallback colors for incomplete custom palettes can differ slightly from what Ghostty draws. If exact values matter later, read them from Ghostty's app-level config-change action, which carries the slot-applied config; `ghostty_config_get` alone cannot return cursor or selection colors.
- Reinstalling user scripts must not touch the bridge token or document generation.

## Open questions

- Should the payload include the native chrome colors (header, separator) for plugins that want to match the pane header rather than the terminal?
- Palette files edited in place are picked up on the next reload, through snapshot comparison. Live file watching stays out of scope, as `configuration.md` says.
