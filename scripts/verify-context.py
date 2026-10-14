#!/usr/bin/env python3
"""Production-zsh context gate: owned startup files, tokens, focus scopes, and shell replacement."""
import json
import os
import pathlib
import shlex
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal"
CLI = APP.parent.parent / "Helpers/slate-term"


def eventually(label, condition, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(0.03)
    raise AssertionError(f"Timed out: {label}")


with tempfile.TemporaryDirectory(prefix="slate-context-", dir="/tmp") as temporary:
    directory = pathlib.Path(temporary)
    startup = directory / "startup"
    startup.mkdir()
    (startup / ".zshenv").write_text('export HISTFILE=/dev/null\nexport PATH=/usr/bin:/bin\n')
    (startup / ".zshrc").write_text('HISTSIZE=0; SAVEHIST=0\nPS1="SLATE_CONTEXT> "\nPS2="SLATE_CONT> "\nbuiltin cd -- "$SLATE_TERM_TEST_DIRECTORY"\n')
    ready = directory / "ready"
    config = directory / "config.toml"
    config.write_text('[terminal]\nshell = "/bin/zsh"\n')
    environment = {key: value for key, value in os.environ.items() if not key.startswith("SLATE_TERM_")}
    environment.update(SLATE_TERM_INTEGRATION="1", SLATE_TERM_TEST_REAL_SHELL="1", SLATE_TERM_STATE_DIR=temporary,
                       SLATE_TERM_SOCKET_FILE=str(ready), SLATE_TERM_CONFIG_FILE=str(config), ZDOTDIR=str(startup),
                       SLATE_TERM_TEST_DIRECTORY=str(directory))
    with (ROOT / "artifacts/context-process.log").open("w") as log:
        app = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
        try:
            eventually("context app readiness", lambda: ready.exists() and app.poll() is None)
            environment["SLATE_TERM_SOCKET"] = ready.read_text().strip()

            def cli(*args, success=True):
                result = subprocess.run([str(CLI), *args, "--json"], env=environment, text=True, capture_output=True, timeout=20)
                if not success:
                    assert result.returncode != 0, args
                    return result.stderr
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)

            def rpc(method, **params):
                return cli("rpc", method, "--params", json.dumps(params))

            def context(pane="p1", scope="pane"):
                return rpc("context.get", pane=pane, scope=scope)

            def check_copy(pane):
                before = rpc("workspace.get")
                header = rpc("debug.paneHeader", pane=pane)
                assert header["closeVisible"] and header["headerActions"] == [], header
                assert rpc('command.run', id='pane.copyID', pane=pane)['paneId'] == pane
                assert rpc('debug.commandClipboard') == pane
                assert rpc("workspace.get") == before, "Copy changed pane identity, layout or focus"

            try:
                eventually("actual zsh prompt telemetry", lambda: context()["terminal"]["state"] == "prompt")
            except AssertionError:
                print("SHELL_STARTUP_DIAGNOSTIC", cli("panes", "capture", "--pane", "p1"), context(), flush=True)
                raise
            header = rpc("debug.paneHeader", pane="p1")
            assert header["type"] == "Terminal" and header["closeVisible"] and header["height"] > 0
            assert "zsh" in header["title"]
            check_copy("p1")
            initial = context()["terminal"]
            assert initial["workingDirectory"] == str(directory), initial
            assert initial["isAtPrompt"] is True and initial["pid"] > 0
            cli("panes", "send", "--pane", "p1", "--text", "/bin/sleep 2\r")
            eventually("running command telemetry", lambda: context()["terminal"]["state"] == "running")
            running = context()["terminal"]
            assert running["command"] == "/bin/sleep 2" and running["isAtPrompt"] is False
            assert "sleep" in rpc("debug.paneHeader", pane="p1")["title"]
            try:
                eventually("header samples the actual foreground process", lambda: next(p for p in rpc("debug.inspect")["panes"] if p["paneId"] == "p1").get("processName") == "sleep")
            except AssertionError:
                print("TITLE_DIAGNOSTIC", rpc("debug.inspect"), context(), flush=True)
                pid = initial["pid"]
                for _ in range(6):
                    row = subprocess.run(["/bin/ps", "-o", "pid=,ppid=,pgid=,tpgid=,comm=", "-p", str(pid)], capture_output=True, text=True, timeout=2).stdout
                    print("OWNED_PROCESS", row, flush=True)
                    if not row.strip() or pid == app.pid:
                        break
                    pid = int(row.split()[1])
                raise
            eventually("return to prompt", lambda: context()["terminal"]["state"] == "prompt")
            assert context()["terminal"]["sequence"] > running["sequence"] > initial["sequence"]
            eventually("header returns to shell process", lambda: "zsh" in rpc("debug.paneHeader", pane="p1")["title"])
            changed = directory / "日本語 ' quoted"
            changed.mkdir()
            cli("panes", "send", "--pane", "p1", "--text", f"cd {shlex.quote(str(changed))}; false\r")
            eventually("quoted cwd and exit status", lambda: context()["terminal"]["workingDirectory"] == str(changed) and context()["terminal"]["exitCode"] == 1)
            draft_file = directory / "unsubmitted-draft"
            cli("terminal", "send", "--pane", "p1", "--text", "printf DRAFT > " + shlex.quote(str(draft_file)) + "; ")
            error = cli("terminal", "run", "--pane", "p1", "--command", ":", success=False)
            assert "editing buffer" in error.lower(), error
            assert not draft_file.exists(), "Automation executed an unfinished user draft"
            draft_sequence = context()["terminal"]["sequence"]
            cli("terminal", "key", "--pane", "p1", "--key", "ctrl+c")
            cli("terminal", "wait", "--pane", "p1", "--after-sequence", str(draft_sequence))
            continuation_file = directory / "unsubmitted-continuation"
            cli("terminal", "send", "--pane", "p1", "--text", "printf DRAFT > " + shlex.quote(str(continuation_file)) + "; " + "\\" + "\r")
            eventually("actual continuation prompt", lambda: "SLATE_CONT> " in cli("panes", "capture", "--pane", "p1")["text"])
            error = cli("terminal", "run", "--pane", "p1", "--command", ":", success=False)
            assert "editing buffer" in error.lower(), error
            assert not continuation_file.exists(), "Automation completed and executed a multiline user draft"
            continuation_sequence = context()["terminal"]["sequence"]
            cli("terminal", "key", "--pane", "p1", "--key", "ctrl+c")
            cli("terminal", "wait", "--pane", "p1", "--after-sequence", str(continuation_sequence))
            run_file = directory / "run-output"
            command = "printf '%s' \"日本語 ' quoted\\nsecond line\" > " + shlex.quote(str(run_file)) + "\nprintf 'RUN_%s\\n' NATIVE\n(exit 17)"
            result = cli("terminal", "run", "--pane", "p1", "--command", command)
            assert result["exitCode"] == 17 and result["sessionId"] == initial["sessionId"]
            assert run_file.read_text() == "日本語 ' quoted\\nsecond line"
            eventually("run command reached actual terminal output", lambda: "RUN_NATIVE" in cli("panes", "capture", "--pane", "p1")["text"])
            assert cli("terminal", "wait", "--pane", "p1", "--contains", "RUN_NATIVE")["matched"]
            error = cli("terminal", "run", "--pane", "p1", "--command", "/bin/sleep 1", "--timeout-milliseconds", "100", success=False)
            assert "not stopped" in error, error
            assert context()["terminal"]["state"] == "running", "Run timeout killed the user's process"
            assert cli("terminal", "wait", "--pane", "p1", "--timeout-milliseconds", "5000")["matched"]
            cli("terminal", "wait", "--pane", "p1", "--contains", "NEVER_PRINTED_SENTINEL", "--timeout-milliseconds", "100", success=False)
            runner = subprocess.Popen([str(CLI), "terminal", "run", "--pane", "p1", "--command", "/bin/sleep 30"], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                eventually("native run owns a suspended request", lambda: rpc("debug.inspect")["pendingTerminalRuns"] == 1 and context()["terminal"]["state"] == "running")
                cli("terminal", "run", "--pane", "p1", "--command", "printf unwanted", success=False)
                runner.terminate()
                runner.communicate(timeout=5)
                eventually("disconnect releases the run", lambda: rpc("debug.inspect")["pendingTerminalRuns"] == 0)
                assert context()["terminal"]["state"] == "running", "Disconnect killed the user's command"
                cli("terminal", "key", "--pane", "p1", "--key", "ctrl+c")
                cli("terminal", "wait", "--pane", "p1", "--timeout-milliseconds", "5000")
            finally:
                if runner.poll() is None:
                    runner.kill()
                    runner.communicate(timeout=5)
            waiter = subprocess.Popen([str(CLI), "terminal", "wait", "--pane", "p1", "--contains", "NEVER_PRINTED_SENTINEL"], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                eventually("native wait is pending", lambda: rpc("debug.inspect")["pendingTerminalWaits"] == 1)
                waiter.terminate()
                waiter.communicate(timeout=5)
                eventually("disconnect releases the wait", lambda: rpc("debug.inspect")["pendingTerminalWaits"] == 0)
            finally:
                if waiter.poll() is None:
                    waiter.kill()
                    waiter.communicate(timeout=5)
            sibling = cli("panes", "split", "--right", "--pane", "p1")["paneId"]
            eventually("second shell context", lambda: context(sibling)["terminal"]["state"] == "prompt")
            assert context(scope="tab")["activeTerminalPaneId"] == sibling
            environment.update(SLATE_TERM_PANE_ID="p1", SLATE_TERM_TAB_ID="t1")
            try:
                assert cli("terminal", "capture", "--scope", "tab")["paneId"] == sibling
                other_tab = cli("tabs", "new")["tabId"]
                global_terminal = context(scope="global")["activeTerminalPaneId"]
                assert global_terminal not in ["p1", sibling], "Scope fixture needs a distinct global terminal"
                check_copy(global_terminal)
                check_copy("p1")
                assert cli("terminal", "capture", "--scope", "global")["paneId"] == global_terminal
                assert cli("terminal", "capture", "--scope", "global", "--pane", "p1")["paneId"] == "p1"
                cli("tabs", "close", "--tab", other_tab, "--force")
            finally:
                environment.pop("SLATE_TERM_PANE_ID", None)
                environment.pop("SLATE_TERM_TAB_ID", None)
            cli("panes", "type", "--pane", sibling, "--type", "browser", "--force")
            web_context = context(sibling, scope="tab")
            assert web_context["focusedPaneId"] == sibling and web_context["activeTerminalPaneId"] == "p1"
            assert web_context["terminal"]["pid"] == initial["pid"]
            eventually("browser header type", lambda: rpc("debug.paneHeader", pane=sibling)["type"] == "Browser")
            eventually("initial browser document loaded", lambda: rpc("browser.get", pane=sibling)["title"] == "New Browser" and not rpc("browser.get", pane=sibling)["loading"])
            rpc("browser.eval", pane=sibling, script="document.title='日本語 Browser Title'")
            eventually("browser header follows document title", lambda: rpc("debug.paneHeader", pane=sibling)["title"] == "日本語 Browser Title")
            rpc("debug.activate", tab="t1")
            time.sleep(1)
            check_copy(sibling)
            rpc("debug.screenshot", path=str(ROOT / "artifacts/pane-copy-feedback.png"))
            time.sleep(1.3)
            rpc("debug.screenshot", path=str(ROOT / "artifacts/pane-copy-header.png"))
            before = context()["terminal"]
            rejection = cli("rpc", "shell.update", "--params", json.dumps({"pane": "p1", "token": "not-the-session", "pid": initial["pid"], "sequence": 99999, "state": "prompt", "cwd": "/", "exitCode": 0}), success=False)
            assert "token" in rejection
            assert context()["terminal"] == before
            cli("panes", "type", "--pane", "p1", "--type", "browser", "--force")
            assert context()["terminal"] is None
            cli("panes", "type", "--pane", "p1", "--type", "terminal", "--force")
            eventually("new shell session", lambda: context()["terminal"]["state"] == "prompt")
            replacement = context()["terminal"]
            check_copy("p1")
            assert replacement["pid"] != initial["pid"] and replacement["sessionId"] != initial["sessionId"]
            config.write_text('[terminal]\nshell = "/bin/zsh"\nshell_integration = "off"\n')
            rpc("config.reload")
            cli("panes", "type", "--pane", sibling, "--type", "terminal", "--force")
            assert context(sibling)["terminal"]["state"] == "unknown"
            assert context(sibling)["terminal"]["isAtPrompt"] is None
            error = cli("terminal", "run", "--pane", sibling, "--command", "printf unsafe", success=False)
            assert "prompt" in error.lower(), error
            disposable = cli("panes", "split", "--down", "--pane", sibling)["paneId"]
            cli("panes", "type", "--pane", disposable, "--type", "browser", "--force")
            cli("panes", "focus", "--pane", "p1")
            surface = next(p["surface"] for p in rpc("debug.inspect")["panes"] if p["paneId"] == "p1")
            rpc("debug.paneHeader", pane=disposable, close=True)
            assert disposable not in [p["id"] for p in cli("panes", "list")]
            after = next(p for p in rpc("debug.inspect")["panes"] if p["paneId"] == "p1")
            assert after["surface"] == surface and after["terminalFocus"], "Header close stole focus or recreated a sibling terminal"
            print("PASS pane headers: type/title, foreground command and prompt updates, browser document title, copy-ID command across tabs and type replacement without focus/layout changes, close control and sibling preservation")
            print("PASS generic terminal run/wait: actual zsh, multiline quoting, nonzero status, timeout without process termination, output conditions and unknown-prompt refusal")
            print("PASS context: real zsh prompt/running/cwd/status, original startup files, monotonic session reports, token rejection, web-independent active terminal, replacement and integration-off unknown state")
        finally:
            if app.poll() is None:
                os.killpg(app.pid, signal.SIGTERM)
                try:
                    app.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(app.pid, signal.SIGKILL)
                    app.wait(timeout=5)
