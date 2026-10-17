# Command-only plugin

1. From this directory, run `zip /tmp/slate-tools.zip plugin.json split-left.sh`.
2. From a Slate terminal, run `slate-term plugins register --package /tmp/slate-tools.zip`.
3. Run `slate-term command run plugin.tools.split-left`, or choose **Workspace → Plugin Commands → My Tools: Split Left**.
4. Optionally assign a shortcut in **Settings → Keyboard Shortcuts**. No plugin pane is needed.

Slate keeps its own ZIP and extracted files; deleting the download or this source directory does not break the installed plugin. Repackage and use `--replace` to update it. No dependency bundling or old-manifest migration is performed.

This example splits the targeted pane, not the whole workspace. See `docs/plugins.md` for command environment variables, settings, timeouts, logs, and trust boundaries.
