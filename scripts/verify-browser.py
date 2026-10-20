#!/usr/bin/env python3
"""Exercise the embedded WebKit implementation against a local, owned HTTP fixture."""
import http.server
import json
import os
import pathlib
import shlex
import signal
import socket
import subprocess
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = pathlib.Path(os.environ.get("SLATE_TERM_TEST_APP", ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal"))
CLI = APP.parent.parent / "Frameworks/SlateRuntime.framework/Helpers/slate-term"


def eventually(label, condition, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {label}")


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


slow_started = threading.Event()


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/slow"):
            slow_started.set()
            time.sleep(3)
        page = b'<!doctype html><title>Slate Browser Fixture</title><style>body{font:18px system-ui;margin:40px}</style><h1>Working browser</h1><input id="name" aria-label="Name"><button id="go" onclick="document.querySelector(\'#result\').textContent=document.querySelector(\'#name\').value">Submit</button><p id="result"></p><a href="/next">Next page</a>'
        if self.path.startswith("/with-frame"):
            page += b'<iframe src="data:text/html,unprivileged subframe"></iframe>'
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        try:
            self.wfile.write(page)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix="slate-browser-", dir="/tmp") as temporary:
        directory = pathlib.Path(temporary)
        ready = directory / "socket"
        environment = dict(os.environ, SLATE_TERM_INTEGRATION="1", SLATE_TERM_STATE_DIR=temporary,
                           SLATE_TERM_CONFIG_FILE=str(directory / "config.toml"), SLATE_TERM_SOCKET_FILE=str(ready))
        with (ROOT / "artifacts/browser-process.log").open("w") as log:
            app = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
            try:
                eventually("app readiness", lambda: ready.exists() and app.poll() is None)
                environment["SLATE_TERM_SOCKET"] = ready.read_text().strip()

                def cli(*args, success=True):
                    result = subprocess.run([str(CLI), *args, "--json"], env=environment, capture_output=True, text=True, timeout=20)
                    if not success:
                        assert result.returncode != 0, args
                        return result.stderr
                    assert result.returncode == 0, result.stderr
                    return json.loads(result.stdout)

                def rpc(method, **params):
                    return cli("rpc", method, "--params", json.dumps(params))

                def evaluate(script, pane="p1"):
                    return rpc("browser.eval", pane=pane, script=script)

                navigation = rpc("api.describe")["browserNavigation"]
                assert navigation["localFiles"] and "file" in navigation["schemes"]
                assert navigation["fileReadAccess"] == "containingDirectory" and not navigation["pluginBridge"]
                pid_file = directory / "original-pid"
                cli("panes", "send", "--pane", "p1", "--text", f"printf '%s' \"$$\" > {shlex.quote(str(pid_file))}\r")
                eventually("original shell PID", lambda: pid_file.exists() and pid_file.read_text().strip().isdigit())
                old_pid = int(pid_file.read_text())
                sibling = cli("panes", "split", "--right", "--pane", "p1")["paneId"]
                cli("panes", "focus", "--pane", "p1")
                original_layout = cli("layout", "get")
                sibling_surface = next(p["surface"] for p in rpc("debug.inspect")["panes"] if p["paneId"] == sibling)
                menu = rpc("debug.paneTypeMenu")
                assert next(item for item in menu if item["type"] == "terminal")["checked"]
                rpc("debug.paneTypeMenu", select="private-browser", answer="switch")
                eventually("switch terminates old shell", lambda: not alive(old_pid))
                assert cli("layout", "get") == original_layout
                url = f"http://127.0.0.1:{server.server_port}/"
                loaded = rpc("browser.navigate", pane="p1", url=url)
                assert loaded["title"] == "Slate Browser Fixture", {"response": loaded, "document": evaluate("document.documentElement.outerHTML"), "current": rpc("browser.get", pane="p1")}
                with_frame = rpc("browser.navigate", pane="p1", url=url + "with-frame")
                assert with_frame["title"] == "Slate Browser Fixture", "Blocked subframe failed the main navigation"
                evaluate("document.querySelector('#name').focus(); true")
                other_tab = cli("tabs", "new", "--focus-policy", "new")["tabId"]
                cli("tabs", "focus", "--tab", "t1")
                rpc("debug.key", chord="j", dispatch=True)
                eventually("browser input focus after native tab activation", lambda: evaluate("document.querySelector('#name').value") == "j")
                cli("tabs", "close", "--tab", other_tab, "--force")
                assert rpc("debug.browserAddress", pane="p1")["addressFocused"]
                address_tab = cli("tabs", "new", "--focus-policy", "new")["tabId"]
                cli("tabs", "focus", "--tab", "t1")
                rpc("debug.key", chord="j", dispatch=True)
                address_state = next(p["browser"] for p in rpc("debug.inspect")["panes"] if p["paneId"] == "p1")
                assert address_state["addressFocused"] and address_state["address"] == "j", address_state
                cli("tabs", "close", "--tab", address_tab, "--force")
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
                    peer.settimeout(5)
                    peer.connect(environment["SLATE_TERM_SOCKET"])
                    with peer.makefile("rwb") as stream:
                        stream.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "hello", "params": {"protocolVersion": 1}}).encode() + b"\n")
                        stream.flush()
                        assert json.loads(stream.readline())["result"]["protocolVersion"] == 1
                        stream.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "browser.navigate", "params": {"pane": "p1", "url": url + "slow"}}).encode() + b"\n")
                        stream.flush()
                        assert slow_started.wait(3)
                eventually("disconnected navigation is cancelled", lambda: not rpc("browser.get", pane="p1")["loading"], timeout=1)
                rpc("browser.navigate", pane="p1", url=url)
                assert evaluate("typeof window.workspace") == "undefined"
                assert evaluate("document.querySelector('h1').textContent") == "Working browser"
                evaluate("document.body.insertAdjacentHTML('beforeend','<div contenteditable aria-label=Editor>draft</div><div contenteditable=plaintext-only aria-label=Plain>plain</div>');true")
                snapshot = rpc("browser.snapshot", pane="p1")
                for name in ["Editor", "Plain"]:
                    editor = next(element for element in snapshot["elements"] if element["name"] == name)
                    rpc("browser.fill", pane="p1", ref=editor["ref"], text="Edited 日本語")
                    assert evaluate("document.querySelector('[aria-label=" + name + "]').textContent") == "Edited 日本語"
                name_ref = next(element["ref"] for element in snapshot["elements"] if element["name"] == "Name")
                submit_ref = next(element["ref"] for element in snapshot["elements"] if element["name"] == "Submit")
                assert snapshot["title"] == "Slate Browser Fixture" and snapshot["documentId"]
                assert evaluate("typeof window.__slateBrowserAutomation") == "undefined", "Automation state leaked into page world"
                evaluate("window.inputEvents=0;document.querySelector('#name').addEventListener('input',()=>window.inputEvents++);true")
                rpc("browser.fill", pane="p1", ref=name_ref, text="Automation 日本語")
                rpc("browser.click", pane="p1", ref=submit_ref)
                assert evaluate("document.querySelector('#result').textContent") == "Automation 日本語"
                assert evaluate("window.inputEvents") == 1
                evaluate("document.body.insertAdjacentHTML('beforeend','<div id=cover style=\"position:fixed;inset:0;z-index:999;background:white\"></div>');document.querySelector('#name').value='covered-input';true")
                cli("rpc", "browser.click", "--params", json.dumps({"pane":"p1","ref":submit_ref}), success=False)
                assert evaluate("document.querySelector('#result').textContent") == "Automation 日本語", "Covered control was activated"
                evaluate("document.querySelector('#cover').remove();true")
                evaluate("document.body.insertAdjacentHTML('beforeend','<button class=duplicate>One</button><button class=duplicate>Two</button><input id=locked readonly value=unchanged><select id=choices><option value=a>A</option><option value=b>B</option></select>');true")
                for method, params in [("browser.click", {"selector":".duplicate"}), ("browser.fill", {"selector":"#locked", "text":"changed"}), ("browser.select", {"selector":"#choices", "values":["missing"]})]:
                    cli("rpc", method, "--params", json.dumps(dict(pane="p1", **params)), success=False)
                assert evaluate("document.querySelector('#locked').value") == "unchanged"
                assert evaluate("document.querySelector('#choices').value") == "a"
                rpc("browser.select", pane="p1", selector="#choices", values=["b"])
                assert evaluate("document.querySelector('#choices').value") == "b"
                evaluate("setTimeout(()=>document.body.insertAdjacentHTML('beforeend','<p id=late>Ready</p>'),200);true")
                assert rpc("browser.wait", pane="p1", selector="#late", state="visible", timeoutMilliseconds=5000)["matched"]
                start_wait = time.monotonic()
                cli("rpc", "browser.wait", "--params", json.dumps({"pane":"p1","selector":"#absent","timeoutMilliseconds":100}), success=False)
                assert time.monotonic()-start_wait < 3, "Wait ignored its deadline"
                evaluate("document.body.insertAdjacentHTML('beforeend','<div id=spacer style=height:2000px></div><button id=far onclick=window.farClicked=true>Far action</button>');true")
                rpc("browser.click", pane="p1", selector="#far")
                assert evaluate("window.farClicked===true && scrollY>0")
                rpc("browser.scroll", pane="p1", x=0, y=-10000)
                assert evaluate("scrollY") == 0
                truncated = rpc("browser.snapshot", pane="p1", maxElements=1)
                assert len(truncated["elements"]) == 1 and truncated["truncated"]
                evaluate("window.wasCached=false;addEventListener('pageshow',event=>window.wasCached=event.persisted);true")
                rpc("browser.navigate", pane="p1", url=url+"next")
                failure = cli("rpc", "browser.click", "--params", json.dumps({"pane":"p1","ref":submit_ref}), success=False)
                assert "stale" in failure.lower(), failure
                evaluate("history.back();true")
                eventually("cached browser document restored", lambda: rpc("browser.get", pane="p1")["url"] == url and evaluate("window.wasCached===true"))
                failure = cli("rpc", "browser.click", "--params", json.dumps({"pane":"p1","ref":submit_ref}), success=False)
                assert "stale" in failure.lower(), "Cached restoration revived an old automation reference"
                evaluate("document.body.replaceChildren(document.createTextNode('x'.repeat(20000)));true")
                clipped = rpc("browser.snapshot", pane="p1")
                assert len(clipped["text"]) == 16384 and clipped["truncated"], "Single text-node clipping was not reported"
                rpc("browser.navigate", pane="p1", url=url)
                rendered = {p["paneId"]: p for p in rpc("debug.inspect")["panes"]}
                assert abs(rendered["p1"]["width"] / (rendered["p1"]["width"] + rendered[sibling]["width"]) - original_layout["fraction"]) < 0.003, {"rendered": rendered, "inspection": rpc("debug.inspect"), "model": cli("layout", "get")}
                assert rendered[sibling]["surface"] == sibling_surface, "Switching a pane replaced its sibling"
                cli("browser", "fill", "--pane", "p1", "--selector", "#name", "--text", "日本語")
                cli("browser", "click", "--pane", "p1", "--selector", "#go")
                assert evaluate("document.querySelector('#result').textContent") == "日本語"
                evaluate("localStorage.setItem('private','first');document.cookie='private=first';true")
                cli("panes", "type", "--pane", sibling, "--type", "private-browser", "--force")
                rpc("browser.navigate", pane=sibling, url=url)
                assert evaluate("localStorage.getItem('private')", sibling) is None
                assert evaluate("document.cookie", sibling) == ""
                cli("panes", "type", "--pane", sibling, "--type", "terminal", "--force")
                assert cli("layout", "get") == original_layout
                cli("rpc", "browser.navigate", "--params", json.dumps({"pane": "p1", "url": "file://remote/unsupported.html"}), success=False)
                local_page = directory / "local page 日本語.html"
                local_page.write_text('<!doctype html><title>Local Browser Fixture</title><h1>Local preview</h1>')
                assert cli("browser", "navigate", "--pane", "p1", "--url", str(local_page))["title"] == "Local Browser Fixture"
                assert evaluate("typeof workspace") == "undefined"
                rpc("browser.navigate", pane="p1", url=url)
                rpc("browser.screenshot", pane="p1", path=str(ROOT / "artifacts/browser-content.png"))
                rpc("debug.screenshot", path=str(ROOT / "artifacts/browser-workspace.png"))
                cli("panes", "focus", "--pane", "p1")
                rpc("debug.paneTypeMenu", select="terminal", answer="switch")
                new_pid_file = directory / "replacement-pid"
                cli("panes", "send", "--pane", "p1", "--text", f"printf '%s' \"$$\" > {shlex.quote(str(new_pid_file))}\r")
                eventually("replacement shell works", lambda: new_pid_file.exists() and new_pid_file.read_text().strip().isdigit())
                assert int(new_pid_file.read_text()) != old_pid
                rpc("debug.paneTypeMenu", select="private-browser", answer="switch")
                rpc("browser.navigate", pane="p1", url=url)
                assert evaluate("localStorage.getItem('private')") is None, "Switching restored discarded browser data"
                assert evaluate("document.cookie") == ""
                assert cli("layout", "get") == original_layout
                print("PASS: native Pane menu, destructive type replacement, new shell, real WebKit navigation/JS/snapshot, browser-store isolation, and bridge absence")
            finally:
                if app.poll() is None:
                    os.killpg(app.pid, signal.SIGTERM)
                    try:
                        app.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        os.killpg(app.pid, signal.SIGKILL)
                        app.wait(timeout=5)
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=3)
