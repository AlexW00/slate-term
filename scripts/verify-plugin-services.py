#!/usr/bin/env python3
"""Real managed web servers: scoped ports, ownership, restart bounds, logs and teardown."""
import concurrent.futures
import http.server
import json
import os
import pathlib
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / ".derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal"
CLI = APP.parent.parent / "Helpers/slate-term"


def eventually(label, condition, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(0.05)
    raise AssertionError(label)


def running(pid):
    result = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, timeout=2)
    return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")


foreign_gets = []


class Foreign(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        foreign_gets.append(self.path)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"unrelated server")

    def log_message(self, *_):
        pass


foreign = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Foreign)
thread = threading.Thread(target=foreign.serve_forever, daemon=True)
thread.start()
try:
    with tempfile.TemporaryDirectory(prefix="slate-services-", dir="/tmp") as temporary:
        directory = pathlib.Path(temporary)
        server = directory / "server.py"
        server.write_text('''import http.server,json,os,pathlib,signal,subprocess,sys,time
path=pathlib.Path(sys.argv[1]);mode=sys.argv[2];port=int(sys.argv[3])
child=subprocess.Popen(['/bin/sleep','60'])
previous=path.read_text().splitlines() if path.exists() else []
with path.open('a') as f:f.write(json.dumps(dict(pid=os.getpid(),child=child.pid,group=os.getpgrp(),port=port))+'\\n')
print('SERVICE_STARTED',os.getpid(),flush=True)
if mode=='crash' or mode=='once' and not previous:sys.exit(23)
if mode=='sleep':time.sleep(60);sys.exit(0)
if mode=='ignore':signal.signal(signal.SIGTERM,signal.SIG_IGN)
class Handler(http.server.BaseHTTPRequestHandler):
 def do_HEAD(self):self.send_response(200);self.end_headers()
 def do_GET(self):
  self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers()
  self.wfile.write(b"<!doctype html><title>Service</title><p>Managed plugin</p><script>window.addEventListener('pageshow',event=>window.wasCached=event.persisted);workspace.context().then(c=>{window.context=c;window.fixtureReady=true}).catch(e=>window.fixtureError=String(e));</script>")
 def log_message(self,*args):pass
http.server.ThreadingHTTPServer(('127.0.0.1',port),Handler).serve_forever()
''')
        ready = directory / "ready"
        environment = {key: value for key, value in os.environ.items() if not key.startswith("SLATE_TERM_")}
        environment.update(SLATE_TERM_INTEGRATION="1", SLATE_TERM_STATE_DIR=temporary,
                           SLATE_TERM_SOCKET_FILE=str(ready), SLATE_TERM_CONFIG_FILE=str(directory / "config.toml"))
        with (ROOT / "artifacts/plugin-services-process.log").open("w") as log:
            app = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
            try:
                eventually("App readiness", lambda: ready.exists() and app.poll() is None)
                environment["SLATE_TERM_SOCKET"] = ready.read_text().strip()

                def cli(*args):
                    result = subprocess.run([str(CLI), *args, "--json"], env=environment, capture_output=True, text=True, timeout=35)
                    assert result.returncode == 0, result.stderr
                    return json.loads(result.stdout)

                def rpc(method, **params):
                    return cli("rpc", method, "--params", json.dumps(params))

                def statuses(name):
                    return cli("plugins", "status", name)

                def register(name, scope="pane", mode="normal", restarts=0, port=0):
                    manifest = directory / (name + ".json")
                    manifest.write_text(json.dumps({"id": name, "title": name.title(), "scope": scope,
                        "source": {"kind": "url", "url": f"http://127.0.0.1:{port}/"},
                        "process": {"executable": sys.executable, "arguments": [str(server), str(directory / (name + ".pids")), mode, "{port}"],
                                    "directory": temporary, "environment": {"PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1"},
                                    "restartLimit": restarts, "readyTimeoutSeconds": 1.5}}))
                    cli("plugins", "register", "--manifest", str(manifest))

                def open_plugin(name, split="p1"):
                    pane = cli("panes", "split", "--down", "--pane", split)["paneId"]
                    cli("panes", "type", "--pane", pane, "--type", name, "--force")
                    return pane

                def evaluate(pane, expression):
                    return rpc("debug.pluginEval", pane=pane, script=expression)

                def loaded(name, count=1):
                    return len(statuses(name)) == count and all(item["state"] == "ready" for item in statuses(name))

                def processes(name):
                    path = directory / (name + ".pids")
                    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

                def stopped(name):
                    return all(not running(item[key]) for item in processes(name) for key in ["pid", "child", "group"])

                register("shared", scope="global", mode="ignore")
                shared = open_plugin("shared")
                try:
                    eventually("Managed global service", lambda: loaded("shared"))
                except AssertionError:
                    print('SERVICE_STARTUP_DIAGNOSTIC', statuses('shared'), flush=True)
                    for item in statuses('shared'):
                        print('SERVICE_STARTUP_LOG', cli('plugins', 'logs', '--instance-id', item['instanceId']), flush=True)
                    raise
                eventually("Managed server bridge", lambda: evaluate(shared, "window.fixtureReady===true"))
                evaluate(shared, "(window.historyMarker='original',location.href='/second',true)")
                eventually("same-origin second document", lambda: evaluate(shared, "location.pathname==='/second' && window.fixtureReady===true"))
                evaluate(shared, "(history.back(),true)")
                eventually("history returned to first document", lambda: evaluate(shared, "location.pathname==='/' && window.fixtureReady===true"))
                cached = evaluate(shared, "window.wasCached===true")
                print("History restoration used WebKit page cache:", cached, flush=True)
                assert cached, "This regression requires actual cached-document restoration"
                assert evaluate(shared, "window.historyMarker") == "original"
                assert evaluate(shared, "workspace.call('events.head').then(value=>!!value.cursor)")
                assert evaluate(shared, "workspace.emit('test.history',{restored:true}).then(event=>event.source.kind)") == "plugin"
                evaluate(shared, "(async()=>{window.historyStop=await workspace.subscribe(()=>{}, {topics:['test.history.wait'],waitMilliseconds:25000});return true})()")
                eventually("restored page subscribes", lambda: rpc("events.head")["pendingPolls"] == 1)
                evaluate(shared, "(window.historyStop(),true)")
                eventually("restored subscription cancels", lambda: rpc("events.head")["pendingPolls"] == 0)
                evaluate(shared, "(async()=>{window.globalEvents=[];window.stopGlobal=await workspace.subscribe(event=>window.globalEvents.push(event),{topics:['test.global'],waitMilliseconds:25000});return true})()")
                eventually("global subscription", lambda: rpc("events.head")["pendingPolls"] == 1)
                other_tab = cli("tabs", "new")["tabId"]
                rpc("events.emit", topic="test.global", tab=other_tab, payload="other-tab")
                eventually("global instance receives another tab's event", lambda: evaluate(shared, "window.globalEvents.length===1 && window.globalEvents[0].payload==='other-tab'"))
                evaluate(shared, "(window.stopGlobal(),true)")
                eventually("global unsubscribe", lambda: rpc("events.head")["pendingPolls"] == 0)
                cli("tabs", "close", "--tab", other_tab, "--force")
                first = statuses("shared")[0]
                assert evaluate(shared, "workspace.plugin.instanceId") == first["instanceId"]
                assert evaluate(shared, "workspace.plugin.paneId") == shared
                assert first["pid"] == processes("shared")[0]["group"]
                assert "SERVICE_STARTED" in cli("plugins", "logs", "--instance-id", first["instanceId"])["text"]
                cli("panes", "type", "--pane", shared, "--type", "browser", "--force")
                assert statuses("shared")[0]["panes"] == [] and running(first["pid"]), "Global service did not outlive its view"
                cli("panes", "type", "--pane", shared, "--type", "shared", "--force")
                eventually("Reattached global view", lambda: evaluate(shared, "window.fixtureReady===true"))
                assert statuses("shared")[0]["pid"] == first["pid"]
                evaluate(shared, "(location.href='/second',true)")
                eventually("document before native restart", lambda: evaluate(shared, "location.pathname==='/second' && window.fixtureReady===true"))
                evaluate(shared, "(window.restartMarker='cached-before-restart',true)")
                eventually("automation ready before managed restart", lambda: rpc("pane.inspect", pane=shared)["webReady"])
                automation_before = rpc("pane.inspect", pane=shared)
                with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                    restarting = pool.submit(cli, "plugins", "restart", "shared")
                    eventually("First restart enters stopping", lambda: statuses("shared")[0]["state"] == "stopping")
                    cli("plugins", "restart", "shared")
                    restarting.result(timeout=10)
                eventually("Concurrent restart coalesces without a port collision", lambda: loaded("shared") and statuses("shared")[0]["pid"] != first["pid"])
                eventually("Old group ended after restart", lambda: not running(first["pid"]))
                eventually("restart loaded entry document", lambda: evaluate(shared, "location.pathname==='/' && window.fixtureReady===true"))
                eventually("automation ready after managed restart", lambda: rpc("pane.inspect", pane=shared)["webReady"])
                automation_entry = rpc("pane.inspect", pane=shared)
                assert automation_entry["viewId"] == automation_before["viewId"]
                assert automation_entry["documentId"] != automation_before["documentId"]
                evaluate(shared, "(history.back(),true)")
                eventually("cached history after native restart", lambda: evaluate(shared, "location.pathname==='/second' && window.fixtureReady===true"))
                assert evaluate(shared, "window.wasCached===true && window.restartMarker==='cached-before-restart'")
                eventually("automation ready after managed history restore", lambda: rpc("pane.inspect", pane=shared)["webReady"])
                automation_restored = rpc("pane.inspect", pane=shared)
                assert automation_restored["viewId"] == automation_before["viewId"]
                assert automation_restored["documentId"] not in [automation_before["documentId"], automation_entry["documentId"]]
                assert evaluate(shared, "workspace.call('events.head').then(value=>!!value.cursor)")
                assert evaluate(shared, "workspace.emit('test.after-restart',null).then(event=>event.source.kind)") == "plugin"
                register("private")
                private1 = open_plugin("private")
                private2 = open_plugin("private")
                eventually("Two independent per-pane servers", lambda: loaded("private", 2))
                instances = statuses("private")
                assert len({item["url"] for item in instances}) == 2 and len({item["instanceId"] for item in instances}) == 2
                for pane in [private1, private2]:
                    eventually("Private bridge", lambda: evaluate(pane, "window.fixtureReady===true"))
                evaluate(private1, "workspace.storage.set('secret','one')")
                assert evaluate(private2, "workspace.storage.get('secret')") is None
                for pane in [private1, private2]:
                    evaluate(pane, "(async()=>{window.privateEvents=[];window.stopPrivate=await workspace.subscribe(event=>window.privateEvents.push(event),{topics:['test.private'],waitMilliseconds:25000});return true})()")
                eventually("per-pane subscriptions", lambda: rpc("events.head")["pendingPolls"] == 2)
                recipient = evaluate(private1, "workspace.plugin.instanceId")
                evaluate(private2, "workspace.emit('test.private',42,{targetInstanceId:" + json.dumps(recipient) + "})")
                eventually("directed per-pane delivery", lambda: evaluate(private1, "window.privateEvents.length===1"))
                assert evaluate(private2, "window.privateEvents.length") == 0
                cli("plugins", "unregister", "private", "--force")
                eventually("unregister cancels every private subscription", lambda: rpc("events.head")["pendingPolls"] == 0)
                eventually("Per-pane servers and grandchildren ended", lambda: stopped("private"))
                register("retry", mode="once", restarts=1)
                retry = open_plugin("retry")
                eventually("Automatic restart recovered", lambda: loaded("retry") and statuses("retry")[0]["restartCount"] == 1)
                assert len(processes("retry")) == 2
                assert "code=23" in cli("plugins", "logs", "--instance-id", statuses("retry")[0]["instanceId"])["text"]
                cli("plugins", "unregister", "retry", "--force")
                eventually("Retried service cleanup", lambda: stopped("retry"))
                register("crash", mode="crash", restarts=2)
                open_plugin("crash")
                eventually("Restart limit", lambda: statuses("crash")[0]["state"] == "failed" and statuses("crash")[0]["restartCount"] == 2)
                assert len(processes("crash")) == 3
                eventually("Crash descendants cleaned up", lambda: stopped("crash"))
                register("foreign", mode="sleep", port=foreign.server_port)
                rejected = open_plugin("foreign")
                eventually("Unrelated 200 response must not authenticate readiness", lambda: statuses("foreign")[0]["state"] == "failed")
                assert foreign_gets == [] and evaluate(rejected, "typeof workspace") == "undefined"
                eventually("Failed readiness kills owned sleeping group", lambda: stopped("foreign"))
                assert foreign.fileno() >= 0, "Unrelated server was closed"
                # Real GUI crash, rather than only the standalone worker test.
                os.kill(app.pid, signal.SIGKILL)
                app.wait(timeout=5)
                eventually("GUI crash orphan cleanup", lambda: stopped("shared"))
                print("PASS plugin services: managed bridge, instance identity, dynamic ports, pane/global scopes, isolated storage, logs, explicit/automatic restart, restart bound, listener ownership, descendants and GUI-SIGKILL cleanup")
            finally:
                if app.poll() is None:
                    os.killpg(app.pid, signal.SIGTERM)
                    try:
                        app.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        os.killpg(app.pid, signal.SIGKILL)
                        app.wait(timeout=5)
                # Only fixture-owned groups, with the recorded leader still alive.
                for path in directory.glob("*.pids"):
                    for item in [json.loads(line) for line in path.read_text().splitlines()]:
                        if running(item["group"]):
                            os.killpg(item["group"], signal.SIGKILL)
finally:
    foreign.shutdown()
    foreign.server_close()
    thread.join(timeout=3)
