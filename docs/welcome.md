# Inline welcome

New terminal sessions show a short native message above the live terminal until the user explicitly marks it read. It is not terminal scrollback: `clear`, alternate-screen programs and shell integration being off do not remove it. No shell startup files or Ghostty code are changed. Browser/plugin panes do not show it.

The terminal view and session are retained when the message disappears. Welcome content never receives keyboard focus or terminal input. It wraps and scrolls locally when necessary, takes no more than half the available content height, and yields space to the terminal in very small panes. Hiding the pane header does not dismiss the welcome.

Each small play-shaped button sits to the left of its command: `slate-term skill setup` opens an interactive skill installer, and `slate-term welcome --read` acknowledges the welcome. A button **inserts** its exact command text into the terminal below and focuses it. It does not press Return, mark the message read, or clear an existing draft; input is inserted at the current cursor, like typing. Press Return yourself when ready. Its tooltip and accessibility label describe insertion rather than execution. These are native conveniences for the existing terminal-input capability (`terminal.send` for agents), not separate installation or acknowledgement operations. The interactive installer uses `skills.list` and `skills.install`, just like Settings → AI Agents, and asks for destinations and confirmation before installing. It does not acknowledge the welcome. See [agent skill setup](control.md#agent-skill).

## Explicit operations

```sh
slate-term welcome          # print current copy; no acknowledgement
slate-term welcome --read   # persist acknowledgement; dismiss all current welcomes
slate-term welcome --unread # re-enable it in future terminal sessions only
slate-term welcome --reset  # alias for --unread
slate-term welcome --json   # inspect structured state/content
```

`--read` and `--unread`/`--reset` are mutually exclusive. Unrelated CLI commands never acknowledge the message. No operation is automatically retried. These operations need a running, explicitly discovered app instance, just like other app-control CLI commands.

| Surface | Read content/state | Acknowledge | Mark unread / reset |
| --- | --- | --- | --- |
| Shared RPC | `welcome.get {}` | `command.run {id:"welcome.read"}` | `command.run {id:"welcome.unread"}` (alias: `welcome.reset`) |
| Registered page | `workspace.welcome.get(options)` | `workspace.welcome.read(options)` | `workspace.welcome.unread(options)` (alias: `workspace.welcome.reset(options)`) |
| Native service | Same RPC/CLI through its bound endpoint | Same | Same |
| Native | Inline content | Cmd-K: Mark Welcome Message as Read | Cmd-K: Mark Welcome Message as Unread |

The mutation command IDs are also configurable shortcuts, with no default binding. Cmd-K disables actions already matching known state and omits the duplicate `welcome.reset` alias. There is no extra dismiss button/settings dialog and no native picker action for the pure read. Page helper `options` accepts the usual `cause` and `signal`; generic calls can also supply the optional `expectedInstanceId` guard.

Operations are global to the app's state directory. No pane/tab defaults are inherited. Only `expectedInstanceId` is accepted in addition to the mutation command `id`; pane/session/layout/workspace guards and unknown arguments fail closed. Normal caller liveness, document binding and admission rules still apply. `api.describe.welcome` and the shared method/command catalogs advertise this capability.

### Result and error contract

`welcome.get` returns:

- `content: {title: string, paragraphs: string[]}` — current provisional copy.
- `acknowledged: boolean | null` — `null` means the saved state could not be read.
- `automaticDisplayEnabled: boolean` — true only when acknowledgement is known to be false; applies to future terminal sessions.
- `revision: string` — opaque app-lifetime preference revision, separate from workspace revisions.
- `error: string | null` — bounded read diagnostic; current copy remains available if persistence is damaged.

Mutations return the same fields plus `changed: boolean`, `persisted: true`, and `operationId: string`. Repeating the current known value is a no-op: no write, revision bump or event. Unread/reset never reopens the message in existing sessions; open a new terminal to test it again. An explicit read removes current messages without focusing, recreating or sending input to terminals.

Malformed/unsupported inputs fail with `-32602`; a stale app-instance guard fails with `-32050`. A failed preference write returns `-32054` with `{persisted:false,revision}` and retains acknowledgement and presentation. If persistence succeeds but event publication fails, `-32051` reports `{persisted:true,revision}`: inspect `welcome.get` before deciding what to do; do not blindly retry. Standard transport, stale-caller and admission failures also apply.

A successful change emits one bounded global `host.welcome.changed` post-persistence event with `{operationId,beforeRevision,revision,acknowledged}`, host source and native-assigned causal lineage. It carries no preference path, private caller identifiers or welcome copy. To recover after event expiry, get `events.head`, read `welcome.get`, then resume polling.

## Persistence and wording

Acknowledgement is a private boolean in `state/welcome.json` under the application's existing state root, written atomically through `PrivateJSONStore` (0600 file, private directory, ownership/symlink checks). It survives restart and is not tied to the current copy or app version. No preference file is needed for the initial unread default. Reading content never writes it.

Malformed/unreadable saved state pauses automatic display rather than preventing terminal startup or repeatedly showing onboarding. `config.get` includes the welcome snapshot and its storage diagnostic. Only an explicit read/reset may repair malformed content; unsafe permissions and symlinks still fail closed.

**Wording is intentionally provisional.** Edit only `Sources/SlateTermCore/Welcome.swift` (`WelcomeContent.current`, `skillCommand` and `readCommand`) to iterate. Both native presentation and CLI/API content use it. Text edits must not reset acknowledgement. Release announcements are not part of this feature.

## Focused checks

Package tests cover private persistence, failure retention, malformed state, no-ops, CLI flag routing and catalog/default-target parity. `scripts/verify-welcome-native.sh` renders production AppKit controls with a retained responder fixture and checks focus/identity, dismissal, small panes and hidden headers. `scripts/verify-welcome.py` exercises the built app's native picker, CLI, registered page and managed service, shell-integration-off zsh/bash, retained Ghostty identity/geometry, failure paths and one isolated restart. Both gates are included in `verify-all.sh`; its source manifest automatically includes their inputs. Offscreen AppKit view caching can omit system-scroller pixels even when the scrollbar is enabled and laid out; use real-window compositor captures to review small-pane overflow. See the welcome entry in [implementation progress](api-extension-progress.md) for what was actually run and remaining verification limits.
