# Design guidelines for plugin panes

Plugin pages run inside a pane next to terminals. People glance at them while they work, often in a narrow split. Design for that context. These rules are defaults; the user's instructions win.

## Character

- Quiet, practical and native-feeling, like a small macOS utility. Not a web app and not a landing page.
- The content is the interface. Chrome stays thin and neutral.
- Beautiful through alignment, spacing and type, not through decoration. No gradients, glows, illustrations or decorative cards.

## Fit the pane

- The native pane header already shows the plugin name and a close button. Do not repeat a title inside the page. Use `workspace.setTitle()` for context such as the current file.
- Fill the pane edge to edge with the page background. No outer margins, centered max-width columns or floating cards around the whole page.
- Only the main content area scrolls. Toolbars and status bars stay fixed. Start from the pane shell.
- Panes can be 280px wide or fill a large display. Check 340px, 560px and full width. Use container queries, so layouts react to the pane rather than the window.
- At narrow widths, drop columns and secondary metadata first. Turn a sidebar into push navigation. Never scroll the page horizontally; truncate with an ellipsis instead.

## Density and spacing

- Use macOS sizes: 13px body text, 24px controls, 28px compact rows and 40px two-line rows.
- Use the 4px spacing scale. Most gaps are 8px or 12px, and section gaps are 16px or 24px.
- Separate regions with one hairline (`--separator`) or a background step, not both. Avoid borders inside borders.
- Align on one left edge. Text in rows, headers and groups shares the same inset.

## Text and copy

- Write less. A pane is not documentation. Labels are one to three words. Buttons are verbs, such as "Run" or "Delete Branch".
- No explainer paragraphs, no helper text under every field and no tooltips that restate the label. Add a caption only when the label alone is ambiguous.
- Use tooltips (`title`) only to name icon-only buttons.
- Empty states get one line saying what to do, plus at most one button.
- Errors say what happened and what to do next, in one sentence each.
- Use sentence case for headings and labels, and title case for buttons and menu items, as in macOS.
- Show data in the terminal font (`--font-mono`): paths, commands, IDs, hashes and log lines. Everything else uses the system font.

## Color

- Use the semantic tokens from `slate.css` only. Never hard-code a color. Every color derives from the terminal palette, so the plugin follows the user's theme and light or dark mode.
- Color carries meaning, not decoration. Accent marks selection, the primary action and focus. Success, warning and danger mark state.
- Most of the page is `--bg`, `--text` and `--text-secondary`. If a view is full of accent color, it is too loud.
- Pair status color with text or an icon. Color is never the only signal.
- Use tints (`--accent-tint`, `--danger-tint`) for backgrounds. Use solid accent only for the primary button and menu highlight.
- For charts and canvas, read colors from `SlateTheme.current` or `getComputedStyle`. Redraw in `SlateTheme.onChange`.

## Hierarchy

- Build hierarchy with weight and color before size. Most text is 13px or 12px. Use 15px semibold at most once per view.
- One primary button per view at most. Many views need none.
- Put actions near what they affect. Pane-wide actions go in the toolbar, and item actions go in the row or the detail view.
- Keep the toolbar to about five controls. Move rare actions into a menu.

## Interaction

- Interaction should feel instant. Do not animate keyboard actions, list selection, menus, tab switches or data refreshes.
- Use short transitions (120 to 200ms, ease-out) only for state changes such as switches, disclosure chevrons and dialogs. Respect `prefers-reduced-motion`.
- Support the keyboard. Arrow keys move through lists, Return opens and Escape closes. Keep focus rings visible with `:focus-visible`.
- Show feedback on press, not after the round trip. Keep stale data visible while refreshing and show a spinner in the toolbar.
- Ask for confirmation only for destructive, irreversible actions. Prefer undo.
- Text that people may copy, such as paths, output and IDs, stays selectable. Chrome text does not.

## Custom components

When no recipe fits, build one that looks like it belongs. First look at the existing components for inspiration, and reuse their structure, tokens, spacing, states and keyboard patterns so the new piece feels like part of the same set.

1. Compose from existing controls and tokens before writing new CSS.
2. Reuse the shapes: `--radius` for controls, `--radius-lg` for groups and `--control-height` for anything clickable.
3. Use `--fill` and `--fill-hover` for interactive backgrounds, and `--surface` for grouped areas.
4. Prefix classes with the plugin's own prefix, not `st-`, so later copies of recipes do not collide.
5. Check the result against a light and a dark palette, at narrow and wide pane sizes.

## Before finishing

- [ ] No hard-coded colors; changing the terminal palette restyles everything.
- [ ] Works at 340px wide without horizontal scrolling.
- [ ] No title repeated inside the page, and no explanatory paragraphs.
- [ ] Every icon-only button has `aria-label` and `title`.
- [ ] Keyboard works for the main flow, and focus is visible.
- [ ] Empty, loading and error states exist and are one line each.
