#!/usr/bin/env python3
"""First-pass production API/CLI/registered-page parity. Run only through verify-vm.py."""
import json
import time
import os
import subprocess
import sys
from api_fixture import AppFixture, APP, ROOT, eventually
from plugin_package_fixture import package_fixture

assert subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip().startswith('VirtualMac'), 'Run this UI gate through scripts/verify-vm.py'

HTML = '''<!doctype html><title>Parity fixture</title>
<style>body{padding:20px}input,button{display:block;margin:6px}#keys{height:35px}</style>
<form id="form" onsubmit="event.preventDefault();document.querySelector('#result').textContent='submitted'">
<input id="text"><button id="submit" name="action" value="save" onclick="document.querySelector('#clicked').textContent='clicked'">Submit</button></form>
<p id="clicked">untouched</p>
<form onsubmit="event.preventDefault();document.querySelector('#result').textContent='disabled-submit-bug'">
<input id="disabled-submit-text"><button disabled>Disabled submit</button></form>
<form onsubmit="event.preventDefault();document.querySelector('#result').textContent='multiple-submit-bug'">
<input id="multiple-a"><input id="multiple-b"></form>
<button id="before-negative" type="button">Before</button><div id="negative" tabindex="-1">Negative</div><button id="after-negative" type="button">After</button>
<input id="datetime" type="datetime-local"><input id="month" type="month"><input id="week" type="week">
<div id="keys" tabindex="0" role="button" onkeydown="if(event.key==='ArrowDown'){this.textContent='moved';event.preventDefault()}else if(event.key==='+'){this.dataset.plus='yes'}">keys</div>
<input id="check" type="checkbox"><input id="radio" type="radio" name="group">
<input id="other" type="radio" name="group" checked>
<input id="number" type="number" min="1" max="10" step="1" value="2">
<input id="date" type="date"><input id="time" type="time">
<input id="range" type="range" min="0" max="10" step="1" value="2">
<input id="disabled" type="checkbox" disabled><input id="readonly" type="number" readonly>
<input id="veto" type="checkbox" onclick="event.preventDefault()">
<input id="controlled" type="number" value="3" oninput="this.value='3'">
<p id="result">ready</p>
<button id="space-cancel" type="button" onclick="this.dataset.clicked='yes'" onkeyup="if(event.key===' ')event.preventDefault()">Cancel Space</button>
<button id="before-summary" type="button">Before summary</button><details><summary id="summary">Summary</summary></details><button type="button">After summary</button>
<form onsubmit="event.preventDefault();document.querySelector('#shadow-result').textContent='submitted'">
<input id="shadow-text"><input type="hidden" name="requestSubmit"></form><p id="shadow-result">ready</p>
<button id="release-source" type="button" onkeydown="window.keyHeld=true" onkeyup="window.keyHeld=false">Release source</button>
<button id="reject-focus" type="button" onfocus="this.blur()">Reject focus</button>'''

with AppFixture('api-parity') as app:
    describe = app.rpc('api.describe')
    assert {'web.focus', 'web.key', 'web.check', 'web.setValue'} <= set(describe['methods'])
    window = app.rpc('window.list')['windows'][0]
    wid = window['windowId']
    frame = window['visibleScreenFrame']
    desired = dict(x=frame['x']+20, y=frame['y']+20, width=min(900, frame['width']-40), height=min(700, frame['height']-40))
    session = app.rpc('pane.inspect', pane='p1')['sessionId']
    cursor = app.rpc('events.head')['cursor']
    resized = app.cli('windows', 'frame', '--window-id', wid, *[arg for key, value in desired.items() for arg in ['--'+key, str(value)]])
    assert resized['accepted'] and all(abs(resized['frame'][key]-value)<2 for key, value in desired.items()), resized
    assert app.rpc('pane.inspect', pane='p1')['sessionId'] == session
    if resized['settled']:
        assert all(resized['frame'][key] == value for key, value in desired.items())
    eventually('native presentation event', lambda: any(e['payload'].get('windowId') == wid for e in app.rpc('events.poll', after=cursor, topics=['host.window.changed'], waitMilliseconds=0)['events']))
    unchanged = app.rpc('command.run', id='window.frame.set', windowId=wid, **desired)
    assert unchanged['changed'] is False and unchanged['settled'], unchanged
    app.rpc('command.run', id='window.frame.set', windowId=wid, **dict(desired, width=-1), error=-32602)
    app.rpc('command.run', id='window.frame.set', windowId=wid, **dict(desired, x=1_000_000), error=-32602)
    app.rpc('command.run', id='window.minimize', windowId='closed', error=-32051)
    app.rpc('command.run', id='window.minimize', windowId=wid, expectedLayoutRevision='bad', error=-32602)
    minimized = app.cli('windows', 'minimize', '--window-id', wid)
    assert not minimized['settled'] or minimized['minimized'], minimized
    eventually('minimized', lambda: app.rpc('window.get', windowId=wid)['minimized'])
    restored = app.cli('windows', 'restore', '--window-id', wid)
    assert not restored['settled'] or not restored['minimized'], restored
    eventually('restored', lambda: not app.rpc('window.get', windowId=wid)['minimized'])
    app.rpc('command.run', id='window.focus', windowId=wid)
    tab = app.rpc('command.run', id='tab.new')['tabId']
    app.rpc('command.run', id='window.minimize', windowId=wid, error=-32051)
    app.rpc('command.run', id='tab.close', tab=tab, force=True)
    app.rpc('command.run', id='window.focus', windowId=wid)
    entering = app.cli('windows', 'fullscreen', '--window-id', wid, '--enabled', 'true')
    assert entering['accepted']
    eventually('fullscreen completion or explicit failure', lambda: not app.rpc('window.get', windowId=wid)['fullscreenTransitionPending'], timeout=30)
    settled = app.rpc('window.get', windowId=wid)
    assert settled['fullscreen'], settled
    app.rpc('command.run', id='window.frame.set', windowId=wid, **desired, error=-32051)
    app.cli('windows', 'fullscreen', '--window-id', wid, '--enabled', 'false')
    eventually('exit fullscreen', lambda: not app.rpc('window.get', windowId=wid)['fullscreenTransitionPending'], timeout=30)
    assert not app.rpc('window.get', windowId=wid)['fullscreen']

    for kind, field in [('close', 'closeWarning'), ('type', 'typeWarning')]:
        assert app.cli('warnings', kind, '--suppressed', 'true')['suppressed']
        assert app.rpc('config.get')[field]['suppressed']
        store = app.root / 'state' / f'suppress-{kind}-warning.json'
        inode = store.stat().st_ino
        app.rpc('command.run', id=f'warnings.{kind}.set', suppressed=True)
        assert store.stat().st_ino == inode, 'No-op preference rewrote its store'
        app.rpc('command.run', id=f'warnings.{kind}.set', suppressed='true', error=-32602)
        app.rpc('command.run', id=f'warnings.{kind}.set', suppressed=False, expectedSourceRevision='unsupported', error=-32602)
        assert app.rpc('config.get')[field]['suppressed']
        assert json.loads((app.root / 'state' / f'suppress-{kind}-warning.json').read_text()) is True
    # Persisted suppression survives a real owned-app restart.
    app.process.terminate(); app.process.wait(timeout=10)
    app.ready.unlink()
    launched = time.time()
    app.process = subprocess.Popen([str(APP)], env=app.env, stdout=app.log, stderr=app.log, start_new_session=True)
    probe = subprocess.Popen(['/usr/bin/sample', str(app.process.pid), '9', '2', '-file', str(ROOT / 'artifacts/api-parity-launch-sample.txt')],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    eventually('restarted fixture', lambda: app.ready.exists() and app.process.poll() is None)
    print(f'TIMING launched={launched:.3f} ready_seen={time.time():.3f}', flush=True)
    import socket as _socket
    for _ in range(30):
        started = time.time()
        with _socket.socket(_socket.AF_UNIX) as probe_socket:
            probe_socket.settimeout(10)
            probe_socket.connect(app.ready.read_text().strip())
            probe_socket.sendall(b'{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":1}}\n')
            probe_socket.recv(65536)
        print(f'TIMING hello at={started:.3f} took={time.time() - started:.3f}', flush=True)
        time.sleep(0.1)
    probe.wait(timeout=10)
    print('TIMING trace', (app.root / 'shell-reports.log').read_text(), flush=True)
    app.path = app.ready.read_text().strip(); app.env['SLATE_TERM_SOCKET'] = app.path
    assert app.rpc('config.get')['closeWarning']['suppressed']
    assert app.rpc('config.get')['typeWarning']['suppressed']
    # Preference suppression never grants API destructive consent.
    eventually('idle shell after restart', lambda: app.rpc('pane.inspect', pane='p1').get('state') == 'prompt')
    app.rpc('terminal.send', pane='p1', text='sleep 30\n')
    eventually('running shell', lambda: app.rpc('pane.inspect', pane='p1').get('state') == 'running')
    eventually('native close consent required', lambda: next(p for p in app.rpc('debug.inspect')['panes'] if p['paneId'] == 'p1')['needsConfirmClose'])
    app.rpc('command.run', id='pane.close', pane='p1', error=-32010)
    app.rpc('terminal.key', pane='p1', key='ctrl+c')
    for kind in ['close', 'type']:
        assert app.rpc('command.run', id=f'warnings.{kind}.reset')['suppressed'] is False
    store = app.root / 'state/suppress-close-warning.json'
    saved = store.read_bytes(); store.unlink(); store.mkdir()
    try:
        assert app.cli('warnings', 'close', '--suppressed', 'true', error=True)
        assert app.rpc('config.get')['closeWarning']['suppressed'] is False
    finally:
        store.rmdir(); store.write_bytes(saved); store.chmod(0o600)

    assets = app.root / 'assets'; assets.mkdir()
    (assets / 'index.html').write_text(HTML)
    app.rpc('command.run', id='pane.type', pane='p1', type='private-browser', force=True)
    app.rpc('browser.navigate', pane='p1', url=str(assets / 'index.html'))
    plugin = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='parity.fixture', title='Parity fixture', source=dict(kind='directory', path=str(assets))), app.root))
    app.rpc('command.run', id='pane.type', pane=plugin, type='parity.fixture', force=True)
    for pane in ['p1', plugin]:
        eventually('renderable', lambda: app.rpc('web.get', pane=pane).get('renderable') is True)
        info = app.rpc('web.get', pane=pane)
        guards = dict(expectedViewId=info['viewId'], expectedDocumentId=info['documentId'])
        def action(name, selector, **params):
            return app.rpc('web.'+name, pane=pane, selector=selector, **guards, **params)
        app.rpc('web.focus', pane=pane, selector='#text', error=-32602)
        assert action('focus', '#text')['focused']
        result = action('key', '#text', key='enter')
        assert result['defaultAction'] == 'submit' and result['synthetic']
        assert 'clicked' in app.rpc('web.snapshot', pane=pane)['text']
        assert action('key', '#disabled-submit-text', key='enter')['defaultAction'] == 'none'
        assert action('key', '#multiple-a', key='enter')['defaultAction'] == 'none'
        assert '-submit-bug' not in app.rpc('web.snapshot', pane=pane)['text']
        def inspect_js(script):
            return app.rpc('browser.eval' if pane == 'p1' else 'debug.pluginEval', pane=pane, script=script)
        action('key', '#negative', key='tab')
        assert inspect_js('document.activeElement.id') == 'after-negative'
        action('key', '#negative', key='shift+tab')
        assert inspect_js('document.activeElement.id') == 'before-negative'
        assert action('key', '#space-cancel', key='space')['defaultPrevented']
        assert inspect_js("document.querySelector('#space-cancel').dataset.clicked??null") is None
        action('key', '#before-summary', key='tab')
        assert inspect_js('document.activeElement.id') == 'summary'
        action('key', '#shadow-text', key='enter')
        assert inspect_js("document.querySelector('#shadow-result').textContent") == 'submitted'
        assert app.cli('rpc', 'web.key', '--params', json.dumps(dict(pane=pane,selector='#release-source',key='tab',**guards)), error=True)
        assert inspect_js('window.keyHeld') is False
        inspect_js("(()=>{const box=document.createElement('div');box.id='many';box.hidden=true;box.innerHTML='<input>'.repeat(4001);document.body.append(box);const e=document.querySelector('#text');e.onkeydown=()=>window.keyHeld=true;e.onkeyup=()=>window.keyHeld=false;return true})()")
        assert app.cli('rpc', 'web.key', '--params', json.dumps(dict(pane=pane,selector='#text',key='enter',**guards)), error=True)
        assert inspect_js('window.keyHeld') is False
        inspect_js("(()=>{document.querySelector('#many').remove();return true})()")
        action('key', '#keys', key='arrowdown')
        assert 'moved' in app.rpc('web.snapshot', pane=pane)['text']
        action('key', '#keys', key='plus')
        assert inspect_js("document.querySelector('#keys').dataset.plus") == 'yes'
        assert action('key', '#text', key='tab')['defaultAction'] == 'focus'
        assert action('check', '#check', checked=True)['checked']
        assert not action('check', '#check', checked=True)['performed']
        assert action('check', '#check', checked=False)['checked'] is False
        assert action('check', '#radio', checked=True)['checked']
        assert app.cli('rpc', 'web.check', '--params', json.dumps(dict(pane=pane, selector='#radio', checked=False, **guards)), error=True)
        for selector, value in [('#number','8'), ('#date','2026-10-16'), ('#time','12:30'), ('#range','7'), ('#datetime','2026-10-16T12:30')]:
            effective_type = inspect_js('document.querySelector('+json.dumps(selector)+').type')
            print('Typed input', pane, selector, effective_type, flush=True)
            assert action('setValue', selector, value=value)['value'] == value
        for method, selector, payload in [('check','#disabled',dict(checked=True)), ('check','#veto',dict(checked=True)),
                                         ('setValue','#number',dict(value='11')), ('setValue','#date',dict(value='not-a-date')),
                                         ('setValue','#readonly',dict(value='4')), ('setValue','#controlled',dict(value='8')),
                                         ('setValue','#month',dict(value='2026-10')), ('setValue','#week',dict(value='2026-W42'))]:
            assert app.cli('rpc', 'web.'+method, '--params', json.dumps(dict(pane=pane,selector=selector,**payload,**guards)), error=True)
        assert app.cli('web','check','--pane',pane,'--selector','#check','--checked','true',
                       '--expected-view-id',info['viewId'],'--expected-document-id',info['documentId'])['checked']
        assert app.cli('web','set-value','--pane',pane,'--selector','#number','--value','5',
                       '--expected-view-id',info['viewId'],'--expected-document-id',info['documentId'])['value']=='5'
        app.rpc('web.focus',pane=pane,selector='#text',expectedViewId=info['viewId'],expectedDocumentId='stale',error=-32050)
    def js(script): return app.rpc('debug.pluginEval', pane=plugin, script=script)
    assert js('workspace.web.get()')['ready']
    for method, params in [('focus',dict(selector='#text')),('key',dict(selector='#keys',key='arrowdown')),
                           ('check',dict(selector='#check',checked=False)),('setValue',dict(selector='#number',value='6'))]:
        # Real registered bridge, not direct test evaluation of DOM automation.
        assert js('workspace.web.get().then(p=>workspace.web.'+method+'({...'+json.dumps(params)+',expectedViewId:p.viewId,expectedDocumentId:p.documentId}))')
    assert js('workspace.warnings.close(true)')['suppressed']
    assert js('workspace.warnings.close(false)')['suppressed'] is False
    wid = app.rpc('window.list')['windows'][0]['windowId']
    assert js('workspace.windows.setFrame('+json.dumps(dict(windowId=wid,**desired))+')')['accepted']
    # Exercise the authenticated service adapter using its inherited CLI endpoint.
    info = app.rpc('web.get', pane=plugin)
    guards = dict(expectedViewId=info['viewId'], expectedDocumentId=info['documentId'])
    plan = [('web.focus', dict(pane=plugin, selector='#text', **guards)),
            ('web.key', dict(pane=plugin, selector='#keys', key='arrowdown', **guards)),
            ('web.check', dict(pane=plugin, selector='#check', checked=True, **guards)),
            ('web.setValue', dict(pane=plugin, selector='#number', value='9', **guards)),
            ('command.run', dict(id='warnings.type.set', suppressed=True)),
            ('command.run', dict(id='warnings.type.set', suppressed=False)),
            ('command.run', dict(id='window.frame.set', windowId=wid, **desired))]
    (app.root / 'service-plan.json').write_text(json.dumps(plan))
    worker = app.root / 'parity-service.py'
    worker.write_text('''import json,os,pathlib,subprocess,sys,time
root=pathlib.Path(sys.argv[1])
def call(method,params):
 r=subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc',method,'--params',json.dumps(params),'--json'],capture_output=True,text=True,timeout=15)
 if r.returncode: raise RuntimeError(r.stderr)
 return json.loads(r.stdout)
call('service.ready',{'version':1})
results=[call(method,params) for method,params in json.loads((root/'service-plan.json').read_text())]
temporary=root/'service-results.tmp';temporary.write_text(json.dumps(results));temporary.replace(root/'service-results.json')
while True: time.sleep(1)
''')
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='parity.service', title='Parity service', service=dict(
        executable=sys.executable, arguments=[str(worker), str(app.root)], readyTimeoutSeconds=15)), app.root))
    app.rpc('plugins.service.start', id='parity.service')
    try:
        eventually('service parity results', lambda: (app.root / 'service-results.json').exists(), timeout=30)
        results = json.loads((app.root / 'service-results.json').read_text())
        assert results[0]['focused'] and results[1]['dispatched'] and results[2]['checked']
        assert results[3]['value'] == '9' and results[-1]['accepted']
    finally:
        app.rpc('plugins.service.stop', id='parity.service')
    print('PASS first-pass window/web/warning API, CLI, registered-page and service parity')
