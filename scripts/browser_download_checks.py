"""Browser download checks inside the existing VM-owned web AppFixture."""
import http.server
import json
import threading
import urllib.parse
import uuid
from pathlib import Path
from api_fixture import ROOT, eventually


def check_browser_downloads(app, plugin_pane, external_input=False):
    """Use genuine WebKit downloads; never launch an app or GUI on the host."""
    output = app.root / "browser-downloads"
    output.mkdir()
    captures = ROOT / "artifacts/browser-downloads"
    captures.mkdir(exist_ok=True)
    original_tab = app.rpc("pane.inspect", pane=plugin_pane)["tabId"]
    tabs = []
    releases = {}
    evidence = []
    content = b"Slate download fixture\n"

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            parsed = urllib.parse.urlsplit(self.path)
            path = parsed.path
            if path == "/redirect":
                self.send_response(302)
                self.send_header("Location", "/file")
                self.end_headers()
                return
            if path == "/":
                data = b"""<!doctype html><title>Download fixture</title>
<a id="file" href="/file">Attachment</a>
<a id="attribute" download="attribute.txt" href="/attribute">Download attribute</a>
<a id="unsupported" href="/unsupported">Unsupported response</a>
<a id="redirect" href="/redirect">Redirect</a>
<a id="cookie" href="/cookie">Session download</a>
<a id="slow" href="/slow">Slow download</a>
<button id="blob" onclick="window.blobClicked=true;const a=document.createElement('a');a.href=window.URL.createObjectURL(new Blob(['blob fixture bytes'],{type:'text/plain'}));a.download='blob.txt';window.blobAnchor=a;a.click()">Blob download</button>"""
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
            else:
                data = content
                if path == "/cookie":
                    data = self.headers.get("Cookie", "").encode()
                if path == "/slow":
                    data = b"x" * 262144
                self.send_response(200)
                self.send_header("Content-Type", "text/plain" if path == "/attribute" else "application/x-slate-download")
                if path != "/unsupported" and path != "/attribute":
                    self.send_header("Content-Disposition", 'attachment; filename="fixture.txt"')
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                if path == "/slow":
                    self.wfile.write(data[:1024])
                    self.wfile.flush()
                    key = urllib.parse.parse_qs(parsed.query)["id"][0]
                    releases[key].wait(20)
                    self.wfile.write(data[1024:])
                else:
                    self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    base = f"http://127.0.0.1:{server.server_port}"

    def evaluate(pane, script):
        return app.rpc("browser.eval", pane=pane, script=script)

    def create(mode):
        tab = app.rpc("command.run", id="tab.new", focus="new")["tabId"]
        tabs.append(tab)
        pane = app.rpc("context.inspect")["focusedPaneId"]
        app.rpc("command.run", id="pane.type", pane=pane, type=mode, force=True)
        app.rpc("browser.navigate", pane=pane, url=base + "/")
        return tab, pane

    def status(pane, download):
        return app.rpc("browser.download", pane=pane, downloadId=download["downloadId"])

    def click(pane, selector):
        point = evaluate(pane, """(()=>{
          const r=document.querySelector(%s).getBoundingClientRect();
          return {x:r.x+r.width/2,y:r.y+r.height/2};
        })()""" % json.dumps(selector))
        app.rpc("debug.browserClick", pane=pane, **point)

    def start(pane, selector="#file"):
        before = {row["downloadId"] for row in app.rpc("browser.downloads", pane=pane)["downloads"]}
        print("DOWNLOAD fixture starting " + selector, flush=True)
        click(pane, selector)
        eventually("WebKit asks for download destination " + selector, lambda: any(
            row["downloadId"] not in before and row["state"] == "awaitingDestination"
            for row in app.rpc("browser.downloads", pane=pane)["downloads"]))
        download = next(row for row in app.rpc("browser.downloads", pane=pane)["downloads"] if row["downloadId"] not in before)
        evidence.append(download)
        return download

    def complete(pane, download, path, expected):
        eventually("download completes", lambda: status(pane, download)["state"] in ["completed", "failed"])
        row = status(pane, download)
        assert row["state"] == "completed" and Path(row["path"]).resolve() == path.resolve(), row
        assert path.read_bytes() == expected
        assert not list(output.glob(".slate-download-*"))
        app.rpc("browser.saveDownload", pane=pane, downloadId=download["downloadId"], path=str(path), error=-32050)
        app.rpc("browser.cancelDownload", pane=pane, downloadId=download["downloadId"], error=-32050)
        evidence.append(row)

    def slow(pane):
        key = str(uuid.uuid4())
        releases[key] = threading.Event()
        evaluate(pane, f"document.querySelector('#slow').href='/slow?id={key}';true")
        return start(pane, "#slow"), releases[key]

    try:
        normal_tab, normal = create("browser")
        _, private = create("private-browser")
        app.cli("tabs", "focus", "--tab", normal_tab)
        evaluate(normal, "document.cookie='downloadSession=normal;path=/';true")
        pending = start(normal)
        assert app.cli("browser", "downloads", "--pane", normal)["downloads"][-1]["downloadId"] == pending["downloadId"]
        app.rpc("browser.download", pane=private, downloadId=pending["downloadId"], error=-32050)
        existing = output / "existing.txt"
        existing.write_text("preserve")
        app.rpc("browser.saveDownload", pane=normal, downloadId=pending["downloadId"], path=str(existing), error=-32050)
        app.rpc("browser.saveDownload", pane=normal, downloadId=pending["downloadId"], path=str(output / "missing" / "file"), error=-32602)
        assert status(normal, pending)["state"] == "awaitingDestination"
        app.rpc("debug.screenshot", tab=normal_tab, sheet=True, path=str(captures / "save-sheet.png"))
        saved = output / "attachment.txt"
        if external_input:
            print("DOWNLOAD_NATIVE_SAVE_READY " + str(saved), flush=True)
            eventually("external native Save confirmation", lambda: status(normal, pending)["state"] == "completed", timeout=180)
        else:
            app.cli("browser", "save-download", "--pane", normal, "--download-id", pending["downloadId"], "--path", str(saved))
        complete(normal, pending, saved, content)
        if external_input:
            print("PASS external native Save confirmation and downloaded file bytes", flush=True)
        assert existing.read_text() == "preserve"

        for selector, expected in [("#attribute", content), ("#unsupported", content), ("#redirect", content), ("#blob", b"blob fixture bytes")]:
            pending = start(normal, selector)
            path = output / (selector[1:] + ".txt")
            payload = dict(pane=normal, downloadId=pending["downloadId"], path=str(path))
            app.rpc("debug.pluginEval", pane=plugin_pane,
                    script="workspace.browser.saveDownload(" + json.dumps(payload) + ")")
            complete(normal, pending, path, expected)

        # WebKit must preserve each browser's cookie store instead of refetching the URL.
        evaluate(private, "document.cookie='downloadSession=private;path=/';true")
        for pane, session in [(normal, "normal"), (private, "private")]:
            app.rpc("debug.activate", tab=app.rpc("pane.inspect", pane=pane)["tabId"])
            pending = start(pane, "#cookie")
            path = output / (session + "-cookie.txt")
            app.rpc("browser.saveDownload", pane=pane, downloadId=pending["downloadId"], path=str(path))
            eventually("cookie download completes", lambda: status(pane, pending)["state"] == "completed")
            assert f"downloadSession={session}" in path.read_text()
            assert f"downloadSession={'private' if session == 'normal' else 'normal'}" not in path.read_text()

        app.rpc("debug.activate", tab=normal_tab)
        pending = start(normal)
        app.rpc("browser.navigate", pane=normal, url=base + "/")
        assert status(normal, pending)["state"] == "awaitingDestination"
        cancelled = app.cli("browser", "cancel-download", "--pane", normal, "--download-id", pending["downloadId"])
        assert cancelled["state"] == "cancelled"
        app.rpc("browser.cancelDownload", pane=normal, downloadId=pending["downloadId"], error=-32050)

        # Cancellation removes owned partial bytes without creating the requested final file.
        pending, release = slow(normal)
        path = output / "cancelled.txt"
        app.rpc("browser.saveDownload", pane=normal, downloadId=pending["downloadId"], path=str(path))
        assert status(normal, pending)["state"] == "downloading"
        assert not path.exists()
        app.rpc("browser.showDownloads", pane=normal)
        app.rpc("debug.screenshot", pane=normal, downloads=True, path=str(captures / "downloads-progress.png"))
        app.rpc("debug.browserDownload", pane=normal, downloadId=pending["downloadId"], action="cancel")
        assert status(normal, pending)["state"] == "cancelled"
        release.set()
        eventually("cancel removes private staging", lambda: not list(output.glob(".slate-download-*")))
        assert not path.exists()

        # A file created after destination selection must also survive completion.
        pending, release = slow(normal)
        path = output / "racing.txt"
        app.rpc("browser.saveDownload", pane=normal, downloadId=pending["downloadId"], path=str(path))
        path.write_text("keep racing file")
        release.set()
        eventually("existing destination rejects final publication", lambda: status(normal, pending)["state"] == "failed")
        assert path.read_text() == "keep racing file"
        assert not list(output.glob(".slate-download-*"))

        # Closing a browser owner drains its waiting destination and active transfer.
        pending = start(normal)
        retired = pending["downloadId"]
        app.rpc("command.run", id="pane.type", pane=normal, type="terminal", force=True)
        app.rpc("command.run", id="pane.type", pane=normal, type="browser", force=True)
        app.rpc("browser.download", pane=normal, downloadId=retired, error=-32050)
        app.rpc("browser.navigate", pane=normal, url=base + "/")
        pending, release = slow(normal)
        path = output / "closed.txt"
        app.rpc("browser.saveDownload", pane=normal, downloadId=pending["downloadId"], path=str(path))
        app.rpc("command.run", id="pane.type", pane=normal, type="terminal", force=True)
        release.set()
        eventually("owner close removes private staging", lambda: not list(output.glob(".slate-download-*")))
        assert not path.exists()
        (captures / "results.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print("PASS WebKit attachment/attribute/unsupported/redirect/blob downloads, session cookies, private isolation, native cancel, CLI/plugin parity, destination races and owner cleanup")
    finally:
        for release in releases.values():
            release.set()
        for tab in reversed(tabs):
            app.rpc("command.run", id="tab.close", tab=tab, force=True)
        app.cli("tabs", "focus", "--tab", original_tab)
        server.shutdown()
        server.server_close()
