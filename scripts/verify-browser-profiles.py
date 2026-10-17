#!/usr/bin/env python3
"""One owned window and one restart: browser profile, clearing and trusted-client parity."""
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
from api_fixture import AppFixture, APP, ROOT, eventually
from plugin_package_fixture import package_fixture

# Rendered evidence is a separate, opt-in check requiring a fully visible owned window.
CAPTURE_UI = os.environ.get('SLATE_TERM_CAPTURE_BROWSER_UI') == '1'


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Profile Fixture</title><h1>Browser profile fixture</h1><p>Local test page</p>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def service_call(context, method, params):
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(20)
        peer.connect(context['SLATE_TERM_SOCKET'])
        with peer.makefile('rb') as stream:
            peer.sendall(json.dumps(dict(jsonrpc='2.0', id=1, method='hello', params={'protocolVersion': 1})).encode() + b'\n')
            assert json.loads(stream.readline())['result']['service']['generation'] == context['SLATE_TERM_SERVICE_GENERATION']
            peer.sendall(json.dumps(dict(jsonrpc='2.0', id=2, method=method, params=params)).encode() + b'\n')
            reply = json.loads(stream.readline())
            assert 'error' not in reply, reply
            return reply['result']


with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Page) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_port}/'
    other = f'http://localhost:{server.server_port}/'
    try:
        with AppFixture('browser-profiles') as app:
            def command(id, **params):
                return app.rpc('command.run', id=id, **params)

            def navigate(pane, address=url):
                app.rpc('browser.navigate', pane=pane, url=address)

            def js(pane, script):
                return app.rpc('browser.eval', pane=pane, script=script)

            def seed(pane, value):
                js(pane, f'localStorage.setItem("profile",{json.dumps(value)});document.cookie="profile={value};max-age=3600;path=/";true')

            def value(pane):
                return js(pane, '({saved:localStorage.getItem("profile"),cookie:document.cookie,bridge:typeof workspace})')

            def switch(pane, type):
                command('pane.type', pane=pane, type=type, force=True)
                navigate(pane)

            command('pane.type', pane='p1', type='browser', force=True)
            navigate('p1')
            p2 = command('split.right', pane='p1')['paneId']
            switch(p2, 'browser')
            seed('p1', 'persistent')
            eventually('shared website data propagation', lambda: value(p2)['saved'] == 'persistent' and 'persistent' in value(p2)['cookie'])
            print('PASS cross-pane shared profile', flush=True)
            assert value(p2)['bridge'] == 'undefined'
            switch(p2, 'private-browser')
            assert value(p2)['saved'] is None and value(p2)['cookie'] == ''
            seed(p2, 'private')
            p3 = command('split.down', pane=p2)['paneId']
            switch(p3, 'private-browser')
            assert value(p3)['saved'] is None and value(p3)['cookie'] == ''
            assert value('p1')['saved'] == 'persistent'
            assert app.rpc('browser.get', pane=p2)['persistent'] is False
            assert app.rpc('pane.inspect', pane=p2)['type'] == 'private-browser'
            menu = app.rpc('debug.paneTypeMenu', pane=p2)
            assert {'browser', 'private-browser'}.issubset({item['type'] for item in menu})

            # Restore both types but never restore a private store, even with the same pane ID.
            profile = json.loads((app.root / 'state/browser-profile.json').read_text())
            app.process.terminate()
            app.process.wait(timeout=10)
            app.ready.unlink()
            app.process = subprocess.Popen([str(APP)], env=app.env, stdout=app.log, stderr=app.log, start_new_session=True)
            eventually('restarted fixture ready', lambda: app.ready.exists() and app.process.poll() is None)
            app.path = app.ready.read_text().strip()
            app.env['SLATE_TERM_SOCKET'] = app.path
            assert json.loads((app.root / 'state/browser-profile.json').read_text()) == profile
            assert app.rpc('pane.inspect', pane=p2)['type'] == 'private-browser'
            navigate('p1'); navigate(p2); navigate(p3)
            assert value('p1')['saved'] == 'persistent' and 'persistent' in value('p1')['cookie']
            assert value(p2)['saved'] is None and value(p2)['cookie'] == ''
            seed(p2, 'private')

            # Strict validation: no focus/URL inference and no accidentally accepted fields/guards.
            for method, params in [
                ('browser.clearSiteData', {'pane': 'p1'}),
                ('browser.clearSiteData', {'url': url}),
                ('browser.clearSiteData', {'pane': 'p1', 'url': 'about:blank'}),
                ('browser.clearSiteData', {'pane': 'p1', 'url': 'example.com'}),
                ('browser.clearSiteData', {'pane': 'p1', 'url': url, 'typo': True}),
                ('browser.clearSiteData', {'pane': 'p1', 'url': url, 'expectedDocumentId': 'unsupported'}),
                ('browser.clearData', {'pane': 'p1'}), ('browser.clearData', {'url': url}),
                ('browser.clearData', {'id': 'unexpected'}),
                ('browser.clearSiteData', {'id': 'unexpected', 'pane': 'p1', 'url': url}),
                ('command.run', {'id': 'browser.clearSiteData', 'pane': p2}),
            ]:
                app.rpc(method, error=-32602, **params)
            assert value('p1')['saved'] == 'persistent'
            app.rpc('browser.clearSiteData', pane='p1', url=url, expectedInstanceId='stale', error=-32050)

            # The supplied URL, not the current page, selects the site; other domains survive.
            navigate('p1', other); seed('p1', 'other')
            reply = app.cli('browser', 'clear-site-data', '--pane', 'p1', '--url', url)
            assert reply == dict(cleared=True, scope='site', storage='persistent', host='127.0.0.1')
            assert value('p1')['saved'] == 'other'
            navigate('p1')
            assert value('p1')['saved'] is None and value('p1')['cookie'] == ''
            assert value(p2)['saved'] == 'private'
            command('browser.clearSiteData', pane=p2, url=url)
            assert value(p2)['saved'] is None

            # Native cancellation shows a warning and leaves data intact; API clear has no popup.
            seed('p1', 'native')
            capture = {'screenshot': str(ROOT / 'artifacts/browser-clear-warning.png')} if CAPTURE_UI else {}
            shown = app.rpc('debug.browserDataConfirmation', answer='cancel', **capture)
            assert shown['warning'] and 'cannot be undone' in shown['explanation']
            assert value('p1')['saved'] == 'native'
            seed(p2, 'all-clear-must-preserve-private')
            app.rpc('debug.browserDataConfirmation', answer='clear')
            eventually('native clear completed', lambda: value('p1')['saved'] is None)
            assert value(p2)['saved'] == 'all-clear-must-preserve-private'
            seed('p1', 'not-target'); seed(p2, 'native-private')
            site_capture = {'screenshot': str(ROOT / 'artifacts/browser-clear-site-warning.png')} if CAPTURE_UI else {}
            site_warning = app.rpc('debug.browserDataConfirmation', id='browser.clearSiteData', pane=p2, answer='cancel', **site_capture)
            assert site_warning['warning'] and '127.0.0.1' in site_warning['explanation']
            assert value(p2)['saved'] == 'native-private'
            app.rpc('debug.browserDataConfirmation', id='browser.clearSiteData', pane=p2, answer='clear', focusPane='p1')
            eventually('native private site clear completed', lambda: value(p2)['saved'] is None)
            assert value('p1')['saved'] == 'not-target', 'Modal focus changes redirected clearing'

            # Both commands are available in the bar with Private Browser focus.
            command('pane.focus', pane=p2)
            picker = app.rpc('debug.commandPicker', show=True, pane=p2, query='Clear')
            results = {item['id']: item for item in picker['results']}
            assert results['browser.clearData']['enabled'] and results['browser.clearSiteData']['enabled']
            (ROOT / 'artifacts/browser-picker.json').write_text(json.dumps(picker, indent=2))
            if CAPTURE_UI:
                app.rpc('debug.screenshot', pickerContext=True, path=str(ROOT / 'artifacts/browser-clear-picker-context.png'))
            app.rpc('debug.commandPicker', dismiss=True)
            if CAPTURE_UI:
                app.rpc('debug.menuPreview', pane=p2, path=str(ROOT / 'artifacts/browser-pane-types.png'))

            # Page bridge and a live service use the same discovery and operations.
            assets = app.root / 'panel'; assets.mkdir()
            (assets / 'index.html').write_text('<!doctype html><title>Browser Controller</title><p>Trusted controller</p>')
            worker = app.root / 'worker.py'
            worker.write_text('import os,json,pathlib,time\npathlib.Path(os.environ["CONTEXT_FILE"]).write_text(json.dumps(dict(os.environ)))\nwhile True: time.sleep(1)\n')
            app.rpc('plugins.register', packagePath=package_fixture(dict(id='profile.fixture', title='Controller', source=dict(kind='directory', path=str(assets)),
                service=dict(executable=sys.executable, arguments=[str(worker)], environment={'CONTEXT_FILE': str(app.root / 'service-context')}, readyTimeoutSeconds=30)), app.root))
            # Default service readiness is explicit; the endpoint is usable while starting.
            command('pane.type', pane=p3, type='profile.fixture', force=True)
            eventually('controller bridge', lambda: app.rpc('debug.pluginEval', pane=p3, script='typeof workspace') == 'object')
            app.rpc('plugins.service.start', id='profile.fixture')
            eventually('controller service context', lambda: (app.root / 'service-context').exists())
            context = json.loads((app.root / 'service-context').read_text())
            service_call(context, 'service.ready', {'version': 1})

            def bridge(method, params):
                return app.rpc('debug.pluginEval', pane=p3, script='await workspace.call(' + json.dumps(method) + ',' + json.dumps(params) + ')')

            for call in [bridge, lambda method, params: service_call(context, method, params)]:
                assert call('api.describe', {})['browserData']['persistentProfile'] == 'appWide'
                seed('p1', 'trusted'); seed(p2, 'trusted-private')
                call('browser.clearSiteData', {'pane': p2, 'url': url})
                assert value(p2)['saved'] is None and value('p1')['saved'] == 'trusted'
                seed(p2, 'all-clear-preserves-private')
                assert call('browser.clearData', {}) == dict(cleared=True, scope='all', storage='persistent', host=None)
                # Observe the live page separately from WebKit's store-removal callback.
                # Cross-process cache invalidation need not arrive in the same turn.
                eventually('trusted all-data clear reaches live page', lambda: value('p1')['saved'] is None)
                private = value(p2)
                assert private['saved'] == 'all-clear-preserves-private', private
            app.cli('browser', 'clear-data')
            print('PASS browser profiles: shared persistence across restart, private isolation, explicit-site selection, native consent/cancel, CLI/page/service clearing and bridge isolation')
    finally:
        server.shutdown()
