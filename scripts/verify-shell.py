#!/usr/bin/env python3
"""Exercise the production shell-command path with an isolated zsh dotfile directory."""
import json
import os
import pathlib
import re
import signal
import shlex
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal"
CLI = ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/Helpers/slate-term"


def eventually(label, condition, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {label}")


for mode in ["system", "quoted", "literal"]:
    with tempfile.TemporaryDirectory(prefix="slate-shell-", dir="/tmp") as temporary:
        directory = pathlib.Path(temporary)
        shell = pathlib.Path("/bin/zsh")
        if mode != "system":
            parent = directory / ("a space, 'quote' and \"double\"" if mode == "quoted" else "$literal and \\backslash and `true`")
            parent.mkdir()
            shell = parent / "zsh"
            shell.symlink_to("/bin/zsh")
        config = directory / "config.toml"
        config.write_text("[terminal]\nshell = " + json.dumps(str(shell)) + ("\nshell_integration = 'off'\n" if mode == "literal" else "\n"))
        home = directory / "shell-home"
        home.mkdir()
        rc = "export SLATE_TEST_RC=isolated\nHISTFILE=/dev/null\nPROMPT='SLATE_TEST_PROMPT> '\n"
        if mode != "literal":
            rc += "export PATH=/usr/bin:/bin:/usr/sbin:/sbin\n"
        (home / ".zshrc").write_text(rc)
        ready = directory / "socket-path"
        environment = dict(os.environ, SLATE_TERM_INTEGRATION="1", SLATE_TERM_TEST_REAL_SHELL="1",
                           SLATE_TERM_STATE_DIR=temporary, SLATE_TERM_CONFIG_FILE=str(config), SLATE_TERM_SOCKET_FILE=str(ready), ZDOTDIR=str(home), ENV="/dev/null", BASH_ENV="/dev/null", HISTFILE="/dev/null")
        for name in ["SLATE_TERM_PANE_ID", "SLATE_TERM_TAB_ID"]:
            environment.pop(name, None)
        with (ROOT / f"artifacts/shell-process-{mode}.log").open("w") as log:
            app = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
            try:
                eventually("shell app readiness", lambda: app.poll() is None and ready.exists())
                environment["SLATE_TERM_SOCKET"] = ready.read_text().strip()

                def cli(*args):
                    result = subprocess.run([str(CLI), *args, "--json"], env=environment, capture_output=True, text=True, timeout=10)
                    assert result.returncode == 0, result.stderr
                    return json.loads(result.stdout)

                def capture():
                    return cli("panes", "capture", "--pane", "p1")["text"]

                eventually("isolated shell prompt ready", lambda: "SLATE_TEST_PROMPT>" in capture())
                cli("panes", "send", "--pane", "p1", "--text", "printf '\\nSLATE_REAL_SHELL=%s:%s\\n' \"$ZSH_VERSION\" \"$SLATE_TEST_RC\"\r")
                eventually("isolated production zsh", lambda: re.search(r"SLATE_REAL_SHELL=\d+[^:]*:isolated", capture()))
                if mode != "literal":
                    eventually("OSC 133 idle-prompt integration", lambda: not cli("rpc", "debug.inspect")["panes"][0]["needsConfirmClose"])
                literal = '日本語 café \\ and "quotes"'
                cli("panes", "send", "--pane", "p1", "--text", "printf '\\nSLATE_UNICODE=%s\\n' " + shlex.quote(literal) + "\r")
                eventually("literal UTF-8 and escaping", lambda: "SLATE_UNICODE=" + literal in capture())
                cli("panes", "send", "--pane", "p1", "--text", "printf '\\nSLATE_REAL_CLI=%s\\n' \"$(command -v slate-term)\"\r")
                eventually("bundled CLI wins shell PATH", lambda: "SLATE_REAL_CLI=" + str(CLI) in capture())
                cli("panes", "send", "--pane", "p1", "--text", "slate-term panes list --json\r")
                eventually("CLI runs inside production zsh", lambda: re.search(r'"id"\s*:\s*"p1"', capture()))
                if mode != "literal":
                    eventually("idle after CLI", lambda: not cli("rpc", "debug.inspect")["panes"][0]["needsConfirmClose"])
                cli("panes", "close", "--pane", "p1", *(["--force"] if mode == "literal" else []))
                assert cli("panes", "list") == []
                print(f"PASS production shell: {mode} path, isolated rc, integration policy, raw UTF-8 input, bundled CLI PATH, close")
            finally:
                if app.poll() is None:
                    os.killpg(app.pid, signal.SIGTERM)
                    try:
                        app.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(app.pid, signal.SIGKILL)
                        app.wait()
