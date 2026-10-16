#!/usr/bin/env python3
"""First-pass production API/CLI/registered-page parity. Run only through verify-vm.py."""
import json
import os
import subprocess
from api_fixture import AppFixture, APP, eventually

assert subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip().startswith('VirtualMac'), 'Run this UI gate through scripts/verify-vm.py'

HTML = '''<!doctype html><title>Parity fixture</title>
<style>body{padding:20px}input,button{display:block;margin:6px}#keys{height:35px}</style>
<form id="form" onsubmit="event.preventDefault();document.querySelector('#result').textContent='submitted'">
<input id="text"><button id="submit">Submit</button></form>
<div id="keys" tabindex="0" role="button" onkeydown="if(event.key==='ArrowDown'){this.textContent='moved';event.preventDefault()}">keys</div>
<input id="check" type="checkbox"><input id="radio" type="radio" name="group">
<input id="other" type="radio" name="group" checked>
<input id="number" type="number" min="1" max="10" step="1" value="2">
<input id="date" type="date"><input id="time" type="time">
<input id="range" type="range" min="0" max="10" step="1" value="2">
<input id="disabled" type="checkbox" disabled><input id="readonly" type="number" readonly>
<input id="veto" type="checkbox" onclick="event.preventDefault()">
<input id="controlled" type="number" value="3" oninput="this.value='3'">
<p id="result">ready</p>'''

with AppFixture('api-parity') as app:
    describe = app.rpc('api.describe')
    assert {'web.focus', 'web.key', 'web.check', 'web.setValue'} <= set(describe['methods'])
    window = app.rpc('window.list')['windows'][0]
    wid = window['windowId']
    frame = window['visibleScreenFrame']
    desired = dict(x=frame['x']+20, y=frame['y']+20, width=min(900, frame['width']-40), height=min(700, frame['height']-40))
    session = app.rpc('pane.inspect', pane='p1')['sessionId']
    resized = app.cli('windows', 'frame', '--window-id', wid, *[arg for key, value in desired.items() for arg in ['--'+key, str(value)]])
    assert resized['accepted'] and all(abs(resized['frame'][key]-value)<2 for key, value in desired.items()), resized
    assert app.rpc('pane.inspect', pane='p1')['sessionId'] == session
    app.rpc('command.run', id='window.frame.set', windowId=wid, **dict(desired, width=-1), error=-32602)
    app.rpc('command.run', id='window.frame.set', windowId=wid, **dict(desired, x=1_000_000), error=-32602)
    app.rpc('command.run', id='window.minimize', windowId='closed', error=-32051)
    app.rpc('command.run', id='window.minimize', windowId=wid, expectedLayoutRevision='bad', error=-32602)
    app.cli('windows', 'minimize', '--window-id', wid)
    eventually('minimized', lambda: app.rpc('window.get', windowId=wid)['minimized'])
    app.cli('windows', 'restore', '--window-id', wid)
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
        app.rpc('command.run', id=f'warnings.{kind}.set', suppressed='true', error=-32602)
        app.rpc('command.run', id=f'warnings.{kind}.set', suppressed=False, expectedSourceRevision='unsupported', error=-32602)
        assert app.rpc('config.get')[field]['suppressed']
        assert json.loads((app.root / 'state' / f'suppress-{kind}-warning.json').read_text()) is True
    # Persisted suppression survives a real owned-app restart.
    app.process.terminate(); app.process.wait(timeout=10)
    app.ready.unlink()
    app.process = subprocess.Popen([str(APP)], env=app.env, stdout=app.log, stderr=app.log, start_new_session=True)
    eventually('restarted fixture', lambda: app.ready.exists() and app.process.poll() is None)
    app.path = app.ready.read_text().strip(); app.env['SLATE_TERM_SOCKET'] = app.path
    assert app.rpc('config.get')['closeWarning']['suppressed']
    assert app.rpc('config.get')['typeWarning']['suppressed']
    # Preference suppression never grants API destructive consent.
    app.rpc('terminal.send', pane='p1', text='sleep 30\r')
    eventually('running shell', lambda: 'sleep 30' in app.rpc('terminal.capture', pane='p1')['text'])
    app.rpc('command.run', id='pane.close', pane='p1', error=-32010)
    app.rpc('terminal.key', pane='p1', key='ctrl+c')
    for kind in ['close', 'type']:
        assert app.rpc('command.run', id=f'warnings.{kind}.reset')['suppressed'] is False

    assets = app.root / 'assets'; assets.mkdir()
    (assets / 'index.html').write_text(HTML)
    app.rpc('command.run', id='pane.type', pane='p1', type='private-browser', force=True)
    app.rpc('browser.navigate', pane='p1', url=str(assets / 'index.html'))
    plugin = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('plugins.register', manifest=dict(id='parity.fixture', title='Parity fixture', source=dict(kind='directory', path=str(assets))))
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
        action('key', '#keys', key='arrowdown')
        assert 'moved' in app.rpc('web.snapshot', pane=pane)['text']
        assert action('key', '#text', key='tab')['defaultAction'] == 'focus'
        assert action('check', '#check', checked=True)['checked']
        assert not action('check', '#check', checked=True)['performed']
        assert action('check', '#check', checked=False)['checked'] is False
        assert action('check', '#radio', checked=True)['checked']
        assert app.cli('rpc', 'web.check', '--params', json.dumps(dict(pane=pane, selector='#radio', checked=False, **guards)), error=True)
        for selector, value in [('#number','8'), ('#date','2026-10-16'), ('#time','12:30'), ('#range','7')]:
            assert action('setValue', selector, value=value)['value'] == value
        for method, selector, payload in [('check','#disabled',dict(checked=True)), ('check','#veto',dict(checked=True)),
                                         ('setValue','#number',dict(value='11')), ('setValue','#date',dict(value='not-a-date')),
                                         ('setValue','#readonly',dict(value='4')), ('setValue','#controlled',dict(value='8'))]:
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
    print('PASS first-pass window/web/warning API, CLI and registered-page parity')
