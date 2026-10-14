# Command-only plugin

1. In `plugin.json`, replace the script argument with the absolute path to this directory's `split-left.sh`.
2. From a Slate terminal, run `slate-term plugins register --manifest /absolute/path/to/plugin.json`.
3. Run `slate-term command run plugin.tools.split-left`, or choose **Workspace → Plugin Commands → My Tools: Split Left**.
4. Optionally assign a shortcut in **Settings → Keyboard Shortcuts**. No plugin pane is needed.

This example splits the targeted pane, not the whole workspace. Full-workspace/sidebar layout primitives are a separate follow-up. See `docs/plugins.md` for command environment variables, settings, timeouts, logs, and trust boundaries.
