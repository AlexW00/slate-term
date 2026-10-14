#!/usr/bin/env python3
"""Owned native app: true header-title centering, collision bounds and inline renaming."""
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
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.04)
    raise AssertionError("Timed out: " + label)


with tempfile.TemporaryDirectory(prefix="slate-pane-titles-", dir="/tmp") as temporary:
    directory = pathlib.Path(temporary)
    ready = directory / "ready"
    config = directory / "config.toml"
    config.write_text('[appearance]\ntheme = "light"\n')
    environment = {key: value for key, value in os.environ.items() if not key.startswith("SLATE_TERM_")}
    environment.update(SLATE_TERM_INTEGRATION="1", SLATE_TERM_STATE_DIR=temporary,
                       SLATE_TERM_SOCKET_FILE=str(ready), SLATE_TERM_CONFIG_FILE=str(config))
    ARTIFACTS.mkdir(exist_ok=True)
    with (ARTIFACTS / "pane-titles-process.log").open("w") as log:
        app = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
        try:
            eventually("owned app readiness", lambda: ready.exists() and app.poll() is None)
            environment["SLATE_TERM_SOCKET"] = ready.read_text().strip()

            def cli(*args):
                result = subprocess.run([str(CLI), *args, "--json"], env=environment,
                                        text=True, capture_output=True, timeout=20)
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)

            def rpc(method, **params):
                return cli("rpc", method, "--params", json.dumps(params))

            def check(pane):
                header = rpc("debug.paneHeader", pane=pane)
                assert header["titleCentered"], header
                assert abs(header["titleCenterX"] - header["headerWidth"] / 2) < 0.5, header
                assert header["titleLeadingX"] >= header["typeTrailingX"] + 7.5, header
                assert header["titleTrailingX"] <= header["actionsLeadingX"] - 5.5, header
                assert header["titleTrailingX"] > header["titleLeadingX"], header
                assert header["actionsBeforeClose"] and header["closeVisible"] and header["dragHandleVisible"], header
                assert header["headerActions"] == [], 'No built-in copy button should remain'
                return header

            def capture(name):
                path = ARTIFACTS / f"pane-titles-{name}.png"
                rpc("debug.screenshot", path=str(path))
                dimensions = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
                                            check=True, text=True, capture_output=True, timeout=5).stdout
                width = int(dimensions.split("pixelWidth: ")[1].splitlines()[0])
                assert width >= 1000, "Capture caught a native window animation: " + dimensions

            rpc("debug.activate", tab="t1")
            time.sleep(1)
            rpc("debug.paneHeader", pane="p1", rename="Build")
            check("p1")
            p2 = cli("panes", "split", "--right", "--pane", "p1")["paneId"]
            cli("panes", "type", "--pane", p2, "--type", "browser", "--force")
            eventually("browser ready", lambda: rpc("browser.get", pane=p2)["title"] == "New Browser"
                       and not rpc("browser.get", pane=p2)["loading"])
            rpc("browser.eval", pane=p2, script="document.title = 'Documentation'")
            eventually("live browser title", lambda: check(p2)["title"] == "Documentation")
            check("p1")
            capture("light")

            # The field/editor keeps its centered region through commit, cancel and blur.
            header = rpc("debug.paneHeader", pane="p1", beginRename=True, draft="Cancelled draft")
            assert header["editing"] and header["draft"] == "Cancelled draft", header
            check("p1")
            rpc("debug.paneHeader", pane="p1", finish="cancel")
            assert check("p1")["title"] == "Build"
            rpc("debug.paneHeader", pane="p1", draft="Saved on blur", finish="blur")
            assert check("p1")["title"] == "Saved on blur"
            rpc("debug.paneHeader", pane="p1", rename="Build")
            assert check("p1")["title"] == "Build"

            rpc("debug.paneHeader", pane=p2, beginRename=True, draft="Documentation draft")
            rpc("browser.eval", pane=p2, script="document.title = 'Live update'")
            assert rpc("debug.paneHeader", pane=p2)["draft"] == "Documentation draft"
            rpc("debug.paneHeader", pane=p2, finish="cancel")
            eventually("cancel restores updated title", lambda: check(p2)["title"] == "Live update")
            rpc("browser.eval", pane=p2, script="document.title = 'Documentation'")
            eventually("restored browser title", lambda: check(p2)["title"] == "Documentation")

            long_title = "A deliberately long panel title — 日本語 — " * 8
            rpc("debug.paneHeader", pane="p1", rename=long_title)
            # Manual names normalize surrounding whitespace in Workspace.setManualTitle.
            header = check("p1")
            assert header["title"] == long_title.strip(), header
            for fraction in [0.25, 0.75, 0.5]:
                rpc("debug.divider", tab="t1", fraction=fraction)
                check("p1")
                check(p2)
                if fraction == 0.25:
                    capture("narrow-long")

            config.write_text('[appearance]\ntheme = "dark"\n')
            rpc("config.reload")
            rpc("debug.paneHeader", pane="p1", rename="Build")
            check("p1")
            check(p2)
            capture("dark")
            rpc("debug.paneHeader", pane=p2, beginRename=True)
            check(p2)
            capture("editing")
            rpc("debug.paneHeader", pane=p2, finish="cancel")

            # Empty titles still expose a usable edit region and restore live titles.
            rpc("debug.paneHeader", pane=p2, rename="")
            assert check(p2)["title"] == "Documentation"
            cli("panes", "type", "--pane", p2, "--type", "terminal", "--force")
            check(p2)
            print("PASS pane titles: centered on whole header, symmetric collision bounds, single/split/resized panes, long Unicode/live/empty titles, type replacement, inline commit/cancel/blur and light/dark captures")
        finally:
            if app.poll() is None:
                os.killpg(app.pid, signal.SIGTERM)
                try:
                    app.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(app.pid, signal.SIGKILL)
                    app.wait(timeout=5)
