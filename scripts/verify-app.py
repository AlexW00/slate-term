#!/usr/bin/env python3
"""CLI-only native workspace integration gate; isolated app process and storage."""
import json
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal"
CLI = ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/Frameworks/SlateRuntime.framework/Helpers/slate-term"


def eventually(label, condition, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {label}")


with tempfile.TemporaryDirectory(prefix="slate-app-", dir="/tmp") as temporary:
    directory = pathlib.Path(temporary)
    ready = directory / "socket-path"
    tmux = shutil.which("tmux")
    assert tmux, "The native tmux smoke gate requires tmux on PATH"
    tmux_server = directory.name
    environment = dict(os.environ, SLATE_TERM_INTEGRATION="1", SLATE_TERM_STATE_DIR=temporary,
                       SLATE_TERM_SOCKET_FILE=str(ready))
    log_path = ROOT / "artifacts/app-process.log"
    log_path.parent.mkdir(exist_ok=True)
    with log_path.open("w") as log:
        app = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
        try:
            eventually("control server readiness", lambda: ready.exists() and app.poll() is None)
            environment["SLATE_TERM_SOCKET"] = ready.read_text().strip()

            def cli(*args, expected_success=True, extra_env=None):
                result = subprocess.run([str(CLI), *args, "--json"], env=dict(environment, **(extra_env or {})),
                                        capture_output=True, text=True, timeout=10)
                if expected_success:
                    assert result.returncode == 0, result.stderr
                    return json.loads(result.stdout)
                assert result.returncode != 0, f"Invalid command succeeded: {args}"

            initial = cli("rpc", "debug.inspect")
            original_surface = initial["panes"][0]["surface"]
            original_window = [initial["windows"][0][key] for key in ["width", "height"]]
            assert cli("panes", "list")[0]["id"] == "p1"
            p2 = cli("panes", "split", "--right", "--pane", "p1")["paneId"]
            first_split = cli("rpc", "debug.inspect")
            assert all(p["attached"] for p in first_split["panes"])
            p3 = cli("panes", "split", "--down", "--pane", p2)["paneId"]
            layout = cli("layout", "get")
            assert layout["axis"] == "horizontal"
            assert layout["first"] == {"kind": "pane", "pane": "p1"}
            assert layout["second"]["axis"] == "vertical"
            inspect = cli("rpc", "debug.inspect")
            assert len(inspect["panes"]) == 3
            assert all(p["width"] > 0 and p["height"] > 0 and p["attached"] for p in inspect["panes"])
            assert [inspect["windows"][0][key] for key in ["width", "height"]] == original_window, f"Splitting resized the window: {original_window} -> {inspect['windows'][0]}"
            rendered = {p["paneId"]: p for p in inspect["panes"]}
            assert rendered["p1"]["x"] < rendered[p2]["x"]
            assert rendered[p2]["y"] > rendered[p3]["y"]
            assert rendered["p1"]["height"] > rendered[p2]["height"]
            assert abs(rendered["p1"]["width"] / (rendered["p1"]["width"] + rendered[p2]["width"]) - 0.5) < 0.003, f"Root fraction was not rendered: {rendered}; model: {layout}"
            assert abs(rendered[p2]["height"] / (rendered[p2]["height"] + rendered[p3]["height"]) - 0.5) < 0.003, "Nested fraction was not rendered"
            assert sum(p["terminalFocus"] for p in inspect["panes"]) == 1, "Multiple Ghostty surfaces retain keyboard focus"
            for pane in ["p1", p2, p3]:
                cli("panes", "send", "--pane", pane, "--text", f"printf '%s%s\\n' 'SLATE_PANE_' '{pane}'\r")
                eventually(f"rendered pane {pane} shell readiness", lambda: f"SLATE_PANE_{pane}" in cli("panes", "capture", "--pane", pane)["text"])
            surfaces = {pane["paneId"]: pane["surface"] for pane in cli("rpc", "debug.inspect")["panes"]}
            original_tree = cli("layout", "get")
            cli("command", "run", "pane.zoom", "--pane", p2)
            zoomed = {pane["paneId"]: pane for pane in cli("rpc", "debug.inspect")["panes"]}
            assert zoomed[p2]["attached"] and not zoomed["p1"]["attached"] and not zoomed[p3]["attached"], zoomed
            assert cli("layout", "get") == original_tree, "Zoom destroyed the split layout"
            cli("command", "run", "focus.down", "--pane", p2)
            focused_zoom = {pane["paneId"]: pane for pane in cli("rpc", "debug.inspect")["panes"]}
            assert focused_zoom[p3]["firstResponder"] and focused_zoom[p3]["attached"] and not focused_zoom[p2]["attached"]
            cli("command", "run", "pane.zoom", "--pane", p3)
            restored = cli("rpc", "debug.inspect")["panes"]
            assert all(pane["attached"] and pane["surface"] == surfaces[pane["paneId"]] for pane in restored)
            cli("command", "run", "layout.equalize")
            assert abs(cli("layout", "get")["fraction"] - 1 / 3) < 0.003
            cli("rpc", "debug.screenshot", "--params", json.dumps({"path": str(ROOT / "artifacts/app-splits.png")}))
            assert next(p for p in inspect["panes"] if p["paneId"] == "p1")["surface"] == original_surface
            cli("rpc", "debug.divider", "--params", '{"fraction":0.3}')
            assert abs(cli("layout", "get")["fraction"] - 0.3) < 0.003, "Native divider did not update the model"
            cli("panes", "focus", "--pane", "p1")
            inspect = cli("rpc", "debug.inspect")
            assert next(p for p in inspect["panes"] if p["paneId"] == "p1")["firstResponder"]
            cli("panes", "send", "--pane", "p1", "--text", "printf '%s%s\\n' 'SLATE_' 'CLI_OK'\r")
            eventually("terminal output through CLI", lambda: "SLATE_CLI_OK" in cli("panes", "capture", "--pane", "p1")["text"])
            cli("panes", "send", "--pane", "p1", "--text", "test -r \"$TERMINFO/78/xterm-ghostty\" && tput cols >/dev/null && printf '%s%s\\n' 'SLATE_' 'TERMINFO_OK'\r")
            eventually("bundled terminfo", lambda: "SLATE_TERMINFO_OK" in cli("panes", "capture", "--pane", "p1")["text"])
            child = "printf '%s%s\\n' 'SLATE_' 'TMUX_READY'; exec /bin/sh --noprofile --norc"
            command = "env -u TMUX -u TMUX_PANE " + shlex.join([tmux, "-L", tmux_server, "-f", "/dev/null", "new-session", "-s", "smoke", child])
            cli("panes", "send", "--pane", "p1", "--text", command + "\r")
            eventually("attached tmux rendering", lambda: "SLATE_TMUX_READY" in cli("panes", "capture", "--pane", "p1")["text"])
            cli("panes", "send", "--pane", "p1", "--text", "printf '%s%s\\n' 'SLATE_' 'INSIDE_TMUX'\r")
            eventually("input inside tmux", lambda: "SLATE_INSIDE_TMUX" in cli("panes", "capture", "--pane", "p1")["text"])
            cli("panes", "close", "--pane", "p1", expected_success=False)
            cli("panes", "send", "--pane", "p1", "--text", "exit\r")
            eventually("tmux session exit", lambda: subprocess.run([tmux, "-L", tmux_server, "has-session", "-t", "smoke"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3).returncode != 0)
            cli("panes", "send", "--pane", "p1", "--text", "slate-term command list >/dev/null && printf '%s%s\\n' 'SLATE_' 'BUNDLED_CLI_OK'\r")
            eventually("bundled CLI on terminal PATH", lambda: "SLATE_BUNDLED_CLI_OK" in cli("panes", "capture", "--pane", "p1")["text"])
            cli("panes", "close", "--pane", p2, "--force")
            assert cli("layout", "get")["second"] == {"kind": "pane", "pane": p3}
            cli("panes", "close", "--pane", p3, "--force")
            assert cli("layout", "get") == {"kind": "pane", "pane": "p1"}
            cli("rpc", "debug.key")
            after_key = cli("panes", "list")
            assert len(after_key) == 2, "Native Command-D did not reach the command registry"
            cli("panes", "close", "--pane", next(p["id"] for p in after_key if p["id"] != "p1"), "--force")
            for _ in range(10):
                pane = cli("panes", "split", "--left", "--pane", "p1")["paneId"]
                cli("panes", "close", "--pane", pane, "--force")
            assert cli("rpc", "debug.inspect")["panes"][0]["surface"] == original_surface
            background_survivor = cli("panes", "split", "--right", "--pane", "p1", "--focus-policy", "new")["paneId"]
            background_pane = cli("panes", "split", "--down", "--pane", "p1", "--focus-policy", "new")["paneId"]
            tab = cli("tabs", "new", "--focus-policy", "new")["tabId"]
            cli("panes", "close", "--pane", background_pane, "--force")
            cli("rpc", "debug.activate", "--params", '{"tab":"t1"}')
            activated = cli("rpc", "debug.inspect")
            assert next(p for p in activated["panes"] if p["paneId"] == background_survivor)["firstResponder"], "Background tab did not restore its most recently focused surviving terminal"
            cli("panes", "close", "--pane", background_survivor, "--force")
            cli("tabs", "focus", "--tab", tab)
            assert len(cli("tabs", "list")) == 2
            assert len(cli("rpc", "debug.inspect")["nativeTabGroups"][0]) == 2
            cli("rpc", "debug.detach", "--params", json.dumps({"tab": tab}))
            eventually("native tab detach", lambda: len(cli("rpc", "debug.inspect")["nativeTabGroups"]) == 2)
            assert len(cli("rpc", "workspace.get")["groups"]) == 2, "Native detach did not update the model"
            # Explicit tab overrides the caller's environment pane.
            extra = cli("panes", "split", "--right", "--tab", tab,
                        extra_env={"SLATE_TERM_PANE_ID": "p1", "SLATE_TERM_TAB_ID": "t1"})["paneId"]
            assert cli("layout", "get", "--tab", tab)["second"]["pane"] == extra
            cli("tabs", "close", "--tab", tab, "--force")
            assert len(cli("panes", "list")) == 1
            cli("panes", "split", "--right", "--pane", "p999", expected_success=False)
            cli("command", "run", "not-a-command", expected_success=False)
            assert cli("layout", "get") == {"kind": "pane", "pane": "p1"}
            cli("rpc", "debug.screenshot", "--params", json.dumps({"path": str(ROOT / "artifacts/app-workspace.png")}))
            cli("panes", "send", "--pane", "p1", "--text", "exit\r")
            eventually("shell exit closes its pane", lambda: cli("panes", "list") == [])
            assert cli("tabs", "list") == []
            assert cli("tabs", "new")["tabId"] != "t1"
            print("PASS native app: CLI layout, fractions, divider writeback, Command-D, stable PTY, tmux, native tabs, background focus, shell exit, self-targeting, bundled CLI, errors")
        finally:
            try:
                subprocess.run([tmux, "-L", tmux_server, "kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            finally:
                if app.poll() is None:
                    os.killpg(app.pid, signal.SIGTERM)
                    try:
                        app.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(app.pid, signal.SIGKILL)
                        app.wait()
