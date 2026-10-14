#!/usr/bin/env python3
"""Real-app settings reload and abrupt-restart recovery, using only the bundled CLI."""
import json
import os
import pathlib
import re
import signal
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


with tempfile.TemporaryDirectory(prefix="slate-settings-", dir="/tmp") as temporary:
    directory = pathlib.Path(temporary)
    # Colocation must not turn generated terminal.conf/workspace writes into a
    # configuration-reload feedback loop.
    config = directory / "state/config.toml"
    config.parent.mkdir(mode=0o700)
    ready = directory / "socket-path"
    state = directory / "state/workspace.json"
    environment = dict(os.environ, SLATE_TERM_INTEGRATION="1", SLATE_TERM_STATE_DIR=temporary,
                       SLATE_TERM_CONFIG_FILE=str(config), SLATE_TERM_SOCKET_FILE=str(ready))
    for name in ["SLATE_TERM_PANE_ID", "SLATE_TERM_TAB_ID"]:
        environment.pop(name, None)
    app = None

    def replace_config(text):
        replacement = config.with_suffix(".new")
        replacement.write_text(text)
        replacement.replace(config)

    def cli(*args, success=True):
        result = subprocess.run([str(CLI), *args, "--json"], env=environment, capture_output=True, text=True, timeout=10)
        if not success:
            assert result.returncode != 0, args
            return
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    def rpc(method, **params):
        return cli("rpc", method, "--params", json.dumps(params))

    def stop():
        global app
        if app is not None and app.poll() is None:
            os.killpg(app.pid, signal.SIGTERM)
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(app.pid, signal.SIGKILL)
                app.wait()
        app = None

    with (ROOT / "artifacts/settings-process.log").open("w") as log:
        def start():
            global app
            ready.unlink(missing_ok=True)
            app = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
            eventually("app readiness", lambda: app.poll() is None and ready.exists())
            environment["SLATE_TERM_SOCKET"] = ready.read_text().strip()

        try:
            replace_config('[appearance]\ntheme = "dark"\n')
            start()
            assert rpc("config.get")["current"]["terminal"]["font_size"] == 13
            original_socket = ready.read_text()
            second = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
            try:
                assert second.wait(timeout=10) != 0, "A second writer acquired the same state directory"
            finally:
                if second.poll() is None:
                    os.killpg(second.pid, signal.SIGKILL)
                    second.wait()
            assert "Another Slate Terminal instance owns this state directory" in (ROOT / "artifacts/settings-process.log").read_text()
            assert ready.read_text() == original_socket
            before = rpc("debug.inspect")["panes"][0]
            cli("panes", "send", "--pane", "p1", "--text", "stty -echo; printf '\\nSLATE_SETTINGS_PID=%s\\n' \"$$\"\r")
            eventually("initial shell", lambda: re.search(r"SLATE_SETTINGS_PID=\d+", cli("panes", "capture", "--pane", "p1")["text"]))
            old_pid = re.search(r"SLATE_SETTINGS_PID=(\d+)", cli("panes", "capture", "--pane", "p1")["text"]).group(1)
            replace_config('[appearance]\ntheme = "light"\n[terminal]\nfont_size = 19\n[keybind]\n"cmd+d" = "split.down"\n"ctrl+shift+j" = "split.right"\n"j" = "split.left"\n"cmd+shift+1" = "split.down"\n"cmd+plus" = "split.down"\n')
            eventually("atomic config reload", lambda: rpc("config.get")["current"]["terminal"]["font_size"] == 19)
            eventually("live engine font size", lambda: rpc("debug.inspect")["panes"][0]["cellHeight"] > before["cellHeight"])
            assert rpc("debug.inspect")["panes"][0]["surface"] == before["surface"]
            engine_file = directory / "state/terminal.conf"
            modified = engine_file.stat().st_mtime_ns
            time.sleep(0.4)  # Negative quiet-window check spans multiple watcher cycles.
            assert engine_file.stat().st_mtime_ns == modified, "Generated files triggered a reload feedback loop"
            cli("panes", "send", "--pane", "p1", "--text", "printf '\\nSLATE_AFTER_PID=%s\\n' \"$$\"\r")
            eventually("same live shell after reload", lambda: re.search(r"SLATE_AFTER_PID=" + old_pid + r"(?!\d)", cli("panes", "capture", "--pane", "p1")["text"]))
            rpc("debug.key", dispatch=True)
            assert cli("layout", "get")["axis"] == "vertical", "Configured binding did not replace default Command-D"
            rpc("debug.key", dispatch=True, chord="ctrl+shift+j")
            after_control = cli("panes", "list")
            assert len(after_control) == 3, f"Control binding produced the wrong pane count: {after_control}"
            rpc("debug.key", dispatch=True, chord="j")
            assert len(cli("panes", "list")) == 4, "Unmodified binding bypassed application routing"
            for chord in ["cmd+shift+1", "cmd+shift+="]:
                old_ids = {pane["id"] for pane in cli("panes", "list")}
                rpc("debug.key", dispatch=True, chord=chord)
                eventually(f"shifted punctuation binding {chord}", lambda: len(cli("panes", "list")) == 5)
                new_id = ({pane["id"] for pane in cli("panes", "list")} - old_ids).pop()
                cli("panes", "close", "--pane", new_id, "--force")
            for pane in cli("panes", "list"):
                pane_id = pane["id"]
                cli("panes", "send", "--pane", pane_id, "--text", f"printf '\\nSLATE_READY_%s\\n' '{pane_id}'\r")
                eventually(f"render fixture {pane_id}", lambda: "SLATE_READY_" + pane_id in cli("panes", "capture", "--pane", pane_id)["text"])
            rpc("debug.screenshot", path=str(ROOT / "artifacts/app-settings-light.png"))
            valid = rpc("config.get")["current"]
            config.write_text("[terminal]\nfont_size = -3\n")
            eventually("invalid in-place edit reported", lambda: rpc("config.get")["error"] is not None)
            assert rpc("config.get")["current"] == valid, "Invalid config replaced the last valid settings"
            cli("rpc", "config.reload", success=False)
            config.write_text('[terminal]\nshell = "/bin"\n')
            cli("config", "reload", success=False)
            assert "regular executable" in cli("config", "get")["error"]
            assert cli("config", "get")["current"] == valid
            replace_config('[appearance]\ntheme = "dark"\n[terminal]\nshell = "/bin/bash"\nfont_size = 19\n')
            eventually("valid edit recovers", lambda: rpc("config.get")["error"] is None)
            assert "terminal.shell" in rpc("config.get")["restartRequired"]
            assert rpc("debug.inspect")["panes"][0]["surface"] == before["surface"]
            t2 = cli("tabs", "new")["tabId"]
            t3 = cli("tabs", "new")["tabId"]
            assert rpc("workspace.get")["groups"][0]["tabs"] == ["t1", t2, t3], "Native insertion reversed the tab order"
            assert rpc("debug.reorder", tab=t3, index=0)["selectionPreserved"]
            eventually("native reorder autosaved without a synchronizing RPC read", lambda: json.loads(state.read_text())["groups"][0]["tabs"] == [t3, "t1", t2])
            t4 = cli("tabs", "new")["tabId"]
            rpc("debug.detach", tab=t4)
            transient = cli("panes", "split", "--right", "--pane", "p1")["paneId"]
            cli("panes", "close", "--pane", transient, "--force")
            rpc("command.run", id="pane.focus", pane="p2")
            snapshot = rpc("workspace.get")
            assert len(snapshot["groups"]) == 2
            eventually("snapshot persisted", lambda: state.exists() and json.loads(state.read_text())["keyTabID"] == snapshot["keyTabID"])
            stop()
            start()
            restored = rpc("workspace.get")
            assert restored == snapshot, (restored, snapshot)
            assert len(rpc("debug.inspect")["nativeTabGroups"]) == 2
            cli("panes", "send", "--pane", "p1", "--text", "printf '\\nSLATE_RESTART_PID=%s\\n' \"$$\"\r")
            eventually("new shell on restored identity", lambda: re.search(r"SLATE_RESTART_PID=\d+", cli("panes", "capture", "--pane", "p1")["text"]))
            new_pid = re.search(r"SLATE_RESTART_PID=(\d+)", cli("panes", "capture", "--pane", "p1")["text"]).group(1)
            assert new_pid != old_pid
            assert cli("panes", "split", "--right", "--pane", "p1")["paneId"] == "p" + str(int(transient[1:]) + 1)
            preserved = state.read_bytes()
            replace_config("[layout]\nrestore_workspace = false\n")
            eventually("restoration disabled", lambda: not rpc("config.get")["current"]["layout"]["restore_workspace"])
            cli("tabs", "new")
            assert state.read_bytes() == preserved
            stop()
            start()
            assert [p["id"] for p in cli("panes", "list")] == ["p1"]
            assert state.read_bytes() == preserved
            stop()
            corrupt = b"{ unfinished workspace"
            state.write_bytes(corrupt)
            replace_config("[layout]\nrestore_workspace = true\n")
            start()
            assert rpc("config.get")["workspace"]["savingSuspended"] is True
            assert rpc("config.get")["workspace"]["error"]
            cli("panes", "split", "--right", "--pane", "p1")
            assert state.read_bytes() == corrupt, "Recovery silently overwrote the corrupt file"
            stop()
            snapshot["panes"][1]["type"] = {"browser": {}}
            for tab in snapshot["tabs"]:
                tab["terminalHistory"] = [p for p in tab["terminalHistory"] if p != "p2"]
            state.write_text(json.dumps(snapshot))
            start()
            panes = rpc("debug.inspect")["panes"]
            browser = next(p for p in panes if p["paneId"] == "p2")
            assert browser["surface"] == 0 and browser["attached"]
            assert rpc("browser.eval", pane="p2", script="typeof window.workspace") == "undefined"
            cli("panes", "capture", "--pane", "p2", success=False)
            rpc("debug.screenshot", path=str(ROOT / "artifacts/app-restored-browser.png"))
            stop()
            snapshot["panes"][1]["type"] = {"registered": {"_0": "missing.plugin"}}
            unavailable = json.dumps(snapshot).encode()
            state.write_bytes(unavailable)
            start()
            assert rpc("config.get")["workspace"]["savingSuspended"] is True
            assert "not registered" in rpc("config.get")["workspace"]["error"]
            assert [p["id"] for p in cli("panes", "list")] == ["p1"]
            assert state.read_bytes() == unavailable, "Unavailable registration silently destroyed the saved workspace"
            print("PASS settings: atomic/in-place reload, live font/theme/keys, last-valid retention, restart flags, abrupt restart, IDs/groups, disabled restore, corrupt-state preservation, live browser restoration, unavailable-type recovery without placeholders")
        finally:
            stop()
