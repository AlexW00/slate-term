#!/usr/bin/env python3
"""Owned native app: pane move validation/preview/commit/menu, retained content and screenshots.

Drives the same destination callbacks as native dragging, not physical pointer events.
"""
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal"
CLI = APP.parent.parent / "Helpers/slate-term"
ARTIFACTS = ROOT / "artifacts"


def eventually(label, condition, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(0.04)
    raise AssertionError(f"Timed out: {label}")


with tempfile.TemporaryDirectory(prefix="slate-pane-move-", dir="/tmp") as temporary:
    directory = pathlib.Path(temporary)
    ready = directory / "ready"
    config = directory / "config.toml"
    config.write_text('[appearance]\ntheme = "light"\n')
    environment = {key: value for key, value in os.environ.items() if not key.startswith("SLATE_TERM_")}
    environment.update(SLATE_TERM_INTEGRATION="1", SLATE_TERM_STATE_DIR=temporary,
                       SLATE_TERM_SOCKET_FILE=str(ready), SLATE_TERM_CONFIG_FILE=str(config))
    ARTIFACTS.mkdir(exist_ok=True)
    with (ARTIFACTS / "pane-movement-process.log").open("w") as log:
        app = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
        try:
            eventually("owned app readiness", lambda: ready.exists() and app.poll() is None)
            environment["SLATE_TERM_SOCKET"] = ready.read_text().strip()

            def cli(*args):
                result = subprocess.run([str(CLI), *args, "--json"], env=environment, text=True, capture_output=True, timeout=20)
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)

            def rpc(method, **params):
                return cli("rpc", method, "--params", json.dumps(params))

            def move(source, target, x=0.05, y=0.5, **params):
                return rpc("debug.paneMove", pane=source, target=target, x=x, y=y, **params)

            def state():
                return rpc("workspace.get")

            def capture(name):
                rpc("debug.screenshot", path=str(ARTIFACTS / f"pane-movement-{name}.png"))

            def panes():
                return {pane["paneId"]: pane for pane in rpc("debug.inspect")["panes"]}

            assert move("p1", "p1")["canDrag"], "A sole pane must be draggable into another window"
            p2 = cli("panes", "split", "--right")["paneId"]
            # Regression: moving the right sibling left/above used to paint the whole
            # left pane or span both current panes using projected window geometry.
            siblings = state()
            for theme in ["light", "dark"]:
                config.write_text(f'[appearance]\ntheme = "{theme}"\n')
                rpc("config.reload")
                for x, y, direction in [(.05, .5, "left"), (.95, .5, "right"), (.5, .95, "up"), (.5, .05, "down")]:
                    result = move(p2, "p1", x, y)
                    assert result["direction"] == direction and result["previewPanes"] == ["p1"], result
                    capture(f"siblings-{theme}-{direction}")
                    assert state() == siblings, "Preview mutated sibling layout"
                assert not move(p2, "p1", .5, .5)["preview"], "Center left a preview"
                rpc("debug.divider", fraction=0.1)
                assert move(p2, "p1")["previewPanes"] == ["p1"], "Collapsed sibling move was rejected at narrow width"
                capture(f"siblings-{theme}-narrow")
                assert not move(p2, "p1", cancel=True)["preview"]
                rpc("debug.divider", fraction=0.5)
            config.write_text('[appearance]\ntheme = "light"\n')
            rpc("config.reload")
            p3 = cli("panes", "split", "--down", "--pane", p2)["paneId"]
            for pane in ["p1", p2, p3]:
                cli("panes", "send", "--pane", pane, "--text", f"printf 'MOVE_%s:%s\\n' '{pane}' \"$$\"\r")
                eventually("terminal output", lambda: f"MOVE_{pane}:" in cli("panes", "capture", "--pane", pane)["text"])
                header = rpc("debug.paneHeader", pane=pane, rename={"p1": "Build", p2: "Server", p3: "Notes"}[pane])
                assert header["dragHandleVisible"] and header["closeVisible"]
            original = panes()
            sessions = {pane: rpc("context.get", pane=pane, scope="pane")["terminal"]["sessionId"] for pane in original}
            before = state()
            capture("light")
            cli("panes", "focus", "--pane", p3)
            rpc("debug.menuPreview", pane=p3, move=True, path=str(ARTIFACTS / "pane-movement-menu.png"))
            assert panes()[p3]["firstResponder"] and panes()[p3]["terminalFocus"], "Cancelled move menu stole typing focus"
            result = move(p3, "p1")
            assert result["direction"] == "left" and result["previewPanes"] == ["p1"], result
            assert state() == before, "Preview mutated workspace"
            capture("preview-left")
            assert move(p3, "p1", cancel=True)["preview"] is False
            assert state() == before, "Cancellation mutated workspace"
            for source, target, x, y in [(p3, p3, .05, .5), (p3, "p1", .5, .5), (p3, "p1", -1., .5)]:
                assert not move(source, target, x, y, drop=True)["accepted"]
                assert state() == before

            other_tab = cli("tabs", "new")["tabId"]
            other = cli("tabs", "list")[-1]["focusedPane"]
            assert move(p3, other, drop=True)["accepted"]
            assert rpc("pane.inspect", pane=p3)["tabId"] == other_tab
            assert move(p3, p2, .5, .05, drop=True)["accepted"]
            cli("tabs", "close", "--tab", other_tab, "--force")
            cli("command", "run", "pane.zoom", "--pane", "p1")
            zoomed = state()
            assert not move("p1", p2, drop=True)["accepted"]
            assert state() == zoomed
            cli("command", "run", "pane.zoom", "--pane", "p1")

            for x, y, direction in [(.05, .5, "left"), (.95, .5, "right"), (.5, .95, "up"), (.5, .05, "down")]:
                preview = move(p3, "p1", x, y)
                assert preview["direction"] == direction and preview["previewPanes"] == ["p1"], preview
                capture(f"nested-{direction}")
                result = move(p3, "p1", x, y, drop=True)
                assert result["accepted"] and result["direction"] == direction and not result["preview"], result
                layout = cli("layout", "get")
                pair = layout["first"]
                assert pair["axis"] == ("horizontal" if direction in ["left", "right"] else "vertical")
                assert pair["first"]["pane"] == (p3 if direction in ["left", "up"] else "p1")
                assert pair["second"]["pane"] == ("p1" if direction in ["left", "up"] else p3)
                assert layout["second"] == {"kind": "pane", "pane": p2}, layout
                assert state()["tabs"][0]["focusedPane"] == p3
                current = panes()
                assert all(current[p]["surface"] == original[p]["surface"] and current[p]["attached"] for p in original)
                assert current[p3]["firstResponder"] and current[p3]["terminalFocus"]
                assert sum(p["terminalFocus"] for p in current.values()) == 1
                for pane in original:
                    assert rpc("context.get", pane=pane, scope="pane")["terminal"]["sessionId"] == sessions[pane]
                    assert f"MOVE_{pane}:" in cli("panes", "capture", "--pane", pane)["text"]

            # The handle's click/keyboard menu invokes the same move operation.
            assert move(p3, "p1", menu=True, direction="right")["accepted"]
            cli("panes", "type", "--pane", p2, "--type", "browser", "--force")
            eventually("browser ready", lambda: rpc("browser.get", pane=p2)["title"] == "New Browser" and not rpc("browser.get", pane=p2)["loading"])
            rpc("browser.eval", pane=p2, script="window.moveSentinel = 'retained'; document.title = 'Documentation'; document.body.innerHTML = '<h1>Documentation</h1><p>This page stays loaded when its pane moves.</p>'")
            assert move(p2, "p1", .5, .05, drop=True)["accepted"]
            assert rpc("browser.eval", pane=p2, script="window.moveSentinel") == "retained"
            assert rpc("debug.paneHeader", pane=p2)["title"] == "Server", "Manual title lost"
            # A web view remains a valid destination, not just a source.
            assert move(p3, p2, .95, .5)["previewPanes"] == [p2]
            capture("browser-preview")
            assert move(p3, p2, .95, .5, drop=True)["accepted"]
            assert rpc("browser.eval", pane=p2, script="window.moveSentinel") == "retained"
            assert rpc("browser.eval", pane=p2, script="window.moveSentinel") == "retained"
            capture("after")
            config.write_text('[appearance]\ntheme = "dark"\n')
            rpc("config.reload")
            capture("dark")
            persisted = json.loads((directory / "state/workspace.json").read_text())
            assert persisted["tabs"][0]["layout"] == state()["tabs"][0]["layout"]
            print("PASS pane movement: all edges, cancellation/invalid/self/zoom rejection, cross-tab round trip, nested collapse, retained surfaces/sessions/browser state, focus, menu, persistence, grip placement and light/dark previews")
        finally:
            if app.poll() is None:
                os.killpg(app.pid, signal.SIGTERM)
                try:
                    app.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(app.pid, signal.SIGKILL)
                    app.wait(timeout=5)
