#!/usr/bin/env python3
"""One owned app/two native tabs: shared web capture, automation and lifecycle guards."""
import argparse
import concurrent.futures
import functools
import http.server
import json
import os
import subprocess
import threading
from api_fixture import AppFixture, ROOT, eventually
from plugin_package_fixture import package_fixture
from browser_dialog_checks import check_browser_dialogs
from browser_popup_checks import run_popup_checks
from browser_download_checks import check_browser_downloads

parser = argparse.ArgumentParser()
parser.add_argument('--external-file-input', action='store_true')
parser.add_argument('--external-browser-input', action='store_true')
args = parser.parse_args()

HTML = '''<!doctype html><title>Shared web fixture</title>
<input id="name" value="before"><input id="password" type="password" value="PASSWORD_SENTINEL">
<button id="apply" onclick="document.querySelector('#result').textContent=document.querySelector('#name').value">Apply</button>
<button id="disabled" disabled>Disabled</button><p id="result">ready</p>
<select id="choice"><option value="a">A</option><option value="b">B</option></select>
<input type="file" id="upload"><input type="file" id="uploads" multiple>
<input type="file" id="directory" webkitdirectory><p id="files">no files</p>
<iframe src="child.html"></iframe><div style="height:1800px">scroll</div>
<script>addEventListener('pageshow', e=>window.restored=e.persisted);
for (const id of ['upload','uploads','directory']) document.getElementById(id).onchange = async e => {
  document.getElementById('files').textContent = (await Promise.all(Array.from(e.target.files, async f => f.name+':'+await f.text()))).join('|');
};
</script>'''

navigation_gates = {path: (threading.Event(), threading.Event()) for path in ['/held-a', '/held-b']}


def screenshot_checker():
    prebuilt = os.environ.get('SLATE_VM_SCREENSHOT_CHECK')
    return [prebuilt] if prebuilt else ['swift', str(ROOT / 'Tests/WebOperations/CheckScreenshot.swift')]


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
    app.capture_contracts()
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
        app.rpc('plugins.register', packagePath=package_fixture(dict(id='web.fixture', title='Web fixture', source=dict(kind='directory', path=str(assets))), app.root))
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
        assert all(exposure['webAutomation'][key] for key in ['screenshotInactiveTabs', 'screenshotRequiresAttachedLayout', 'screenshotViewportOnly', 'domRequiresVisiblePane'])
        assert js('workspace.call("web.eval",{script:"1"}).then(()=>null,e=>e.code)') == -32601
        assert js('workspace.browser.eval({pane:"p1",script:"1"})') == 1

        # Real WebKit chooser callbacks, shared by native UI, socket, CLI and page bridge.
        upload_a, upload_b = app.root / 'upload-a.txt', app.root / 'upload-b.txt'
        upload_a.write_text('first-file-bytes')
        upload_b.write_text('second-file-bytes')
        upload_dir = app.root / 'upload-directory'
        upload_dir.mkdir()
        (upload_dir / 'nested.txt').write_text('directory-bytes')
        assert exposure['webAutomation']['fileChooser']

        def open_chooser(pane, selector='#upload'):
            info = app.rpc('web.get', pane=pane)
            app.rpc('web.click', pane=pane, selector=selector,
                    expectedViewId=info['viewId'], expectedDocumentId=info['documentId'])
            eventually('pending native file chooser', lambda: app.rpc('web.fileChooser', pane=pane)['chooser'] is not None)
            return app.rpc('web.fileChooser', pane=pane)['chooser']

        for pane in ['p1', p2]:
            tab = app.rpc('pane.inspect', pane=pane)['tabId']
            app.rpc('debug.activate', tab=tab)
            eventually('active app for native chooser', lambda: app.rpc('debug.inspect')['applicationActive'])
            assert app.rpc('web.fileChooser', pane=pane)['chooser'] is None
            chooser = open_chooser(pane)
            cid = chooser['chooserId']
            assert not chooser['allowsMultipleSelection'] and not chooser['allowsDirectories']
            assert app.cli('web', 'file-chooser', '--pane', pane)['chooser']['chooserId'] == cid
            app.rpc('web.chooseFiles', pane=pane, chooserId='stale', paths=[str(upload_a)], error=-32050)
            app.rpc('web.chooseFiles', pane=pane, chooserId=cid, paths=[str(upload_a), str(upload_b)], error=-32602)
            app.rpc('web.chooseFiles', pane=pane, chooserId=cid, paths=[str(upload_dir)], error=-32602)
            app.rpc('web.chooseFiles', pane=pane, chooserId=cid, paths=[str(app.root / 'missing')], error=-32602)
            app.rpc('web.chooseFiles', pane=pane, chooserId=cid, paths=[str(upload_a)],
                    expectedViewId='stale', expectedDocumentId='stale', error=-32050)
            assert app.rpc('web.fileChooser', pane=pane)['chooser']['chooserId'] == cid
            selected = app.cli('web', 'choose-files', '--pane', pane, '--chooser-id', cid, '--file', str(upload_a))
            assert selected['selectedCount'] == 1 and not selected['cancelled']
            eventually('file bytes available in page', lambda: 'upload-a.txt:first-file-bytes' in app.rpc('web.snapshot', pane=pane)['text'])
            app.rpc('web.cancelFileChooser', pane=pane, chooserId=cid, error=-32050)

            chooser = open_chooser(pane, '#uploads')
            assert chooser['allowsMultipleSelection']
            app.rpc('web.chooseFiles', pane=pane, chooserId=chooser['chooserId'],
                    paths=[str(upload_a), str(app.root / 'missing')], error=-32602)
            assert app.rpc('web.fileChooser', pane=pane)['chooser']['chooserId'] == chooser['chooserId']
            params = dict(pane=pane, chooserId=chooser['chooserId'], paths=[str(upload_a), str(upload_b)])
            assert js('workspace.web.chooseFiles(' + json.dumps(params) + ')')['selectedCount'] == 2
            eventually('multiple file bytes available', lambda: 'upload-b.txt:second-file-bytes' in app.rpc('web.snapshot', pane=pane)['text'])
            chooser = open_chooser(pane)
            cancelled = app.cli('web', 'cancel-file-chooser', '--pane', pane, '--chooser-id', chooser['chooserId'])
            assert cancelled['cancelled'] and cancelled['selectedCount'] == 0
            assert app.rpc('web.fileChooser', pane=pane)['chooser'] is None
            chooser = open_chooser(pane)
            app.rpc('debug.screenshot', tab=tab, sheet=True, path=str(ROOT / f'artifacts/web-file-chooser-{pane}.png'))
            if args.external_file_input and pane == 'p1':
                print('FILE_CHOOSER_NATIVE_CANCEL_READY', flush=True)
                eventually('external native chooser cancellation', lambda: app.rpc('web.fileChooser', pane=pane)['chooser'] is None, timeout=120)
                app.rpc('web.chooseFiles', pane=pane, chooserId=chooser['chooserId'], paths=[str(upload_a)], error=-32050)
                chooser = open_chooser(pane)
                print('FILE_CHOOSER_NATIVE_SELECT_READY ' + str(upload_b), flush=True)
                eventually('external native file selection', lambda: app.rpc('web.fileChooser', pane=pane)['chooser'] is None, timeout=120)
                eventually('native selection file bytes', lambda: app.rpc('browser.eval', pane=pane,
                           script="document.querySelector('#upload').files[0]?.name") == upload_b.name)
                assert 'upload-b.txt:second-file-bytes' in app.rpc('web.snapshot', pane=pane)['text']
                print('PASS native picker cancellation and confirmation through external input', flush=True)
            else:
                app.rpc('web.cancelFileChooser', pane=pane, chooserId=chooser['chooserId'])

        chooser = open_chooser('p1', '#directory')
        assert chooser['allowsDirectories']
        app.rpc('web.chooseFiles', pane='p1', chooserId=chooser['chooserId'], paths=[str(upload_a)], error=-32602)
        app.rpc('web.chooseFiles', pane='p1', chooserId=chooser['chooserId'], paths=[str(upload_dir)])
        eventually('directory file bytes available', lambda: 'nested.txt:directory-bytes' in app.rpc('web.snapshot', pane='p1')['text'])

        # Navigation retires the pending chooser; its ID cannot select into a new one.
        chooser = open_chooser('p1')
        app.rpc('browser.navigate', pane='p1', url=base + '/index.html')
        assert app.rpc('web.fileChooser', pane='p1')['chooser'] is None
        newer = open_chooser('p1')
        app.rpc('web.chooseFiles', pane='p1', chooserId=chooser['chooserId'], paths=[str(upload_a)], error=-32050)
        app.rpc('web.cancelFileChooser', pane='p1', chooserId=newer['chooserId'])

        private_tab = app.rpc('command.run', id='tab.new', focus='new')
        private_pane = app.rpc('context.inspect')['focusedPaneId']
        app.rpc('command.run', id='pane.type', pane=private_pane, type='private-browser', force=True)
        app.rpc('browser.navigate', pane=private_pane, url=base + '/index.html')
        chooser = open_chooser(private_pane)
        app.rpc('web.chooseFiles', pane=private_pane, chooserId=chooser['chooserId'], paths=[str(upload_a)])
        eventually('private file bytes available', lambda: 'upload-a.txt:first-file-bytes' in app.rpc('web.snapshot', pane=private_pane)['text'])
        chooser = open_chooser(private_pane)
        app.rpc('command.run', id='tab.close', tab=private_tab['tabId'], force=True)
        # The retired private chooser cannot complete a new request in the surviving view.
        chooser_main = open_chooser('p1')
        app.rpc('web.chooseFiles', pane='p1', chooserId=chooser['chooserId'], paths=[str(upload_a)], error=-32050)
        app.rpc('web.cancelFileChooser', pane='p1', chooserId=chooser_main['chooserId'])
        print('PASS native file choosers, file bytes, CLI/page parity, invalid selection and navigation lifetime')
        check_browser_downloads(app, p2, external_input=args.external_browser_input)
        check_browser_dialogs(app, 'p1', p2, base)
        run_popup_checks(app, assets, base, controller_pane=p2, external_input=args.external_browser_input)

        output = app.root / 'plugin-bridge.png'
        js('workspace.web.screenshot({path:' + json.dumps(str(output)) + '})')
        assert output.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')

        # Canonical capture accepts attached inactive-tab views, not DOM actions.
        captures = ROOT / 'artifacts/web-background-captures'
        captures.mkdir(exist_ok=True)
        identities = {pane: app.rpc('web.get', pane=pane) for pane in ['p1', p2]}
        source_tab = app.rpc('pane.inspect', pane=p2)['tabId']
        app.rpc('command.run', id='tab.new', focus='new')
        active = app.rpc('context.inspect')['focusedPaneId']

        def focus_state():
            native = app.rpc('debug.inspect')
            return dict(workspace=app.rpc('workspace.get'),
                        windows=[(w['windowId'], w['selected'], w['key']) for w in app.rpc('window.list')['windows']],
                        responders=[(p['paneId'], p['firstResponder'], p['terminalFocus']) for p in native['panes']])

        before = focus_state()
        native_windows = app.rpc('window.list')['windows']
        source_window = next(w for w in native_windows if w['tabId'] == source_tab)
        front_tab = app.rpc('pane.inspect', pane=active)['tabId']
        front_window = next(w for w in native_windows if w['tabId'] == front_tab)
        assert source_window['groupId'] == front_window['groupId']
        assert not source_window['selected'] and front_window['selected'], native_windows
        dom_visibility = []
        assert next(p for p in app.rpc('debug.inspect')['panes'] if p['paneId'] == active)['firstResponder']
        pixel_args = []
        for pane in ['p1', p2]:
            eventually('inactive capture-ready', lambda: app.rpc('web.get', pane=pane)['screenshotReady'])
            info = app.rpc('web.get', pane=pane)
            inspected = app.rpc('pane.inspect', pane=pane)
            assert not inspected['visible'] and inspected['geometry'] is None
            assert not info['renderable'] and info['documentId'] == identities[pane]['documentId']
            guards = dict(expectedViewId=info['viewId'], expectedDocumentId=info['documentId'])
            app.rpc('web.snapshot', pane=pane, error=-32051)
            app.rpc('web.click', pane=pane, selector='#apply', **guards, error=-32051)
            app.rpc('web.fill', pane=pane, selector='#name', text='hidden mutation', **guards, error=-32051)
            app.rpc('web.wait', pane=pane, selector='#result', timeoutMilliseconds=0, error=-32051)
            for phase, rgb in [('green', [20,190,70]), ('blue', [30,80,220])]:
                script = '''(()=>{let p=document.getElementById('capture-check');
                    if(!p){p=document.createElement('div');p.id='capture-check';document.body.appendChild(p)}
                    p.style.cssText='position:fixed;inset:0;z-index:2147483647;pointer-events:none;color:white;background:rgb(%s)';
                    p.textContent='INACTIVE %s';return document.visibilityState})()''' % (','.join(map(str,rgb)), phase)
                visibility = app.rpc('browser.eval' if pane == 'p1' else 'debug.pluginEval', pane=pane, script=script)
                # WebKit's page visibility signal can lag/differ from native tab
                # selection. Assert the actual native state, without changing DOM visibility.
                dom_visibility.append(dict(pane=pane, phase=phase, visibility=visibility))
                assert not next(w for w in app.rpc('window.list')['windows'] if w['tabId'] == source_tab)['selected']
                path = captures / f'{pane}-{phase}.png'
                # CLI and registered-page requests share the canonical host operation.
                if phase == 'green':
                    result = app.cli('web', 'screenshot', '--pane', pane, '--path', str(path),
                                     '--expected-view-id', info['viewId'], '--expected-document-id', info['documentId'])
                else:
                    result = js('await workspace.web.screenshot(' + json.dumps(dict(pane=pane, path=str(path), **guards)) + ')')
                assert result['path'] == str(path) and result['documentId'] == info['documentId']
                assert focus_state() == before, 'Screenshot changed tab selection/focus/workspace'
                pixel_args.extend([str(path), *map(str,rgb)])
            app.rpc('browser.eval' if pane == 'p1' else 'debug.pluginEval', pane=pane, script="(()=>{document.getElementById('capture-check').remove();return true})()")
        checked = subprocess.run([*screenshot_checker(), *pixel_args],
                                 text=True, capture_output=True, timeout=60)
        assert checked.returncode == 0, checked.stderr
        (captures / 'pixels.json').write_text(checked.stdout)
        (captures / 'focus.json').write_text(json.dumps(dict(before=before, domVisibility=dom_visibility), indent=2))
        app.rpc('command.run', id='tab.focus', tab=source_tab)
        eventually('foreground restored', lambda: app.rpc('web.get', pane=p2)['renderable'])

        # In-flight divider geometry is unavailable, even for attached views.
        assert app.rpc('debug.dividerGesture', phase='begin', tab=source_tab, path=[])['active']
        try:
            for pane in ['p1', p2]:
                assert not app.rpc('web.get', pane=pane)['screenshotReady']
                app.rpc('web.screenshot', pane=pane, path=str(app.root / 'invalid-layout.png'), error=-32051)
            assert not (app.root / 'invalid-layout.png').exists()
        finally:
            app.rpc('debug.dividerGesture', phase='cancel', tab=source_tab)

        # Hiding via existing zoom is not document retirement or permission to reveal.
        old = app.rpc('web.get', pane=p2)
        app.rpc('command.run', id='pane.zoom', pane='p1')
        assert app.rpc('web.get', pane=p2)['renderable'] is False
        assert app.rpc('web.get', pane=p2)['screenshotReady'] is False
        app.rpc('web.snapshot', pane=p2, error=-32051)
        app.rpc('web.screenshot', pane=p2, path=str(app.root / 'zoom-hidden.png'), error=-32051)
        assert not (app.root / 'zoom-hidden.png').exists()
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
                assert not app.rpc('web.get', pane='p1')['screenshotReady']
                app.rpc('web.screenshot', pane='p1', path=str(app.root / 'unready.png'), error=-32051)
                assert not (app.root / 'unready.png').exists()
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
        app.rpc('web.screenshot', pane=p2, path=str(app.root / 'replaced.png'),
                expectedViewId=old['viewId'], expectedDocumentId=old['documentId'], error=-32050)
        assert not (app.root / 'replaced.png').exists()
        app.rpc('command.run', id='pane.close', pane=p2, force=True)
        app.cli('web', 'screenshot', '--pane', p2, '--path', str(app.root / 'closed.png'), error=True)
        assert not (app.root / 'closed.png').exists()
        # Sleeping waits retain logical action slots even between platform probes.
        with concurrent.futures.ThreadPoolExecutor(max_workers=32) as requests:
            waits = [requests.submit(app.rpc, 'web.wait', pane='p1', selector='#never', timeoutMilliseconds=5000, error=-32024) for _ in range(32)]
            eventually('32 logical web actions', lambda: app.rpc('browser.get', pane='p1')['pendingActions'] == 32)
            app.rpc('web.wait', pane='p1', selector='#never', timeoutMilliseconds=0, error=-32025)
            for wait in waits: wait.result(timeout=8)
        assert app.rpc('browser.get', pane='p1')['pendingActions'] == 0
        app.rpc('web.wait', pane='p1', selector='#result', state='visible', timeoutMilliseconds=0)
        print('PASS shared web: browser/plugin/CLI/page conformance, identities without bridge use, ref/selector guards, worlds/exposure, inactive-tab pixels/focus, DOM visibility, invalid-layout/zoom/unready/closed capture rejection, restart/BFCache/replacement, superseded navigation, retirement/cancellation and32/33 logical admission')
    finally:
        for _, release in navigation_gates.values(): release.set()
        server.shutdown(); server.server_close(); worker.join(timeout=2)
