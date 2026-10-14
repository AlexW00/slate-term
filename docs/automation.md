# Automation

All methods use the same local JSON-RPC interface as the bundled CLI. Pass a pane explicitly when targeting a particular surface. See [the control protocol](control.md) and [plugins](plugins.md) for connection and trust boundaries.

## Terminals

```sh
slate-term terminal send --pane p1 --text $'printf "hello\\n"\r'
slate-term terminal key --pane p1 --key ctrl+c
slate-term terminal capture --pane p1
slate-term terminal run --pane p1 --command 'printf "hello\\n"; false'
slate-term terminal wait --pane p1 --contains 'READY' --timeout-milliseconds 5000
slate-term terminal wait --pane p1 --after-sequence 12
```

RPC names are `terminal.send`, `.key`, `.capture`, `.run`, `.wait`. Routing parameters are `pane`, `tab`, `scope` (`pane`, `tab`, `global`) and optional `sessionId`. A terminal pane is addressed directly; a browser/plugin pane anchors contextual terminal resolution. A retained terminal history is independent of web-view focus. Use `context.get` to read the current terminal/session and pass `sessionId` to reject work aimed at a replaced shell.

- **send:** `text` is literal UTF-8, including control bytes. It is not a shell command, shell quoting, or bracketed paste. Existing `panes send/capture` remain available.
- **key:** `key` names a logical US-ASCII key, with optional unique `ctrl+`, `alt+`, `shift+` modifiers. Ghostty encodes press/release using the terminal's current keyboard and cursor modes. Letters, digits, `space`, `enter`, `tab`, `escape`, `backspace`, `delete`, `insert`, `home`, `end`, `pageup`, `pagedown`, arrows and `f1`–`f12` are supported. Punctuation names: `minus`, `equal`, `left-bracket`, `right-bracket`, `semicolon`, `quote`, `backslash`, `comma`, `period`, `slash`, `backtick`. For example, `shift+equal` types `+`. Case is insignificant. Chords are limited to 128 UTF-8 bytes. Command/Super shortcuts belong to workspace commands, not this input API; arbitrary Unicode uses `send`.
- **capture:** returns current screen `text` and `truncated`. Retains at most the final 128 KiB of valid UTF-8. This is not a scrollback export or isolated command stdout. The `terminal` form also returns `paneId` and `sessionId`.
- **run:** `command` is a nonempty zsh program, at most 16,384 UTF-8 bytes with no NUL. Requires authenticated shell integration and an idle prompt. A private zsh widget checks the actual editing buffer, prior continuation lines and primary-prompt context before claiming the queued command; an unfinished draft is refused without submitting it. The widget uses a session-specific binding in the standard main/emacs/viins/vicmd maps. Replacing those maps or removing the integration can make a run time out rather than guess. Completion requires its unique preexec marker followed by a later prompt report, never a guessed output string or process name. Returns `paneId`, `sessionId`, `commandId`, `exitCode`, `text`, `truncated`. A nonzero command status is a completed RPC result; inspect `exitCode`, not the CLI's transport exit status. Text is the screen when completion is reported, not a promise that all output has rendered or a per-command stream. The eval wrapper can appear in shell history and terminal echo. Commands that replace/exit the interactive shell cannot complete through its next prompt.
- **wait:** with `contains`, waits for literal current-screen text (1–4096 UTF-8 bytes). This may match existing output: choose a unique marker when freshness matters. Without it, waits for an authenticated prompt; unknown shell state is rejected. Optional `afterSequence` requires a newer prompt and is incompatible with `contains`. Returns `matched`, pane/session IDs, and available report sequence/exit status.

Run/wait deadlines default to 30,000 milliseconds; range 1–295,000. At most one run per pane, 32 runs and 32 waits per app. Targets and session identities are frozen for an operation. Replacing/closing the terminal invalidates outstanding work. Timeout or disconnect **stops waiting, not the user's command**. Explicitly send `ctrl+c` if interruption is intended. Dedicated automation terminals avoid competing human/extension input; raw `send` deliberately makes no prompt-safety guarantee.

Plugin equivalents:

```js
await workspace.terminal.key('ctrl+c', { pane: 'p1', sessionId });
const result = await workspace.terminal.run('printf "hello\\n"', {}, { signal });
await workspace.terminal.wait({ contains: 'READY', timeoutMilliseconds: 5000 }, { signal });
```

A plugin defaults to its declared context. Explicit terminal IDs override its terminal history. Aborting or replacing the plugin document releases its waits; already accepted input cannot be undone. Tool-specific protocols and enriched context, including tmux integration, belong in extensions.

## Browsers

```sh
slate-term browser navigate --pane p2 --url http://127.0.0.1:8080/
slate-term browser snapshot --pane p2 --max-elements 128
slate-term browser fill --pane p2 --selector '#name' --text '日本語'
slate-term browser click --pane p2 --ref DOCUMENT:REFERENCE
slate-term browser select --pane p2 --selector '#choice' --value first
slate-term browser scroll --pane p2 --y 600
slate-term browser wait --pane p2 --selector '#result' --state visible --timeout-milliseconds 5000
slate-term browser screenshot --pane p2 --path /absolute/path/page.png
```

RPC names match CLI actions (`browser.snapshot`, etc.). Element actions require exactly one unique CSS `selector` or snapshot `ref`. Ambiguous selectors fail instead of choosing the first match. Scroll's target is optional; omission scrolls the window. Distances are CSS pixels, bounded to ±10 million per axis.

Snapshots return URL/title, document identity, viewport/scroll geometry, visible text, interactive element metadata and `truncated`. Elements include reference, tag/approximate role, name, enabled state, rectangle and viewport intersection, plus relevant value/checked/expanded state. Password values are omitted. This is a bounded DOM summary, **not the platform accessibility tree**. Defaults: 128 elements (configurable 1–256), 4,000 visited elements, 2,048 visited text nodes, 16,384 UTF-16 text units and a 350,000-byte element budget. Names/values are clipped to 256/512 UTF-16 units. Truncation is reported. At most 2,048 weak element references are retained; refresh the snapshot if one expires.

References are document-scoped. Navigation, reload, cached-history restoration and pane replacement do not revive old references. A detached element cannot be mutated through its old reference. Helpers live in a retained private WebKit content world, not in the page's JavaScript namespace. Ordinary browser pages never receive `workspace` or the plugin bridge.

Click/fill/select reject hidden, disabled, inert or covered targets and scroll them into view. Fill supports text-like inputs, textareas and contenteditable elements; readonly fields are rejected. Input and change events are dispatched. Select validates every requested value before changing selection; values must uniquely identify enabled options. Up to 64 values of 4,096 UTF-8 bytes each; fill text is limited to 65,536 UTF-8 bytes.

Wait states: `attached`, `detached`, `visible` (default), `hidden`. Timeout is 0–10,000 milliseconds; zero performs one probe, not repeated waiting. Visibility means rendered, not necessarily inside the viewport. Navigation and pane closure invalidate pending operations; disconnect cancels waiting. Navigation has a 15-second deadline, evaluation/screenshot/actions generally 10 seconds. At most 32 active WebKit operations per pane; serialized evaluation results are capped at 900,000 bytes.

### WebKit limits

- Main-document light DOM only: no frame traversal or shadow-root selector language.
- DOM activation/events are synthetic, not trusted hardware input. User-gesture-gated APIs and anti-automation pages may reject them.
- Cancellation does not roll back an action or forcibly interrupt JavaScript already submitted to WebKit.
- Browser data stores are per-pane and ephemeral; history/cookies are discarded with the pane or app, not restored from workspace JSON.
- HTTP(S) and `about:blank` navigation only; no URL credentials, arbitrary file browsing, download manager, remote debugging port, CDP compatibility, or privileged plugin API.
- `browser.eval --script ...` remains available for explicit page-world JavaScript. It must return a JSON-representable value; screenshots capture the visible web view, not an entire scrolling document.
