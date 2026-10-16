#!/usr/bin/env python3
"""Per-pane chrome: shared production dispatch, retained content, recipes and restore.

Only owned fixture windows/files/processes; debug calls observe native presentation or
simulate user input. All model changes go through production commands/layout APIs.
"""
import json
import os
import subprocess
import sys
import time
from api_fixture import APP, AppFixture, ROOT, eventually

ARTIFACTS = ROOT / 'artifacts'
ARTIFACTS.mkdir(exist_ok=True)
configuration = '[appearance]\ntheme = "light"\n[keybind]\n"cmd+ctrl+shift+h" = "pane.header.show"\n'
with AppFixture('pane-headers', configuration) as app:
    def command(id, **params):
        return app.rpc('command.run', id=id, **params)

    def inspect(pane='p1'):
        return app.rpc('pane.inspect', pane=pane)

    def native(pane='p1'):
        return next(p for p in app.rpc('debug.inspect')['panes'] if p['paneId'] == pane)

    def events(cursor):
        return app.rpc('events.poll', after=cursor, topics=['host.pane.*'], waitMilliseconds=0)['events']

    def screenshot(name, **params):
        time.sleep(.4)  # Capture settled rendering, not proof of operation success.
        app.rpc('debug.screenshot', path=str(ARTIFACTS / f'pane-headers-{name}.png'), **params)

    # The gate requires an authenticated idle shell. Establish that prerequisite
    # before native activation/plugin preparation can occupy the main queue.
    eventually('initial shell prompt', lambda: inspect()['state'] == 'prompt')
    app.rpc('debug.activate', tab='t1')
    command('pane.title.set', pane='p1', title='Build')
    panel = command('split.right', pane='p1')['paneId']
    assets = app.root / 'panel'
    assets.mkdir()
    (assets / 'index.html').write_text('<!doctype html><title>Preview</title><style>body{font:16px system-ui;padding:24px}</style><h1>Preview</h1><p>Retained pane content</p><input value="Draft stays here">')
    app.rpc('plugins.register', manifest=dict(id='headers.fixture', title='Header Fixture', source=dict(kind='directory', path=str(assets))))
    command('pane.type', pane=panel, type='headers.fixture', force=True)

    def js(script):
        return app.rpc('debug.pluginEval', pane=panel, script=script)

    eventually('registered page ready', lambda: js('typeof workspace') == 'object')
    document = app.rpc('web.get', pane=panel)
    command('pane.focus', pane='p1')
    before = native()
    snapshot = app.rpc('workspace.get')
    revision = inspect()['layoutRevision']
    cursor = app.rpc('events.head')['cursor']
    result = app.cli('panes', 'hide-header', '--pane', 'p1')
    assert result['headerVisible'] is False and result['outcome'] == 'committed', result
    after = native()
    assert after['surface'] == before['surface'] and inspect()['sessionId'], after
    assert after['firstResponder'] == before['firstResponder'] and after['terminalFocus'] == before['terminalFocus'], (before, after)
    assert abs(after['height'] - before['height'] - 28) < .5, (before, after)
    assert after['header']['height'] == 0 and not after['header']['closeVisible'], after
    assert app.rpc('workspace.get')['tabs'] == snapshot['tabs']
    assert inspect()['layoutRevision'] == revision and not inspect()['headerVisible']
    assert next(p for p in app.rpc('panes.list') if p['id'] == 'p1')['headerVisible'] is False
    assert app.rpc('workspace.snapshot', scope='pane', pane='p1')['panes'][0]['headerVisible'] is False
    facts = events(cursor)
    assert len(facts) == 1 and facts[0]['topic'] == 'host.pane.header.changed', facts
    assert facts[0]['payload']['headerVisible'] is False and facts[0]['payload']['origin']['kind'] == 'administrative', facts
    cursor = app.rpc('events.head')['cursor']
    again = command('pane.header.hide', pane='p1')
    assert again['outcome'] == 'unchanged' and again['workspaceRevision'] == result['workspaceRevision'] and events(cursor) == [], again
    # Recovery is an actual bound native action, not an API-only rescue.
    app.rpc('debug.key', chord='cmd+ctrl+shift+h', tab='t1')
    assert inspect()['headerVisible']
    assert events(cursor)[0]['payload']['origin']['kind'] == 'native'
    menu = next(m for m in app.rpc('debug.menuTree') if m['title'] == 'Workspace')
    assert any(m.get('command') == 'pane.header.show' for m in menu['children'])
    command('pane.rename', pane='p1')
    app.rpc('debug.paneHeader', pane='p1', draft='Do not save')
    cursor = app.rpc('events.head')['cursor']
    command('pane.header.hide', pane='p1')
    assert not native()['header']['editing'] and inspect()['manualTitle'] == 'Build'
    assert all(e['topic'] != 'host.pane.title.changed' for e in events(cursor))
    assert native()['firstResponder'] and native()['terminalFocus'], native()
    app.rpc('terminal.wait', pane='p1', timeoutMilliseconds=5000)
    for _ in range(5):
        app.rpc('debug.key', chord='j', tab='t1', dispatch=True)
    eventually('keyboard input after cancelled rename', lambda: 'jjjjj' in app.rpc('terminal.capture', pane='p1')['text'])
    app.rpc('terminal.key', pane='p1', key='ctrl+u')
    app.rpc('command.run', id='pane.rename', pane='p1', error=-32602)
    command('pane.title.set', pane='p1', title='Build output')
    # Publication rejection must leave both live model and chrome unchanged.
    app.rpc('debug.rejectNextWorkspacePublication')
    app.rpc('command.run', id='pane.header.show', pane='p1', error=-32051)
    assert not inspect()['headerVisible'] and native()['header']['height'] == 0
    for guards, error in [
        ({'pane': 'p999'}, -32602),
        ({'pane': 'p1', 'tab': 't999'}, -32602),
        ({'pane': 'p1', 'expectedInstanceId': 'stale'}, -32050),
        ({'pane': 'p1', 'expectedWorkspaceRevision': 'stale'}, -32050),
        ({'pane': 'p1', 'expectedLayoutRevision': 'stale'}, -32050),
        ({'pane': 'p1', 'expectedAnchorSessionId': 'stale'}, -32050),
        ({'pane': 'p1', 'expectedViewId': 'unsupported'}, -32602),
        ({'pane': 'p1', 'headerVisible': 'yes'}, -32602)
    ]:
        app.rpc('command.run', id='pane.header.show', error=error, **guards)
    assert not inspect()['headerVisible']
    # CLI inherited target cannot fall back to focus when stale.
    stale = dict(app.env, SLATE_TERM_PANE_ID='p999')
    assert app.cli('panes', 'show-header', env=stale, error=True)['code'] == -32602
    command('pane.header.show', pane='p1')
    assert app.cli('panes', 'toggle-header', '--pane', 'p1')['headerVisible'] is False
    assert app.cli('panes', 'show-header', '--pane', 'p1')['headerVisible'] is True
    # Service generation identity and bridge binding use the same public dispatch.
    context_file = app.root / 'service-context.json'
    worker = app.root / 'service.py'
    worker.write_text('''import json,os,pathlib,subprocess,time
subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc','service.ready','--params','{"version":1}'],check=True)
keys=['SLATE_TERM_SOCKET','SLATE_TERM_INSTANCE_ID','SLATE_TERM_SERVICE_PLUGIN_ID','SLATE_TERM_SERVICE_ID','SLATE_TERM_SERVICE_GENERATION']
p=pathlib.Path(os.environ['HEADER_CONTEXT']); t=p.with_suffix('.tmp'); t.write_text(json.dumps({k:os.environ[k] for k in keys})); t.replace(p)
while True: time.sleep(1)
''')
    app.rpc('plugins.register', manifest=dict(id='headerworker', title='Header Worker', service=dict(executable=sys.executable, arguments=[str(worker)], environment={'HEADER_CONTEXT': str(context_file)})))
    app.rpc('plugins.service.start', id='headerworker')
    eventually('service ready', context_file.exists)
    service_env = dict(app.env, **json.loads(context_file.read_text()))
    describe = app.rpc('api.describe')
    assert describe == js("await workspace.call('api.describe')")
    assert app.cli('rpc', 'api.describe', env=service_env) == describe
    assert describe['paneHeader']['stateField'] == 'headerVisible'
    for helper, action in [('hideHeader', 'hide'), ('showHeader', 'show'), ('toggleHeader', 'toggle')]:
        cursor = app.rpc('events.head')['cursor']
        reply = js(f"await workspace.panes.{helper}()")  # Bound panel, not focused terminal.
        assert reply['paneId'] == panel and reply['headerVisible'] == (action == 'show'), reply
        assert events(cursor)[0]['payload']['origin']['kind'] == 'plugin'
    assert app.rpc('web.get', pane=panel)['documentId'] == document['documentId']
    assert app.rpc('web.get', pane=panel)['viewId'] == document['viewId']
    cursor = app.rpc('events.head')['cursor']
    assert app.cli('panes', 'show-header', '--pane', panel, env=service_env)['headerVisible']
    assert events(cursor)[0]['payload']['origin']['kind'] == 'service'
    # Explicit bridge targets, including cross-tab targets, do not inherit sibling guards.
    other_tab = command('tab.new')['tabId']
    other_pane = next(t['focusedPane'] for t in app.rpc('workspace.get')['tabs'] if t['id'] == other_tab)
    target = dict(pane=other_pane, expectedLayoutRevision=inspect(other_pane)['layoutRevision'])
    reply = js(f"await workspace.panes.hideHeader({json.dumps(target)})")
    assert reply['paneId'] == other_pane and not inspect(other_pane)['headerVisible']
    assert inspect(panel)['headerVisible'] and app.rpc('workspace.get')['keyTabID'] == other_tab
    command('tab.close', tab=other_tab, force=True)
    assert js("await workspace.panes.hideHeader({pane:'p1'})")['paneId'] == 'p1'
    assert inspect(panel)['headerVisible'] and not inspect()['headerVisible']
    screenshot('mixed-light')
    app.config.write_text(configuration.replace('"light"', '"dark"'))
    app.rpc('config.reload')
    screenshot('mixed-dark')
    # Hidden state survives zoom and native moves, and replacement creates hidden chrome.
    command('pane.zoom', pane=panel)
    js("await workspace.panes.showHeader({pane:'p1'})")
    js("await workspace.panes.hideHeader({pane:'p1'})")
    command('pane.zoom', pane=panel)
    topology = app.rpc('layout.get', pane='p1')
    command('pane.move', pane='p1', target=panel, direction='down', expectedLayoutRevision=inspect()['layoutRevision'])
    assert app.rpc('layout.get', pane='p1') != topology
    assert not inspect()['headerVisible']
    command('pane.type', pane='p1', type='browser', force=True)
    assert not inspect()['headerVisible'] and native()['header']['height'] == 0
    command('pane.type', pane='p1', type='terminal', force=True)
    # Capture/editor/save/open all transport slot chrome independently of configuration.
    source = next(w for w in app.rpc('layouts.windows') if w['groupId'] == inspect()['groupId'])['id']
    captured = app.rpc('layouts.capture', window=source, name='Pane bars')
    def captured_pane(definition):
        return next(p for p in definition['tabs'][0]['panes'] if p['id'] == 'p1')
    assert captured_pane(captured['definition'])['headerVisible'] is False
    app.rpc('command.run', id='layouts.edit')
    editor = app.rpc('debug.savedLayouts', file=captured['file'], pane='p1', width=1060, height=620)
    assert captured_pane(editor['definition'])['headerVisible'] is False
    screenshot('template-dark', layouts=True)
    editor = app.rpc('debug.savedLayouts', headerVisible=True, save=True)
    assert not editor['dirty'] and captured_pane(app.rpc('layouts.get', id=captured['definition']['id'])['definition'])['headerVisible']
    editor = app.rpc('debug.savedLayouts', headerVisible=False, save=True)
    opened = app.rpc('layouts.open', id=captured['definition']['id'])
    hidden_panes = [p for p in opened['paneIds'] if not inspect(p)['headerVisible']]
    assert len(hidden_panes) == 1 and inspect(hidden_panes[0])['type'] == 'terminal'
    assert native(hidden_panes[0])['header']['height'] == 0
    # Background tabs must update without selecting/activating their window.
    key_tab = app.rpc('workspace.get')['keyTabID']
    key_window = next(w['windowId'] for w in app.rpc('window.list')['windows'] if w['key'])
    command('pane.header.show', pane='p1')
    assert app.rpc('workspace.get')['keyTabID'] == key_tab
    assert next(w['windowId'] for w in app.rpc('window.list')['windows'] if w['key']) == key_window
    command('pane.header.hide', pane='p1')
    app.rpc('plugins.service.stop', id='headerworker')
    # Restart the same owned fixture, using only its temporary configuration/state.
    app.process.terminate(); app.process.wait(timeout=10)
    app.ready.unlink()
    app.process = subprocess.Popen([str(APP)], env=app.env, stdout=app.log, stderr=app.log, start_new_session=True)
    eventually('restored fixture ready', lambda: app.ready.exists() and app.process.poll() is None)
    app.path = app.ready.read_text().strip(); app.env['SLATE_TERM_SOCKET'] = app.path
    assert not inspect()['headerVisible']
    assert native()['header']['height'] == 0
    assert app.cli('panes', 'show-header', '--pane', 'p1')['headerVisible']
    print('PASS pane bars: CLI/native/page/service parity, guards/no-ops/events, retained content/focus/height, rename cancellation, zoom/move/type retention, template edit/capture/open and restart recovery')
