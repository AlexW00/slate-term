#!/usr/bin/env python3
"""Native WebKit plugin gate: real modules/bridge, origins, scopes, persistence, disposal."""
import argparse
import http.server
import json
import os
import pathlib
import signal
import struct
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--functional-only', action='store_true', help='Omit foreground screenshot checks; does not certify visual verification.')
args = parser.parse_args()

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = pathlib.Path(os.environ.get("SLATE_TERM_TEST_APP", ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal"))
CLI = APP.parent.parent / "Helpers/slate-term"


def eventually(label, condition, timeout=15):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(0.05)
    raise AssertionError(f"Timed out: {label}")


foreign_requests = []


class Foreign(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        foreign_requests.append(self.path)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"foreign page")

    def log_message(self, *_):
        pass


foreign = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Foreign)
thread = threading.Thread(target=foreign.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix="slate-plugins-", dir="/tmp") as temporary:
        directory = pathlib.Path(temporary)
        assets = directory / "assets"
        assets.mkdir()
        (assets / "index.html").write_text('''<!doctype html><meta name="color-scheme" content="light dark"><title>Notes Plugin</title><style>body{font:13px system-ui;margin:16px;height:calc(100vh - 32px);min-height:190px;display:flex;flex-direction:column;gap:12px}h1{font-size:20px;margin:0}p{margin:0}textarea{box-sizing:border-box;width:100%;flex:1;min-height:48px;font:inherit;padding:8px}button{align-self:flex-start;flex-shrink:0}</style><h1>Notes</h1><p id="status">Connecting…</p><textarea id="note" aria-label="Note">A real runtime plugin.</textarea><button id="send">Send to terminal</button><script type="module" src="./app.js"></script><iframe id="child" src="./child.html" hidden></iframe>''')
        (assets / "label.js").write_text('export const label="Connected to the active terminal";')
        (assets / "app.js").write_text('''import {label} from './label.js';
        try {window.initialContext=await workspace.context();document.querySelector('#status').textContent=label;window.fixtureReady=true;
        document.querySelector('#send').onclick=()=>workspace.terminal.send("printf 'SLATE_%s\\\\n' PLUGIN\\r");}
        catch(error){window.bridgeError=String(error);document.querySelector('#status').textContent=String(error);}
        ''')
        (assets / "child.html").write_text('''<!doctype html><script>let documentId;parent.document.addEventListener('slate-document-identity',event=>documentId=event.detail,{once:true});parent.document.dispatchEvent(new parent.Event('slate-document-query'));parent.postMessage({channel:'slate-request',documentId,id:999,method:'command.run',params:{id:'window.new'}},'*');</script>''')
        (assets / "escape").symlink_to("/etc", target_is_directory=True)
        manifest = directory / "notes.json"
        manifest.write_text(json.dumps({"id": "notes", "title": "Notes", "scope": "tab", "source": {"kind": "directory", "path": str(assets), "entry": "index.html"}}))
        ready = directory / "ready"
        environment = {key: value for key, value in os.environ.items() if not key.startswith("SLATE_TERM_")}
        environment.update(SLATE_TERM_INTEGRATION="1", SLATE_TERM_STATE_DIR=temporary,
                           SLATE_TERM_SOCKET_FILE=str(ready), SLATE_TERM_CONFIG_FILE=str(directory / "config.toml"))
        with (ROOT / "artifacts/plugins-process.log").open("w") as log:
            app = None

            def start():
                global app
                ready.unlink(missing_ok=True)
                process = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
                app = process
                eventually("plugin app readiness", lambda: ready.exists() and process.poll() is None)
                environment["SLATE_TERM_SOCKET"] = ready.read_text().strip()
                return process

            def stop():
                if app is not None and app.poll() is None:
                    os.killpg(app.pid, signal.SIGTERM)
                    try:
                        app.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        os.killpg(app.pid, signal.SIGKILL)
                        app.wait(timeout=5)

            try:
                app = start()

                def cli(*args, success=True):
                    result = subprocess.run([str(CLI), *args, "--json"], env=environment, capture_output=True, text=True, timeout=35)
                    if not success:
                        assert result.returncode != 0, args
                        return result.stderr
                    assert result.returncode == 0, result.stderr
                    return json.loads(result.stdout)

                def rpc(method, **params):
                    return cli("rpc", method, "--params", json.dumps(params))

                def evaluate(script, pane="p2"):
                    return rpc("debug.pluginEval", pane=pane, script=script)

                def info(pane="p2"):
                    return next(p["plugin"] for p in rpc("debug.inspect")["panes"] if p["paneId"] == pane)

                def failed_unregister_preserves_views():
                    before = cli("panes", "list")
                    catalog_path = directory / "state/plugins.json"
                    catalog_path.chmod(0o400)
                    try:
                        cli("plugins", "unregister", "notes", "--force", success=False)
                        assert cli("panes", "list") == before, "Failed unregister destroyed live panes"
                        assert evaluate("workspace.context().then(c=>c.activeTerminalPaneId)") == "p1"
                    finally:
                        catalog_path.chmod(0o600)

                eventually("fixture shell is ready for input", lambda: cli("panes", "capture", "--pane", "p1")["text"].rstrip().endswith("$"))
                assert cli("plugins", "validate", "--manifest", str(manifest))["valid"]
                assert cli("plugins", "register", "--manifest", str(manifest))["id"] == "notes"
                assert cli("plugins", "list")[0]["id"] == "notes"
                cli("plugins", "register", "--manifest", str(manifest), success=False)
                assert any(item["type"] == "notes" for item in rpc("debug.paneTypeMenu", pane="p1"))
                assert cli("panes", "split", "--right", "--pane", "p1")["paneId"] == "p2"
                rpc("debug.paneTypeMenu", select="notes", answer="switch")
                try:
                    eventually("static ES modules and isolated bridge", lambda: evaluate("window.fixtureReady===true"))
                except AssertionError:
                    print("PLUGIN_DIAGNOSTIC", info(), evaluate("({url:location.href,origin:location.origin,bridge:typeof window.workspace,error:window.bridgeError,html:document.documentElement.outerHTML})"), flush=True)
                    raise
                assert evaluate("window.initialContext.activeTerminalPaneId") == "p1"
                failed_unregister_preserves_views()
                event = evaluate("workspace.emit('test.plugin',{text:'日本語'})")
                assert event["source"] == {"kind": "plugin", "type": "notes", "instanceId": info()["instanceId"]}
                assert event["tab"] == "t1" and event["pane"] == "p2"
                assert "reservedTopic" in evaluate("workspace.emit('host.forged',null).then(()=> 'unexpected',error=>String(error))")
                assert "Unknown event parameter" in evaluate("workspace.call('events.emit',{topic:'test.forged',source:{kind:'host'}}).then(()=> 'unexpected',error=>String(error))")
                evaluate("(workspace.call('events.poll',{topics:['test.pending'],waitMilliseconds:25000}).catch(()=>{}),true)")
                eventually("document owns a suspended event request", lambda: rpc("events.head")["pendingPolls"] == 1)
                document_id = info().get("documentId")
                assert document_id, "Bridge does not identify the actual document"
                evaluate("(location.reload(),true)")
                eventually("Page-driven reload gets a fresh document identity", lambda: info().get("documentId") not in [None, document_id] and evaluate("window.fixtureReady===true"))
                eventually("document replacement cancels its event request", lambda: rpc("events.head")["pendingPolls"] == 0)
                evaluate("(window.postMessage({channel:'slate-request',documentId:" + json.dumps(document_id) + ",id:9999,method:'command.run',params:{id:'window.new'}},'*'),true)")
                assert evaluate("workspace.call('events.head').then(value=>!!value.cursor)")
                assert len(cli("tabs", "list")) == 1, "A retired document request reached the host"
                evaluate("(async()=>{window.seenEvents=[];window.stopEvents=await workspace.subscribe(event=>window.seenEvents.push(event),{topics:['test.scope'],waitMilliseconds:25000,onError:error=>window.subscriptionError=String(error)});return true})()")
                eventually("plugin subscription is polling", lambda: rpc("events.head")["pendingPolls"] == 1)
                rpc("events.emit", topic="test.scope", tab="t999", payload="foreign-tab")
                rpc("events.emit", topic="test.scope", payload="broadcast")
                eventually("plugin receives its scoped event", lambda: evaluate("window.seenEvents.length===1 && window.seenEvents[0].payload==='broadcast'"))
                evaluate("(window.stopEvents(),true)")
                eventually("unsubscribe cancels its outstanding poll", lambda: rpc("events.head")["pendingPolls"] == 0, timeout=2)
                evaluate("(()=>{window.abortResults=[];window.abortControllers=Array.from({length:32},()=>new AbortController());for(const controller of window.abortControllers)workspace.call('events.poll',{topics:['test.abort'],waitMilliseconds:25000},{signal:controller.signal}).then(()=>window.abortResults.push('unexpected'),error=>window.abortResults.push(error.name));return true})()")
                eventually("all 32 bridge slots are occupied", lambda: rpc("events.head")["pendingPolls"] == 32)
                evaluate("(window.abortControllers[0].abort(),true)")
                eventually("abort works at bridge capacity", lambda: rpc("events.head")["pendingPolls"] == 31)
                evaluate("(window.abortControllers.forEach(controller=>controller.abort()),true)")
                eventually("all aborted calls release their native waiters", lambda: rpc("events.head")["pendingPolls"] == 0 and evaluate("window.abortResults.length===32 && window.abortResults.every(name=>name==='AbortError')"))
                assert evaluate("workspace.call('events.head',{}, {signal:AbortSignal.abort()}).then(()=> 'unexpected',error=>error.name)") == "AbortError"
                assert evaluate("workspace.call('events.head').then(value=>!!value.cursor)")
                document_id = info()["documentId"]
                evaluate("(location.hash='note',true)")
                assert evaluate("workspace.context().then(c=>c.activeTerminalPaneId)") == "p1"
                assert info()["documentId"] == document_id, "Same-document navigation invalidated the live bridge"
                assert rpc("debug.paneHeader", pane="p2")["type"] == "Notes"
                evaluate("workspace.setTitle('作業メモ')")
                assert rpc("debug.paneHeader", pane="p2")["title"] == "作業メモ"
                header = rpc("debug.paneHeader", pane="p2", beginRename=True)
                assert header["editing"] and header["draft"] == "作業メモ"
                evaluate("workspace.setTitle('While editing')")
                assert rpc("debug.paneHeader", pane="p2")["draft"] == "作業メモ"
                rpc("debug.paneHeader", pane="p2", finish="cancel")
                assert rpc("debug.paneHeader", pane="p2")["title"] == "While editing"
                rpc("debug.paneHeader", pane="p2", beginRename=True, finish="blur")
                assert not next(p for p in cli("panes", "list") if p["id"] == "p2").get("manualTitle"), "Unchanged edits must not pin automatic titles"
                rpc("debug.paneHeader", pane="p2", draft="Discard me")
                evaluate("workspace.setTitle('New automatic title')")
                assert rpc("debug.paneHeader", pane="p2")["draft"] == "Discard me"
                rpc("debug.paneHeader", pane="p2", finish="cancel")
                assert rpc("debug.paneHeader", pane="p2")["title"] == "New automatic title"
                rpc("debug.paneHeader", pane="p2", draft="Discarded on blur", finish="blur")
                assert rpc("debug.paneHeader", pane="p2")["title"] == "New automatic title"
                rpc("debug.paneHeader", pane="p2", rename="My notes — 手動")
                evaluate("workspace.setTitle('Plugin update')")
                assert rpc("debug.paneHeader", pane="p2")["title"] == "My notes — 手動"
                evaluate("(document.title='Updated document',true)")
                evaluate("workspace.setTitle(null)")
                assert rpc("debug.paneHeader", pane="p2")["title"] == "My notes — 手動"
                rpc("debug.paneHeader", pane="p2", rename="  ")
                eventually("clearing a manual title reveals the latest automatic title", lambda: rpc("debug.paneHeader", pane="p2")["title"] == "Updated document")
                evaluate("(document.title='Notes Plugin',true)")
                eventually("plugin document title in pane header", lambda: rpc("debug.paneHeader", pane="p2")["title"] == "Notes Plugin")
                assert evaluate("typeof window.webkit?.messageHandlers?.slate") == "undefined", "Native bridge handler leaked into page world"
                assert evaluate("typeof document.querySelector('#child').contentWindow.workspace") == "undefined"
                assert len(cli("tabs", "list")) == 1, "An iframe forged a privileged bridge request"
                # Shell telemetry is a non-public method; it stays reachable but requires the pane's shell token.
                assert evaluate("workspace.call('shell.update',{}).then(()=> 'unexpected',error=>error.code)") == -32040
                evaluate("workspace.storage.set('note','保存したメモ')")
                assert evaluate("workspace.storage.get('note')") == "保存したメモ"
                assert cli("panes", "split", "--down", "--pane", "p2")["paneId"] == "p3"
                cli("panes", "type", "--pane", "p3", "--type", "notes", "--force")
                eventually("second scoped view", lambda: evaluate("window.fixtureReady===true", pane="p3"))
                assert info()["instanceId"] == info("p3")["instanceId"], "Tab-scoped views did not share a logical instance"
                assert info()["viewId"] != info("p3")["viewId"]
                assert evaluate("workspace.storage.get('note')", "p3") == "保存したメモ"
                # A different tab has a different logical instance. Directed delivery
                # crosses the tab filter but never leaks to a different recipient.
                old_panes = {pane["id"] for pane in cli("panes", "list")}
                second_tab = cli("tabs", "new")
                new_panes = {pane["id"] for pane in cli("panes", "list")} - old_panes
                assert len(new_panes) == 1
                other_pane = new_panes.pop()
                cli("panes", "type", "--pane", other_pane, "--type", "notes", "--force")
                eventually("other-tab plugin view", lambda: evaluate("window.fixtureReady===true", other_pane))
                for target in ["p2", other_pane]:
                    evaluate("(async()=>{window.directEvents=[];window.stopDirect=await workspace.subscribe(event=>window.directEvents.push(event),{topics:['test.direct'],waitMilliseconds:25000});return true})()", target)
                eventually("two directed subscriptions", lambda: rpc("events.head")["pendingPolls"] == 2)
                assert "scoped" in evaluate("workspace.call('events.poll',{tab:'t1',waitMilliseconds:0}).then(()=> 'unexpected',error=>String(error))", other_pane)
                directed = evaluate("workspace.emit('test.direct',{text:'private'},{targetInstanceId:" + json.dumps(info()["instanceId"]) + "})", other_pane)
                eventually("directed event crosses tabs", lambda: evaluate("window.directEvents.length===1"))
                delivered = evaluate("window.directEvents[0]")
                reference = delivered.pop("deliveryContext")
                assert isinstance(reference, str) and 1 <= len(reference) <= 64, reference
                assert delivered == directed, (delivered, directed)
                assert evaluate("window.directEvents.length", other_pane) == 0
                assert directed["source"]["instanceId"] == info(other_pane)["instanceId"] != info()["instanceId"]
                evaluate("(window.stopDirect(),true)")
                eventually("one subscription remains", lambda: rpc("events.head")["pendingPolls"] == 1)
                cli("tabs", "close", "--tab", second_tab["tabId"], "--force")
                eventually("closing the view cancels its subscription", lambda: rpc("events.head")["pendingPolls"] == 0)
                other_terminal = cli("panes", "split", "--down", "--pane", "p1")["paneId"]
                eventually("other terminal is ready", lambda: cli("panes", "capture", "--pane", other_terminal)["text"].rstrip().endswith("$"))
                assert evaluate("workspace.context().then(value=>value.activeTerminalPaneId)") == other_terminal
                evaluate("(window.terminalAbort=new AbortController(),workspace.terminal.wait({contains:'NEVER_OUTPUT_TERMINAL_MARKER'},{signal:window.terminalAbort.signal}).catch(error=>window.terminalAbortResult=error.name),true)")
                eventually("plugin terminal wait is pending", lambda: rpc("debug.inspect")["pendingTerminalWaits"] == 1)
                evaluate("(window.terminalAbort.abort(),true)")
                eventually("plugin abort releases native terminal wait", lambda: rpc("debug.inspect")["pendingTerminalWaits"] == 0 and evaluate("window.terminalAbortResult==='AbortError'"))
                evaluate("workspace.terminal.send(\"printf 'EXPLICIT_%s\\\\n' TERMINAL\\r\",{pane:'p1'})")
                eventually("explicit terminal wins over scoped history", lambda: "EXPLICIT_TERMINAL" in cli("panes", "capture", "--pane", "p1")["text"])
                assert "EXPLICIT_TERMINAL" not in cli("panes", "capture", "--pane", other_terminal)["text"]
                cli("panes", "close", "--pane", other_terminal, "--force")
                evaluate("workspace.terminal.send(\"printf 'SLATE_%s\\\\n' BRIDGE\\r\")")
                try:
                    eventually("plugin drives actual terminal", lambda: "SLATE_BRIDGE" in cli("panes", "capture", "--pane", "p1")["text"])
                except AssertionError:
                    print("TERMINAL_DIAGNOSTIC", cli("panes", "capture", "--pane", "p1"), evaluate("workspace.context()"), flush=True)
                    raise
                blocked = info()["blockedNavigations"]
                evaluate(f"(location.href='http://127.0.0.1:{foreign.server_port}/forbidden',true)")
                eventually("external plugin navigation is blocked", lambda: info()["blockedNavigations"] > blocked)
                assert foreign_requests == []
                assert info()["url"].startswith("plugin://notes/")
                assert evaluate("fetch('./escape/passwd').then(r=>r.text()).then(()=>false,()=>true)"), "Static handler followed an escaping symlink"
                local_storage = evaluate("(()=>{try{localStorage.setItem('probe','ok');return {supported:localStorage.getItem('probe')==='ok'}}catch(error){return {supported:false,error:String(error)}}})()")
                print("Observed custom-scheme localStorage:", json.dumps(local_storage), flush=True)
                old_view = info()["viewId"]
                evaluate("(window.transient=123,true)")
                cli("panes", "type", "--pane", "p2", "--type", "browser", "--force")
                cli("panes", "type", "--pane", "p2", "--type", "notes", "--force")
                eventually("fresh plugin view", lambda: evaluate("window.fixtureReady===true"))
                assert info()["viewId"] != old_view and evaluate("typeof window.transient") == "undefined"
                assert evaluate("workspace.storage.get('note')") == "保存したメモ"
                assert evaluate("document.querySelector('#send').getBoundingClientRect().bottom<=innerHeight"), "Plugin fixture action is clipped"
                rpc("debug.paneHeader", pane="p2", rename="My notes — 手動")
                if not args.functional_only:
                    rpc("debug.activate", tab="t1")
                capture_path = ROOT / "artifacts/plugin-workspace.png"
                previous_dimensions = None
                stable_captures = 0

                def settled_capture():
                    global previous_dimensions, stable_captures
                    rpc("debug.screenshot", path=str(capture_path))
                    dimensions = struct.unpack(">II", capture_path.read_bytes()[16:24])
                    window = rpc("debug.inspect")["windows"][0]
                    stable_captures = stable_captures + 1 if dimensions == previous_dimensions else 0
                    previous_dimensions = dimensions
                    return dimensions[0] >= window["width"] and dimensions[1] >= window["height"] and stable_captures >= 3

                if not args.functional_only:
                    try:
                        eventually("full-sized capture after native window animation", settled_capture)
                    except AssertionError as error:
                        raise AssertionError(f"{error}; pixels={previous_dimensions}; native={rpc('debug.inspect')}") from error
                cli("plugins", "unregister", "notes", success=False)
                cli("plugins", "register", "--manifest", str(manifest), "--replace", success=False)
                rpc("debug.paneHeader", pane="p2", beginRename=True)
                assert rpc("debug.paneHeader", pane="p2")["editing"] is True
                if not args.functional_only:
                    rpc('debug.paneHeader', pane='p2', renameScreenshot=str(ROOT / 'artifacts/pane-rename-popover-plugin.png'))
                stop()
                app = start()
                eventually("restored registered view is functional", lambda: evaluate("window.fixtureReady===true"))
                assert rpc("debug.paneHeader", pane="p2")["title"] == "My notes — 手動"
                evaluate("workspace.setTitle('After restart')")
                assert rpc("debug.paneHeader", pane="p2")["title"] == "My notes — 手動"
                rpc("debug.paneHeader", pane="p2", rename="")
                assert rpc("debug.paneHeader", pane="p2")["title"] == "After restart"
                assert evaluate("workspace.storage.get('note')") == "保存したメモ"
                failed_unregister_preserves_views()
                assert evaluate("workspace.storage.get('note')") == "保存したメモ"
                rpc("debug.paneHeader", pane="p3", close=True)
                assert "p3" not in [pane["id"] for pane in cli("panes", "list")]
                assert evaluate("workspace.storage.get('note')") == "保存したメモ"
                cli("plugins", "unregister", "notes", "--force")
                assert cli("plugins", "list") == [] and cli("plugins", "status") == []
                assert [pane["id"] for pane in cli("panes", "list")] == ["p1"]
                print("PASS plugins: static modules, origin-gated isolated bridge, trusted registry/menu, iframe rejection, terminal control, tab scope, persistent storage, fresh views, restoration, and forced unregister" + (" [foreground screenshots OMITTED]" if args.functional_only else ""))
            finally:
                stop()
finally:
    foreign.shutdown()
    foreign.server_close()
    thread.join(timeout=3)
