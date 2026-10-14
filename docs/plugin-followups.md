# Plugin follow-ups

Requested follow-ups, deliberately outside the command-plugin implementation:

1. **Command picker (Command-K):** search and invoke built-in app actions and registered plugin commands from the same command catalog. Shortcut configurable through the normal system.
2. **Manual UI / CLI parity audit:** inventory window/tab/pane operations available to people versus CLI users. Include creating, moving/reordering, splitting, resizing, and placing a full-height left-side pane with its intended initial dimensions. Distinguish splitting a leaf from wrapping a whole layout, and hiding a pane from destroying its session.
3. **Plugin integration / hooks audit:** inventory existing CLI, page-bridge, event, macro, and rendering capabilities. Identify behaviors plugins can observe versus intercept or change; consider before/after split hooks, lifecycle hooks, and missing SDK/API primitives. Define cancellation, ordering, reentrancy, errors, and trust implications before introducing synchronous/veto hooks.

The initial command contribution system adds on-demand executable commands, optional panel UI, app-local shortcuts, and namespaced settings. It does not add startup/background-service activation, OS-wide shortcuts, a command picker, sidebar primitives, or hooks.
