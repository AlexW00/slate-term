# Layout editor refinements

Outcome: capture the invoking window without a selector, preview pane bars directly, default terminal folders to home, preserve live pane folders, and create named/icon-customized launchers in a dedicated dialog.

Acceptance: model tests validate launcher inputs and folder defaults; native VM checks cover contextual capture, per-pane current folders and reopening, bar previews, launcher dialog and bundle metadata/icon. Existing CLI/page/service launchers expose the same options.

Non-goals: session snapshots, launcher overwrites, arbitrary custom image uploads, changing existing saved folder paths.

Milestones: implement shared behavior and UI; run focused package/build/VM checks; independently review fresh renders and fix findings.


Verification: 365 package tests passed; native Debug build passed. The focused saved-layouts VM gate passed with clean process teardown in `artifacts/vm/20261017T064548Z-6425b8d0`. It verifies distinct current folders survive capture and reopening, contextual capture without a source selector, defaults, popup rendering and signed launcher bundles with names/icons. Settings close checks also passed in `20261017T063053Z-004b35f9`. Spotlight indexing and Launch Services cold/warm launch remain outside these checks.
