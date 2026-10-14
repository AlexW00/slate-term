# Saved layouts — design notes

Status: interactive HTML proposal only. Native UI, persistence, CLI, and bridge APIs are not implemented by this mockup.

Open `saved-layouts.html` directly in a browser. Changes are held in memory and reset on reload; commands, window opening, and launcher installation are simulated. The explicit sample-file download is a real browser download.

## Current UI

- The layout library is the editor: layouts on the left, selectable split arrangement in the middle, type-specific fields on the right.
- Pane tiles contain names, type icons, and dependency status—not configuration values.
- Selecting a pane updates the inline inspector. Terminal, Browser, and an example plugin use declarative field definitions to render their forms.
- Split Right / Split Below insert a pane into the selected leaf of the layout tree. The mockup caps layouts at eight panes and disables splits that would make tiles too small.
- Revert and Save Changes live in the bottom bar. Unsaved drafts survive switching layouts; they do not change saved definitions until Save Changes.
- No Open in New Window, Save a Window, Open Layouts Folder, or JSON-view buttons on the editor screen. Opening a layout, capturing a workspace window, and creating a Spotlight launcher remain accessible through the command picker.
- Capturing a window uses an explicit source chooser. The last-focused workspace is a suggestion, not an implicit target. The library window is never the source. A closed source is not silently replaced by another window.
- Invalid JSON and unavailable plugins remain visible in the library. Invalid JSON has a read-only file diagnostic; missing plugins retain their pane position and reference until deliberately replaced or restored.
- No command-approval UI. Startup commands remain an explicit part of a layout's setup.

## Files remain authoritative

Proposed location: `~/.config/slate-term/layouts/`, one versioned JSON file per layout with a stable UUID. The future implementation must read and write these files directly, not maintain a second authoritative layout catalog. External changes require validation and conflict detection before overwriting unsaved edits.

The mockup's JSON and sample plugin field definitions illustrate the design; they are not a finalized public schema or a new native plugin SDK.

## Required CLI and bridge parity

Native controls, the command picker, the CLI, and the authorized plugin bridge must use the same supported layout operations. Public API names are still to be designed; do not expose integration-only debug commands as the implementation.

Required coverage:

| Operation | Contract |
| --- | --- |
| List | Stable IDs, names, source files, and availability/diagnostics, including broken files. |
| Inspect | Saved topology, pane types, configuration, startup commands, and a revision for updates. Report malformed files without inventing a valid layout. |
| Inspect pane-type fields | Discover built-in/plugin field definitions, defaults, validation rules, and unavailable dependencies. |
| Validate | Check a proposed definition without creating panes, running commands, or changing files. |
| Create | Persist a supplied, validated definition with a stable identity; do not silently overwrite an existing file. |
| Capture workspace | Require an explicit source workspace/window identity and capture options; never infer a source from the library's focus. |
| Update | Save configuration/topology changes atomically with an expected-revision precondition. Support the same split and pane-type changes as the editor. |
| Open | Open a saved layout with the same validation and startup-command behavior as the human action. Create fresh runtime pane/tab IDs; do not reuse template-local IDs as live identities. |

Read operations should return structured diagnostics. Failed validation, missing dependencies, and stale revisions must not modify the saved file or a live workspace. CLI and bridge entry points must not bypass the native validation or execution behavior.

Bridge access remains subject to its existing caller identity and capability/scope boundaries. Parity does not mean granting every web view arbitrary workspace access. Direct file editing by agents remains supported; it is not replaced by the API.

Verification for the future implementation should exercise equivalent UI, CLI, and bridge operations, plus external-file edits, invalid files, missing plugins, stale updates, explicit source capture, and fresh runtime identity allocation.
