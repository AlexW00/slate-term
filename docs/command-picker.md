# Command picker

Press **⌘K**, or choose **Workspace → Search Commands…**. The picker uses native AppKit **Liquid Glass** (`NSGlassEffectView`), not a web overlay or a simulated blur. It follows the app's light/dark appearance and native material accessibility behavior. It is attached to and centered inside the invoking window's visible content area, follows window movement, and re-centers/fits when resized. It dismisses if the visible content area becomes too small for the controls (below 352×300 points). With no window open, it uses a screen-centered fallback.

## Included

- Search built-in workspace/application actions and registered plugin commands by title, command ID, category, or keywords. Case, diacritics, multiple words, and abbreviated subsequences are supported; title matches rank ahead of metadata.
- Use **↑ / ↓** to select and **Return** to execute. A first click selects a result; a second click on that same result executes it (no double-click timing requirement). Editing the query or navigating with the keyboard resets that mouse activation. Configured command shortcuts also execute against the captured context and dismiss the picker. **Escape** and the picker shortcut dismiss it. Clicking outside or deactivating the app dismisses it too.
- View configured shortcut hints and a secondary category/plugin label. Commands with missing context, absent numbered tabs, stale targets, or an already-running invocation are hidden, not shown as disabled rows.
- Read an explicit empty state instead of an empty list. Plugin registration/unregistration and running-command availability update while the picker is open.
- Preserve the invoking pane/tab for execution. Background CLI changes do not silently redirect the selected command. Closing a captured pane hides its dependent actions; window creation and application actions remain available. Closing the owner window dismisses the attached picker.
- Restore the original valid workspace/editor focus on dismissal. Normal close/type-change safeguards remain host-owned; the picker does not add `force` or bypass confirmation.
- **Copy Pane ID** (`pane.copyID`) replaces the former header copy button. It copies the captured pane's identifier without changing focus or layout; it is also available in Workspace and shortcut settings, with no default binding.
- **Rename Pane…** (`pane.rename`, no default binding) opens a title-anchored popover, also available by clicking a pane title or from Workspace. Return/Rename saves; Escape, Cancel, or clicking outside discards the draft. An empty name restores the automatic title.
- **Maximize Pane** / **Restore Pane Size** reflects the captured tab's current state. The `pane.zoom` ID, shortcut and behavior are unchanged.
- Open Settings through the shared command system (`settings.open`, default **⌘,**). **⌘W** closes Settings without invoking a pane-close command (unless a shortcut recorder is actively recording the chord).

The picker opens and filters instantly, without animated keyboard transitions. There are no usage-history files, pinned actions, AI commands, shell-input interpretation, or OS-wide shortcuts. Actions requiring additional parameters (`pane.type`, `pane.focus`, `tab.focus`) stay in their existing UI/CLI surfaces rather than being listed as broken one-click actions. Ordinary numbered-tab and directional-focus commands remain available.

## Configuration and automation

`command.picker` and `settings.open` are ordinary host commands. Rebind them in **Settings → Keyboard Shortcuts**, or in TOML:

```toml
[keybind]
"cmd+k" = "unbound"
"cmd+shift+k" = "command.picker"
```

```sh
slate-term command run command.picker
slate-term command run settings.open
```

Explicit CLI pane/tab targeting determines the picker's command context. With no workspace open, create-window/tab and application/plugin commands still work; workspace-dependent actions are hidden. Plugin commands come from their manifest and use the same runtime, captured context, timeout, logging, and error behavior as direct CLI/shortcut invocation.

## Verification

`CommandSearchTests` cover search/ranking; `scripts/verify-command-picker.py` drives the actual native picker, text input, selection, execution, mouse path, context/focus, live catalog and running states, shortcuts, windowless use, and light/dark captures. Captures live in ignored `artifacts/command-picker-*.png`; context captures include only the app-owned workspace region.

A full VoiceOver/IME and multi-display manual audit is still required. Marked-text composition is left to the native input method rather than intercepted as navigation. Native material behavior under OS accessibility settings should be manually checked alongside the other release accessibility work.
