# Minimal inline welcome mockup

> **Decision record.** The recommended native inline welcome has since been built; see [welcome](../welcome.md) for current behavior.

Open `welcome-mockup.html` directly in a browser. Self-contained; no external assets, dependencies or network requests.

The simplified version has one short inline welcome above the terminal. Removed the previous multi-column layout, outer presentation headings, preview controls, settings dialog, detail expansion, and explanatory panels. Settings guidance is plain text, not a simulated settings feature.

Click `slate-term welcome --read`, then press Return to preview acknowledgement. The same simulated terminal expands into the available space and retains input focus. Reload resets the demo. `clear` clears only terminal output; explicit `slate-term welcome` prints the welcome without changing acknowledgement. Other text produces a mockup notice. Nothing is executed, installed or persisted.

## Checks

- Rendered desktop welcome and dismissed states in isolated Chrome.
- Verified real click/Return dismissal, retained input focus, and terminal expansion.
- Rendered the page in a 390 × 700 same-origin iframe layout viewport to exercise the narrow-screen media query; no horizontal overflow and 344px of terminal height remained.
- Verified `clear` does not dismiss the native welcome.
- Independent visual review inspected all three states and reported no visible issues.

Captures: ignored `artifacts/welcome-mockup/simple/` (`welcome.png`, `dismissed.png`, `narrow.png`). Earlier captures in the parent directory belong to the superseded complex concept.

No application/engine code or installed app was changed. This does not verify native AppKit behavior, accessibility, real CLI execution, persistence, or extreme minimum split dimensions.
