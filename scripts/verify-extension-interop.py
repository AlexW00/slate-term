#!/usr/bin/env python3
"""An external extension, not core, discovers/drives a private tmux server and publishes context."""
import json
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
from plugin_package_fixture import package_fixture

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / '.derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal'
CLI = APP.parent.parent / 'Helpers/slate-term'
TMUX = shutil.which('tmux')
assert TMUX, 'This compatibility fixture requires tmux; the application does not.'


def eventually(label, condition, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.05)
    raise AssertionError(label)


BACKEND = r'''
import http.server,json,os,shlex,subprocess,time,traceback

def cli(*args):
    result = subprocess.run([os.environ['SLATE_TERM_CLI'], *args, '--json'], capture_output=True, text=True, timeout=5)
    if result.returncode: raise RuntimeError(result.stderr)
    return json.loads(result.stdout)

def tmux(*args):
    result = subprocess.run([os.environ['FIXTURE_TMUX'], '-S', os.environ['FIXTURE_TMUX_SOCKET'], *args], capture_output=True, text=True, timeout=3)
    if result.returncode: raise RuntimeError(result.stderr)
    return result.stdout.strip()

def wait(check):
    deadline = time.monotonic()+10
    while time.monotonic()<deadline:
        try:
            value=check()
            if value:return value
        except RuntimeError:pass
        time.sleep(0.05)
    raise RuntimeError('Extension timed out waiting for actual tmux state')

def exercise():
    # All tmux knowledge lives in this user-extension fixture.
    context=cli('context','get')
    terminal=context['terminal']; pane=terminal['paneId']; session=terminal['sessionId']
    target=['--pane',pane,'--session-id',session]
    home=os.environ['FIXTURE_HOME']
    command=['env','HOME='+home,'SHELL=/bin/sh','ENV=/dev/null','BASH_ENV=/dev/null','HISTFILE=/dev/null',
             os.environ['FIXTURE_TMUX'],'-S',os.environ['FIXTURE_TMUX_SOCKET'],'-f','/dev/null',
             'new-session','-s','fixture','/bin/sh','--noprofile','--norc']
    cli('panes','send',*target,'--text',shlex.join(command)+'\r')
    wait(lambda:tmux('list-panes','-F','#{pane_id}'))
    # The engine encodes a logical control key; only this extension knows its meaning.
    cli('terminal','key',*target,'--key','ctrl+b')
    cli('panes','send',*target,'--text','%')
    wait(lambda:len(tmux('list-panes','-F','#{pane_id}').splitlines())==2)
    active=tmux('display-message','-p','#{pane_id}')
    tmux('send-keys','-t',active,'-l',"printf 'SLATE_%s\\n' EXTENSION")
    tmux('send-keys','-t',active,'Enter')
    wait(lambda:'SLATE_EXTENSION' in tmux('capture-pane','-p','-t',active))
    screen=wait(lambda:cli('panes','capture',*target)['text'] if 'SLATE_EXTENSION' in cli('panes','capture',*target)['text'] else None)
    extension_context={'kind':'tmux','activePane':active,'paneCount':2,'terminalPaneId':pane,'terminalSessionId':session}
    event=cli('events','emit','--topic','extension.fixture.context','--target-instance-id',os.environ['SLATE_TERM_PLUGIN_INSTANCE'],
              '--payload',json.dumps(extension_context))
    return {'context':extension_context,'event':event,'screen':screen,'appInstanceId':context['instanceId']}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):self.send_response(200);self.end_headers()
    def do_GET(self):
        self.send_response(200);self.send_header('Content-Type','text/html');self.end_headers()
        self.wfile.write(b"<!doctype html><title>Extension Interop</title><p>External adapter</p><script>workspace.context().then(()=>window.ready=true)</script>")
    def do_POST(self):
        try:
            if self.path=='/environment':
                value={key:value for key,value in os.environ.items() if key.startswith('SLATE_TERM_')}
            elif self.path=='/exercise':value=exercise()
            else:raise RuntimeError('Unknown fixture action')
            self.send_response(200)
        except Exception:
            value={'error':traceback.format_exc()};self.send_response(500)
        self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(json.dumps(value).encode())
    def log_message(self,*args):pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(os.environ['SLATE_TERM_PLUGIN_PORT'])),Handler).serve_forever()
'''

with tempfile.TemporaryDirectory(prefix='slate-extension-', dir='/tmp') as temporary:
    directory = pathlib.Path(temporary)
    (directory / 'home').mkdir()
    backend = directory / 'backend.py'
    backend.write_text(BACKEND)
    tmux_socket = directory / 'private-tmux.sock'
    manifest = directory / 'extension.json'
    manifest.write_text(json.dumps({'id': 'interop', 'title': 'Extension Interop', 'scope': 'pane',
        'source': {'kind': 'url', 'url': 'http://127.0.0.1:0/'},
        'process': {'executable': __import__('sys').executable, 'arguments': [str(backend)], 'directory': temporary,
                    'environment': {'FIXTURE_TMUX': TMUX, 'FIXTURE_TMUX_SOCKET': str(tmux_socket), 'FIXTURE_HOME': str(directory / 'home'),
                                    'SLATE_TERM_SOCKET': '/wrong-manifest-socket', 'SLATE_TERM_CONTEXT_TOKEN': 'must-not-inherit'},
                    'restartLimit': 0, 'readyTimeoutSeconds': 5}}))
    ready = directory / 'ready'
    environment = {key: value for key, value in os.environ.items() if not key.startswith('SLATE_TERM_')}
    environment.update(SLATE_TERM_INTEGRATION='1', SLATE_TERM_STATE_DIR=temporary, SLATE_TERM_SOCKET_FILE=str(ready),
                       SLATE_TERM_CONFIG_FILE=str(directory / 'config.toml'))
    with (ROOT / 'artifacts/extension-interop-process.log').open('w') as log:
        app = subprocess.Popen([str(APP)], env=environment, stdout=log, stderr=log, start_new_session=True)
        try:
            eventually('app readiness', lambda: ready.exists() and app.poll() is None)
            environment['SLATE_TERM_SOCKET'] = ready.read_text().strip()

            def cli(*args, success=True):
                result = subprocess.run([str(CLI), *args, '--json'], env=environment, capture_output=True, text=True, timeout=35)
                if not success:
                    assert result.returncode != 0, args
                    return result.stderr
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)

            def rpc(method, **params):
                return cli('rpc', method, '--params', json.dumps(params))

            def evaluate(source):
                return rpc('debug.pluginEval', pane='p2', script=source)

            eventually('isolated shell prompt', lambda: cli('panes','capture','--pane','p1')['text'].rstrip().endswith('$'))
            cli('plugins','register','--package',package_fixture(manifest, directory))
            cli('panes','split','--right','--pane','p1')
            cli('panes','type','--pane','p2','--type','interop','--force')
            eventually('extension page', lambda: evaluate('window.ready===true'))
            backend_env = evaluate("fetch('/environment',{method:'POST'}).then(response=>response.json())")
            assert backend_env.get('SLATE_TERM_CLI') == str(CLI), backend_env
            assert backend_env.get('SLATE_TERM_SOCKET') == environment['SLATE_TERM_SOCKET'], backend_env
            assert backend_env.get('SLATE_TERM_PLUGIN_SCOPE') == 'pane'
            assert backend_env.get('SLATE_TERM_TAB_ID') == 't1' and backend_env.get('SLATE_TERM_PANE_ID') == 'p2'
            assert 'SLATE_TERM_CONTEXT_TOKEN' not in backend_env and 'SLATE_TERM_INTEGRATION' not in backend_env
            evaluate("(async()=>{window.received=[];window.stop=await workspace.subscribe(event=>window.received.push(event),{topics:['extension.fixture.context']});return true})()")
            result = evaluate("fetch('/exercise',{method:'POST'}).then(response=>response.json())")
            assert 'error' not in result, result
            assert result['appInstanceId'] == backend_env['SLATE_TERM_INSTANCE_ID']
            assert result['context']['paneCount'] == 2 and result['context']['activePane'].startswith('%')
            assert 'SLATE_EXTENSION' in result['screen']
            eventually('extension-published context reaches its view', lambda: evaluate('window.received.length===1'))
            delivered = evaluate('window.received[0]')
            reference = delivered.pop('deliveryContext')
            assert isinstance(reference, str) and 1 <= len(reference) <= 64, reference
            assert delivered == result['event'], (delivered, result['event'])
            assert result['event']['source'] == {'kind':'client'}, 'Backend RPC must not pretend to be host telemetry'
            session = result['context']['terminalSessionId']
            subprocess.run([TMUX,'-S',str(tmux_socket),'kill-server'], check=True, capture_output=True, timeout=5)
            cli('panes','type','--pane','p1','--type','browser','--force')
            cli('panes','type','--pane','p1','--type','terminal','--force')
            stale = cli('panes','send','--pane','p1','--session-id',session,'--text','stale-input',success=False)
            assert 'session' in stale.lower(), stale
            assert 'stale-input' not in cli('panes','capture','--pane','p1')['text']
            rpc('events.head')
            cli('plugins','unregister','interop','--force')
            eventually('extension subscription removed', lambda: rpc('events.head')['pendingPolls']==0)
            print('PASS extension interoperability: managed backend CLI/socket discovery, reserved environment, active-terminal targeting, real control input, extension-owned tmux inspection, screen capture, directed custom context, stale-session rejection and teardown')
        finally:
            subprocess.run([TMUX,'-S',str(tmux_socket),'kill-server'], capture_output=True, timeout=5)
            if app.poll() is None:
                os.killpg(app.pid, signal.SIGTERM)
                try: app.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    os.killpg(app.pid, signal.SIGKILL)
                    app.wait(timeout=5)
