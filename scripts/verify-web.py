#!/usr/bin/env python3
"""One owned window: shared browser/plugin automation, guards and privilege boundaries."""
import concurrent.futures
import functools
import http.server
import json
import threading
from api_fixture import AppFixture, eventually

HTML = '''<!doctype html><title>Shared web fixture</title>
<input id="name" value="before"><input id="password" type="password" value="PASSWORD_SENTINEL">
<button id="apply" onclick="document.querySelector('#result').textContent=document.querySelector('#name').value">Apply</button>
<button id="disabled" disabled>Disabled</button><p id="result">ready</p>
<select id="choice"><option value="a">A</option><option value="b">B</option></select>
<iframe src="child.html"></iframe><div style="height:1800px">scroll</div>
<script>addEventListener('pageshow', e=>window.restored=e.persisted);</script>'''

navigation_gates = {path: (threading.Event(), threading.Event()) for path in ['/held-a', '/held-b']}

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path in navigation_gates:
            started, release = navigation_gates[self.path]
            started.set()
            if not release.wait(12):
                self.send_error(504)
                return
            self.path = '/index.html'
        try:
            super().do_GET()
        except (BrokenPipeError, ConnectionResetError):
            pass  # The deliberately superseded navigation closed its connection.

with AppFixture('web-conformance') as app:
    assets = app.root / 'assets'
    assets.mkdir()
    (assets / 'index.html').write_text(HTML)
    (assets / 'next.html').write_text('<!doctype html><title>Next page</title><p>next</p>')
    (assets / 'child.html').write_text('<!doctype html><p>child</p>')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(assets)))
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        base = f'http://127.0.0.1:{server.server_port}'
        app.rpc('command.run', id='pane.type', pane='p1', type='browser', force=True)
        app.rpc('browser.navigate', pane='p1', url=base + '/index.html')
        p2 = app.rpc('command.run', id='split.right', pane='p1')['paneId']
        app.rpc('plugins.register', manifest=dict(id='web.fixture', title='Web fixture', source=dict(kind='directory', path=str(assets))))
        app.rpc('command.run', id='pane.type', pane=p2, type='web.fixture', force=True)
        eventually('public identity without a bridge call', lambda: app.rpc('pane.inspect', pane=p2).get('documentId') is not None)
        plugin = next(p['plugin'] for p in app.rpc('debug.inspect')['panes'] if p['paneId'] == p2)
        assert plugin['documentId'] is None, 'Fixture unexpectedly initialized the credential-bearing bridge'
        assert app.rpc('api.describe')['webAutomation']['version'] == 1

        snapshots = {}
        for pane in ['p1', p2]:
            eventually('renderable document', lambda: app.rpc('web.get', pane=pane).get('renderable') is True)
            info = app.cli('web', 'get', '--pane', pane)
            inspected = app.rpc('pane.inspect', pane=pane)
            assert (info['viewId'], info['documentId']) == (inspected['viewId'], inspected['documentId'])
            guards = dict(expectedViewId=info['viewId'], expectedDocumentId=info['documentId'])
            snapshot = app.rpc('web.snapshot', pane=pane, **guards)
            snapshots[pane] = snapshot
            assert snapshot['viewId'] == info['viewId'] and snapshot['documentId'] == info['documentId']
            assert 'PASSWORD_SENTINEL' not in json.dumps(snapshot)
            app.rpc('web.fill', pane=pane, selector='#name', text='must not apply', error=-32602)
            app.cli('web', 'fill', '--pane', pane, '--selector', '#name', '--text', 'checked',
                    '--expected-view-id', info['viewId'], '--expected-document-id', info['documentId'])
            apply = next(e['ref'] for e in snapshot['elements'] if e['name'] == 'Apply')
            assert app.rpc('web.click', pane=pane, ref=apply)['performed'] is True
            app.rpc('web.select', pane=pane, selector='#choice', values=['b'], **guards)
            assert 'checked' in app.rpc('web.snapshot', pane=pane)['text']
            failure = app.cli('rpc', 'web.click', '--params', json.dumps(dict(pane=pane, selector='#disabled', **guards)), error=True)
            assert 'disabled' in failure['message'].lower(), failure
            app.rpc('web.scroll', pane=pane, y=150, **guards)
            app.rpc('web.scroll', pane=pane, y=-150, **guards)
            app.rpc('web.wait', pane=pane, selector='#result', state='visible', timeoutMilliseconds=0)
            output = app.root / (pane + '.png')
            app.rpc('web.screenshot', pane=pane, path=str(output), **guards)
            assert output.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        assert snapshots['p1']['viewId'] != snapshots[p2]['viewId']
        ref = snapshots['p1']['elements'][0]['ref']
        app.rpc('web.click', pane=p2, ref=ref, error=-32050)
        app.rpc('web.get', error=-32602)
        app.rpc('web.eval', pane=p2, script='1', error=-32601)

        def js(script): return app.rpc('debug.pluginEval', pane=p2, script=script)
        assert js('typeof window.__slateBrowserAutomation') == 'undefined'
        assert app.rpc('browser.eval', pane='p1', script='typeof workspace') == 'undefined'
        assert app.rpc('browser.eval', pane='p1', script="typeof document.querySelector('iframe').contentWindow.workspace") == 'undefined'
        assert js("(()=>{try{return typeof document.querySelector('iframe').contentWindow.workspace}catch{return 'blocked'}})()") in ['undefined', 'blocked']
        assert js('workspace.web.get()')['viewId'] == snapshots[p2]['viewId']
        assert js('workspace.web.snapshot({pane:"p1"})')['viewId'] == snapshots['p1']['viewId']
        exposure = js('workspace.call("api.describe")')
        assert exposure == app.rpc('api.describe')
        assert exposure['webAutomation']['screenshot'] is True and 'web.screenshot' in exposure['methods']
        assert js('workspace.call("web.eval",{script:"1"}).then(()=>null,e=>e.code)') == -32601
        assert js('workspace.browser.eval({pane:"p1",script:"1"})') == 1
        output = app.root / 'plugin-bridge.png'
        js('workspace.web.screenshot({path:' + json.dumps(str(output)) + '})')
        assert output.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')

        # Hiding via existing zoom is not document retirement or permission to reveal.
        old = app.rpc('web.get', pane=p2)
        app.rpc('command.run', id='pane.zoom', pane='p1')
        assert app.rpc('web.get', pane=p2)['renderable'] is False
        app.rpc('web.snapshot', pane=p2, error=-32051)
        app.rpc('command.run', id='pane.zoom', pane='p1')
        eventually('unzoom renderable', lambda: app.rpc('web.get', pane=p2)['renderable'])
        assert app.rpc('web.get', pane=p2)['documentId'] == old['documentId']

        # Restart preserves view identity but retires the automation document/refs.
        app.rpc('plugins.restart', id='web.fixture')
        eventually('fresh plugin document', lambda: (i := app.rpc('web.get', pane=p2))['ready'] and i['documentId'] != old['documentId'])
        assert app.rpc('web.get', pane=p2)['viewId'] == old['viewId']
        app.rpc('web.snapshot', pane=p2, expectedViewId=old['viewId'], expectedDocumentId=old['documentId'], error=-32050)

        # Cache restoration must not revive an old ref, even for the same URL/view.
        first = app.rpc('web.get', pane='p1')
        app.rpc('browser.navigate', pane='p1', url=base + '/next.html')
        app.rpc('command.run', id='browser.back', pane='p1')
        # browser.get is cached native metadata; do not let web.get repair identity
        # before checking pane.inspect's independently initialized cache.
        eventually('history restored', lambda: (i := app.rpc('browser.get', pane='p1')).get('url', '').endswith('/index.html') and i['ready'])
        assert app.rpc('pane.inspect', pane='p1')['documentId'] != first['documentId']
        assert app.rpc('browser.eval', pane='p1', script='window.restored') is True, 'Fixture did not exercise BFCache'
        app.rpc('web.click', pane='p1', ref=ref, error=-32050)

        # Supersession cancels A's caller and keeps the held successor B unready.
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as requests:
            try:
                first_load = requests.submit(app.rpc, 'browser.navigate', pane='p1', url=base + '/held-a', error=-32022)
                assert navigation_gates['/held-a'][0].wait(4), 'First navigation did not start'
                successor = requests.submit(app.rpc, 'browser.navigate', pane='p1', url=base + '/held-b')
                assert navigation_gates['/held-b'][0].wait(4), 'Successor navigation did not start'
                first_load.result(timeout=4)
                pending = app.rpc('pane.inspect', pane='p1')
                assert pending['webReady'] is False and pending['documentId'] is None, pending
                app.rpc('web.snapshot', pane='p1', error=-32051)
                navigation_gates['/held-b'][1].set()
                assert successor.result(timeout=5)['title'] == 'Shared web fixture'
            finally:
                for _, release in navigation_gates.values(): release.set()
        eventually('successor identity initialized', lambda: app.rpc('web.get', pane='p1')['ready'])

        # Caller retirement cancels borrowed waits on a different target.
        js('(window.waitResult=null,window.waitAbort=new AbortController(),workspace.web.wait({pane:"p1",selector:"#never"},{signal:waitAbort.signal}).then(()=>waitResult="unexpected",e=>waitResult=e.code),true)')
        eventually('borrowed wait pending', lambda: app.rpc('web.get', pane='p1')['pendingActions'] == 1)
        js('(waitAbort.abort(),true)')
        eventually('wait cancellation', lambda: js('window.waitResult') is not None)
        eventually('wait slot released', lambda: app.rpc('web.get', pane='p1')['pendingActions'] == 0)
        js('(workspace.web.wait({pane:"p1",selector:"#never"}).catch(()=>{}),true)')
        eventually('borrowed wait before caller retirement', lambda: app.rpc('web.get', pane='p1')['pendingActions'] == 1)
        app.rpc('plugins.restart', id='web.fixture')
        eventually('retirement releases borrowed wait', lambda: app.rpc('web.get', pane='p1')['pendingActions'] == 0)
        eventually('restarted caller ready', lambda: app.rpc('pane.inspect', pane=p2)['webReady'])
        old = app.rpc('web.get', pane=p2)
        app.rpc('command.run', id='pane.type', pane=p2, type='browser', force=True)
        eventually('replacement ready', lambda: app.rpc('web.get', pane=p2)['ready'])
        app.rpc('web.snapshot', pane=p2, expectedViewId=old['viewId'], expectedDocumentId=old['documentId'], error=-32050)
        # Sleeping waits retain logical action slots even between platform probes.
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as requests:
            waits = [requests.submit(app.rpc, 'web.wait', pane='p1', selector='#never', timeoutMilliseconds=5000, error=-32024) for _ in range(32)]
            eventually('32 logical web actions', lambda: app.rpc('browser.get', pane='p1')['pendingActions'] == 32)
            app.rpc('web.wait', pane='p1', selector='#never', timeoutMilliseconds=0, error=-32025)
            for wait in waits: wait.result(timeout=8)
        assert app.rpc('browser.get', pane='p1')['pendingActions'] == 0
        app.rpc('web.wait', pane='p1', selector='#result', state='visible', timeoutMilliseconds=0)
        print('PASS shared web: browser/plugin/CLI/page conformance, identities without bridge use, ref/selector guards, worlds/exposure, renderability, restart/BFCache/replacement, superseded navigation, retirement/cancellation and32/33 logical admission')
    finally:
        for _, release in navigation_gates.values(): release.set()
        server.shutdown(); server.server_close(); worker.join(timeout=2)
