# Plugin follow-ups

The full project and initial command-plugin expansion were checkpointed in **`1f80bde`** before starting these follow-ups.

## Follow-up deliverables

1. **Command picker (Command-K):** implemented as a window-attached, centered native Liquid Glass panel, with built-in/plugin search, shortcuts, keyboard/two-click execution, hidden unavailable actions, and preserved invocation context. Copy Pane ID is a stock command rather than permanent frame chrome. See [usage and scope](command-picker.md).
2. **Manual UI / CLI parity audit:** completed with a production-vs-model-vs-debug matrix and prioritized proposals. See [layout/CLI capability audit](layout-cli-audit.md). Important gaps include pane move/resize, tab regrouping, and initial/root split sizing.
3. **Plugin integration / hooks audit:** completed with the supported command/rendering/event/settings surfaces and a staged proposal for semantic post-commit events, headless services, and—only if justified—preflight hooks. See [plugin integration audit](plugin-integration-audit.md).

4. **Native plugin frame buttons:** manifest-declared `headerButtons` invoke owned commands beside Close, with all-type/built-in/widget-ID selectors, clicked-pane context, busy state, adaptive overflow, persistence and live registration cleanup. See [the manifest API](plugins.md#native-frame-buttons).

The audits are deliverables, not implementations of every API they identify. Root-split/sidebar primitives, hidden-pane lifetime, OS-wide shortcuts, startup services, and a hook SDK remain explicitly outside this change. The command picker intentionally has no workflow engine, usage history, AI, or argument-editor subsystem.

Verification entry points: `swift test`, `scripts/verify-plugin-commands.py`, `scripts/verify-plugin-header-buttons.py`, and `scripts/verify-command-picker.py`. The latter captures native light/dark, search/empty/unavailable, and in-workspace material states for visual review. All are also covered by the sequential `scripts/verify-all.sh` run and its source/binary manifest. Full manual accessibility/IME and multi-display QA remain release work.
