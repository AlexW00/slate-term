# Slate plugin UI

An optional design system for Slate Terminal panel plugins. It makes plugin pages look like part of the app and follow the user's terminal palette. Use it when the user has not asked for a different visual style. Their instructions and their own design skills take precedence.

It is a set of copyable files, not a package. Copy what you need into the plugin and edit freely.

## Start here

1. Read [guidelines.md](guidelines.md). It is short and covers layout, density, copy and color.
2. Copy [slate.css](slate.css) and [slate-theme.js](slate-theme.js) into the plugin directory unchanged.
3. Start from [the starter page](components/templates/starter.html), or the [pane shell](components/patterns/pane-shell.html) for a blank frame.
4. Copy the recipes you need from the table below. Each file's header says when to use it and what to avoid.
5. For anything custom, first study the closest existing components and reuse their structure, tokens, spacing, states and keyboard patterns. Then build it from the tokens in `slate.css` and follow the guidelines.

Inside Slate Terminal, the host injects the palette variables before page scripts run and updates them on change. `slate-theme.js` also reads `appearance.get`, follows `host.appearance.changed`, and exposes `SlateTheme.current` for canvas or chart code. Outside the host, pages follow the system light or dark setting with default colors.

## Files

| File | Purpose |
| --- | --- |
| `slate.css` | Palette input variables, semantic tokens, base styles and controls. Required. |
| `slate-theme.js` | Writes the live terminal palette into the CSS variables and follows changes. Required. |
| `guidelines.md` | Design rules for plugin panes. |
| `components/controls/` | Markup for controls styled by `slate.css`. |
| `components/patterns/` | Self-contained patterns: a `<style>` block, markup and, sometimes, a short script. |
| `components/templates/` | Complete pages to start from. |

## Components

Each file's header comment holds its full guidance.

<!-- components:start -->
### Controls

| Component | Summary |
| --- | --- |
| [Badge and status dot](components/controls/badge.html) | Short status labels and colored dots, tinted from the terminal's ANSI colors. |
| [Button](components/controls/button.html) | Quiet filled default, plus primary, danger, plain, icon and small variants. |
| [Checkbox and switch](components/controls/checkbox-switch.html) | Accent-tinted native checkbox and radio, and a switch for settings that apply immediately. |
| [Keyboard hint](components/controls/kbd.html) | Shortcut keys shown beside an action or in a footer. |
| [Meter and sparkline](components/controls/meter.html) | Small inline level bar and trend line for per-row numbers such as CPU, memory or duration. |
| [Spinner and progress](components/controls/progress.html) | Indeterminate spinner and determinate progress bar. |
| [Segmented control](components/controls/segmented.html) | Two to four mutually exclusive options, such as views or filters. |
| [Select](components/controls/select.html) | Native select restyled to match fields. |
| [Text field](components/controls/text-field.html) | Single-line input, search field, monospace field and textarea. |

### Patterns

| Component | Summary |
| --- | --- |
| [Banner](components/patterns/banner.html) | Inline message at the top of the content for errors, warnings and important state. |
| [Bulk selection](components/patterns/bulk-selection.html) | Multi-select list whose toolbar switches to a selection count, a few actions and Done. |
| [Code and diff](components/patterns/code-view.html) | Monospace code with a line-number gutter, unified or side-by-side diff, hunk headers and a target line. |
| [Confirmation dialog](components/patterns/dialog.html) | Small modal for destructive or irreversible actions, using the native dialog element. |
| [Disclosure](components/patterns/disclosure.html) | Collapsible section using native details/summary, with a rotating chevron. |
| [Empty state](components/patterns/empty-state.html) | Centered icon, one short line and at most one action. |
| [Inspector](components/patterns/inspector.html) | Key-value details for one item, in label and value columns. |
| [List](components/patterns/list.html) | Selectable rows with an optional icon, a title, one line of detail and trailing metadata. |
| [Loading rows](components/patterns/loading.html) | Placeholder rows shaped like the content that is about to load. |
| [Log output](components/patterns/log-output.html) | Monospace output in the terminal's font and colors, with ANSI-colored levels. |
| [Master-detail](components/patterns/master-detail.html) | List beside a detail view when wide; the list alone with push navigation when narrow. |
| [Menu](components/patterns/menu.html) | Popover menu anchored to a button, using the native popover attribute. |
| [Metrics](components/patterns/metrics.html) | A row of compact numbers with labels that wraps to fit the pane. |
| [Pane shell](components/patterns/pane-shell.html) | The default page frame: optional toolbar, one scrolling content area, optional status bar. |
| [Path bar](components/patterns/path-bar.html) | Breadcrumb path with clickable segments that collapses middle segments into a menu when narrow. |
| [Search results](components/patterns/search-results.html) | Matches grouped by file, each a line number and a one-line snippet with the match highlighted. |
| [Grouped section](components/patterns/section-group.html) | macOS-style inset groups of label/control rows for settings and forms. |
| [Sectioned list](components/patterns/sectioned-list.html) | Compact list split into groups under sticky, collapsible headers with counts. |
| [Table](components/patterns/table.html) | Dense rows with a sticky header, aligned numeric columns and row selection. |
| [Task list](components/patterns/task-list.html) | Steps or jobs with a status icon, name and duration; the running one shows a spinner. |
| [Toolbar](components/patterns/toolbar.html) | One row of view controls: filter, view switch, a few icon actions and at most one text button. |
| [Outline](components/patterns/tree.html) | Expandable tree of single-line rows with disclosure chevrons, like Finder's list view. |

### Templates

| Component | Summary |
| --- | --- |
| [Starter page](components/templates/starter.html) | Complete plugin index.html: theme setup, pane shell, toolbar filter, list, empty state and status bar. |
<!-- components:end -->
