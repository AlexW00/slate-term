#!/usr/bin/env python3
"""Owned fixture: shared tab names, guarded native sheets and title persistence."""
import json
import subprocess
import sys
from api_fixture import AppFixture, APP, ROOT, eventually

configuration = '[appearance]\ntheme = "light"\n[keybind]\n"cmd+ctrl+r" = "tab.rename"\n"cmd+ctrl+shift+r" = "tab.title.clear"\n'
with AppFixture('tab-titles', configuration=configuration) as app:
    def command(id, **params):
        return app.rpc('command.run', id=id, **params)

    def tab(id='t1'):
        return next(t for t in app.rpc('workspace.snapshot')['tabs'] if t['id'] == id)

    def native(id='t1'):
        projection = next(w for w in app.rpc('window.list')['windows'] if w['tabId'] == id)
        rendered = next(w for w in app.rpc('debug.inspect')['windows'] if w['tabId'] == id)
        assert rendered['title'] == projection['title'], (rendered, projection)
        return projection

    def facts(after):
        return app.rpc('events.poll', after=after, topics=['host.tab.title.changed', 'host.workspace.changed'], waitMilliseconds=0)['events']

    def editor(**params):
        return app.rpc('debug.tabRename', **params)

    def cancel():
        editor(finish='cancel')
        eventually('sheet cancellation', lambda: not editor()['editing'])

    def js(script):
        return app.rpc('debug.pluginEval', pane=panel, script=script)

    describe = app.rpc('api.describe')
    assert describe['tabTitle']['maximumCharacters'] == 100
    commands = {c['id']: c for c in app.rpc('command.list')}
    assert not commands['tab.rename']['contract']['requiresArguments']
    assert commands['tab.title.set']['contract']['requiresArguments']
    assert tab()['manualTitle'] is None and tab()['title'] == 'Slate Terminal'
    layout_revision = tab()['layoutRevision']
    cursor = app.rpc('events.head')['cursor']
    reply = app.cli('tabs', 'set-title', '--tab', 't1', '--title', '  Build 日本語  ')
    assert reply['manualTitle'] == reply['title'] == 'Build 日本語'
    assert reply['outcome'] == 'committed' and reply['workspacePersistence'] == 'saved'
    assert reply['layoutRevision'] == layout_revision
    changed = facts(cursor)
    assert [e['topic'] for e in changed] == ['host.tab.title.changed', 'host.workspace.changed'], changed
    assert all(e['tab'] == 't1' and e['payload']['origin']['kind'] == 'administrative' for e in changed)
    assert 'Build' not in json.dumps(changed)
    assert native()['title'] == 'Build 日本語'
    cursor = app.rpc('events.head')['cursor']
    assert app.cli('tabs', 'set-title', '--tab', 't1', '--title', 'Build 日本語')['outcome'] == 'unchanged'
    assert facts(cursor) == []
    for params in [dict(title=None), dict(title=3), dict(title='bad\nname'), dict(title='x' * 101), dict(title='ok', typo=True), dict(title='ok', tab='t999'), dict(title='ok', expectedWorkspaceRevision='stale'), dict(title='ok', expectedViewId='unsupported')]:
        app.rpc('command.run', id='tab.title.set', error=-32050 if 'expectedWorkspaceRevision' in params else -32602, **params)
    app.rpc('command.run', id='tab.title.set', error=-32602)
    assert tab()['title'] == 'Build 日本語'
    # Rejected journal preparation must leave model, native title and revision untouched.
    revision = app.rpc('workspace.snapshot')['workspaceRevision']
    cursor = app.rpc('events.head')['cursor']
    app.rpc('debug.rejectNextWorkspacePublication')
    app.rpc('command.run', id='tab.title.set', tab='t1', title='Must not commit', error=-32051)
    assert native()['title'] == tab()['title'] == 'Build 日本語'
    assert app.rpc('workspace.snapshot')['workspaceRevision'] == revision and not facts(cursor)
    # No-op save retry repairs earlier best-effort persistence failure.
    state = app.root / 'state'
    state.chmod(0o500)
    try:
        assert command('tab.title.set', tab='t1', title='Accepted live')['workspacePersistence'] == 'failed'
    finally:
        state.chmod(0o700)
    cursor = app.rpc('events.head')['cursor']
    recovered = command('tab.title.set', tab='t1', title='Accepted live')
    assert recovered['outcome'] == 'unchanged' and recovered['workspacePersistence'] == 'saved'
    assert not facts(cursor)
    second = app.cli('tabs', 'new', '--tab', 't1')['tabId']
    app.rpc('debug.activate', tab=second)
    eventually('foreground tab key', lambda: native(second)['key'])
    key_before = native(second)['windowId']
    sessions_before = {p['paneId']: p.get('sessionId') for p in app.rpc('workspace.snapshot')['panes']}
    command('tab.title.set', tab='t1', title='Background')
    assert app.rpc('workspace.get')['keyTabID'] == second and native(second)['key']
    assert native(second)['windowId'] == key_before and native()['title'] == 'Background'
    app.rpc('command.run', id='tab.rename', tab='t1', error=-32051)
    # Explicit tab suppresses an invalid inherited launching pane/session.
    stale = dict(app.env, SLATE_TERM_PANE_ID='p999', SLATE_TERM_SESSION_ID='stale')
    assert app.cli('tabs', 'set-title', '--title', 'stale', env=stale, error=True)['code'] == -32050
    missing = dict(app.env, SLATE_TERM_PANE_ID='p999')
    assert app.cli('tabs', 'set-title', '--title', 'stale', env=missing, error=True)['code'] == -32602
    assert app.cli('tabs', 'set-title', '--tab', 't1', '--title', 'Explicit', env=stale)['tabId'] == 't1'
    app.rpc('debug.activate', tab='t1')
    assert editor(tab='t1', probeSheet=True)['errorCode'] == -32051
    modal = app.rpc('debug.browserDataConfirmation', id='browser.clearData', answer='cancel', probeTabRename=True)
    assert modal['tabRenameError'] == -32051, modal
    # Exercise shortcut opening, actual native Return/Escape, invalid draft and conflict.
    app.rpc('debug.key', tab='t1', chord='cmd+ctrl+r')
    assert editor()['editing']
    first_editor = editor()['windowNumber']
    command('tab.rename', tab='t1')
    assert editor()['windowNumber'] == first_editor
    app.rpc('debug.key', menu=True, chord='cmd+ctrl+r')
    assert editor()['windowNumber'] == first_editor
    def menu_commands(items):
        return {entry['command']: entry for item in items for entry in [item, *menu_commands(item['children']).values()] if entry.get('command')}
    menu = menu_commands(app.rpc('debug.menuTree'))
    assert menu['tab.rename']['enabled'] and not menu['pane.close']['enabled']
    cursor = app.rpc('events.head')['cursor']
    editor(draft='')
    app.rpc('debug.key', tabRename=True, chord='j', dispatch=True)
    assert editor()['draft'] == 'j', editor()
    app.rpc('debug.key', tabRename=True, chord='return', dispatch=True)
    eventually('Return commits typed text', lambda: tab()['title'] == 'j')
    assert facts(cursor)[0]['payload']['origin']['kind'] == 'native'
    command('tab.rename', tab='t1')
    editor(draft='Native saved', finish='commit')
    command('tab.rename', tab='t1')
    editor(draft='Discard me')
    cursor = app.rpc('events.head')['cursor']
    app.rpc('debug.key', tabRename=True, chord='escape', dispatch=True)
    eventually('Escape cancels', lambda: not editor()['editing'])
    assert tab()['title'] == 'Native saved' and not facts(cursor)
    command('tab.rename', tab='t1')
    info = editor(draft='x' * 101, finish='commit')
    assert info['editing'] and info['error']
    editor(screenshot=str(ROOT / 'artifacts/tab-rename-error.png'))
    cancel()
    command('tab.rename', tab='t1')
    editor(draft='Stale draft')
    command('tab.title.set', tab='t1', title='Concurrent API')
    info = editor(finish='commit')
    assert info['editing'] and 'changed' in info['error'] and tab()['title'] == 'Concurrent API'
    cancel()
    for theme in ['light', 'dark']:
        app.config.write_text(configuration.replace('"light"', json.dumps(theme)))
        app.rpc('config.reload')
        command('tab.rename', tab='t1')
        editor(draft='Release 日本語', screenshot=str(ROOT / f'artifacts/tab-rename-{theme}.png'))
        cancel()
    command('tab.title.set', tab='t1', title='Release 日本語')
    app.rpc('debug.screenshot', path=str(ROOT / 'artifacts/tab-titles-dark.png'))
    cursor = app.rpc('events.head')['cursor']
    app.rpc('debug.key', tab='t1', chord='cmd+ctrl+shift+r')
    assert tab()['manualTitle'] is None and native()['title'] == 'Slate Terminal'
    assert facts(cursor)[0]['payload']['origin']['kind'] == 'native'
    command('tab.title.set', tab='t1', title='日本語 ' * 25)
    app.rpc('debug.screenshot', path=str(ROOT / 'artifacts/tab-titles-long.png'))
    # Picker captures a tab and offers reset; execute Rename via its real Return path.
    info = app.rpc('debug.commandPicker', show=True, query='Rename Tab')
    assert info['selected'] == 'tab.rename', info
    app.rpc('debug.key', picker=True, chord='return', dispatch=True)
    eventually('picker opens editor', lambda: editor()['editing'])
    cancel()
    command('tab.rename', tab='t1')
    command('tab.focus', tab=second)
    eventually('tab switch discards draft', lambda: not editor()['editing'])
    app.rpc('debug.activate', tab='t1')
    command('tab.rename', tab='t1')
    editor(draft='Retained through split')
    command('split.right', pane='p1')
    assert editor()['editing'] and editor()['draft'] == 'Retained through split'
    cancel()
    command('tab.rename', tab='t1')
    command('tab.reorder', tab='t1', index=1, expectedWorkspaceRevision=app.rpc('workspace.snapshot')['workspaceRevision'])
    eventually('reparent/reorder discards draft', lambda: not editor()['editing'])
    temporary_tab = command('window.new')['tabId']
    app.rpc('debug.activate', tab=temporary_tab)
    command('tab.title.set', tab=temporary_tab, title='Single tab')
    app.rpc('debug.screenshot', path=str(ROOT / 'artifacts/tab-titles-single.png'))
    command('tab.rename', tab=temporary_tab)
    command('tab.close', tab=temporary_tab, force=True)
    eventually('target close discards draft', lambda: not editor()['editing'])
    # Registered page and service use the same catalog, setters and attributed facts.
    assets = app.root / 'panel'
    assets.mkdir()
    (assets / 'index.html').write_text('<!doctype html><title>Tab names fixture</title>')
    app.rpc('plugins.register', manifest=dict(id='tabnames', title='Tab Names', source=dict(kind='directory', path=str(assets))))
    panel = next(t['focusedPane'] for t in app.rpc('tabs.list') if t['id'] == second)
    app.cli('panes', 'type', '--pane', panel, '--type', 'tabnames', '--force')
    eventually('page bridge ready', lambda: js('typeof workspace') == 'object')
    assert js("await workspace.call('api.describe')") == app.rpc('api.describe')
    cursor = app.rpc('events.head')['cursor']
    assert js("await workspace.tabs.setTitle('From page', {tab:'t1'})")['tabId'] == 't1'
    assert facts(cursor)[0]['payload']['origin']['kind'] == 'plugin'
    assert js("await workspace.tabs.clearTitle({tab:'t1'})")['manualTitle'] is None
    assert tab()['title'] == 'Slate Terminal'
    assert js("await workspace.tabs.setTitle('Bound page')")['tabId'] == second
    context = app.root / 'service-context.json'
    worker = app.root / 'service.py'
    worker.write_text('''import json,os,pathlib,subprocess,time
subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc','service.ready','--params','{"version":1}'],check=True)
keys=['SLATE_TERM_SOCKET','SLATE_TERM_INSTANCE_ID','SLATE_TERM_SERVICE_PLUGIN_ID','SLATE_TERM_SERVICE_ID','SLATE_TERM_SERVICE_GENERATION']
p=pathlib.Path(os.environ['TAB_CONTEXT']); t=p.with_suffix('.tmp'); t.write_text(json.dumps({k:os.environ[k] for k in keys})); t.replace(p)
while True: time.sleep(1)
''')
    app.rpc('plugins.register', manifest=dict(id='tabworker', title='Tab Worker', service=dict(executable=sys.executable, arguments=[str(worker)], environment={'TAB_CONTEXT': str(context)})))
    app.rpc('plugins.service.start', id='tabworker')
    eventually('service ready', context.exists)
    service_env = dict(app.env, **json.loads(context.read_text()))
    assert app.cli('rpc', 'api.describe', env=service_env) == app.rpc('api.describe')
    cursor = app.rpc('events.head')['cursor']
    assert app.cli('tabs', 'set-title', '--tab', 't1', '--title', 'Tab 2', env=service_env)['title'] == 'Tab 2'
    assert facts(cursor)[0]['payload']['origin']['kind'] == 'service'
    assert app.cli('tabs', 'clear-title', '--tab', 't1', env=service_env)['manualTitle'] is None
    maximum = 'a' + '\u0301' * 511 + 'b'
    command('tab.title.set', tab='t1', title=maximum)
    assert tab()['title'] == native()['title'] == maximum
    snapshot_page = app.rpc('workspace.snapshot', limit=1)
    window_page = app.rpc('window.list', limit=1)
    assert snapshot_page['nextCursor'] and window_page['nextCursor']
    command('tab.title.set', tab='t1', title='Tab 2')
    app.rpc('workspace.snapshot', cursor=snapshot_page['nextCursor'], limit=1, error=-32050)
    app.rpc('window.list', cursor=window_page['nextCursor'], limit=1, error=-32050)
    assert sessions_before['p1'] == app.rpc('pane.inspect', pane='p1')['sessionId']
    source = next(w['id'] for w in app.rpc('layouts.windows') if 't1' in w['tabs'])
    captured = app.rpc('layouts.capture', window=source, name='Named tabs', includeDirectories=False)
    assert any(t.get('manualTitle') == 'Tab 2' for t in captured['definition']['tabs'])
    opened = app.rpc('layouts.open', id=captured['definition']['id'])
    opened_tabs = [t for t in app.rpc('tabs.list') if t['id'] not in ['t1', second]]
    assert any(t.get('manualTitle') == 'Tab 2' for t in opened_tabs)
    assert opened['outcome'] == 'committed'
    # Renaming an inactive/minimized native window cannot reveal or select it.
    command('window.focus', windowId=native()['windowId'], activate=True)
    eventually('target selected before minimizing', lambda: native()['key'] and native()['selected'])
    editor(tab='t1', minimize=True)
    eventually('target minimized', lambda: native()['minimized'])
    # Existing window.focus reconciliation reveals minimized groups; do not use it between title assertions.
    eventually('other group key after minimizing', lambda: any(w['key'] and w['tabId'] != 't1' for w in app.rpc('window.list')['windows']))
    key_before = app.rpc('workspace.get')['keyTabID']
    command('tab.title.set', tab='t1', title='Minimized title')
    assert native()['minimized'] and app.rpc('workspace.get')['keyTabID'] == key_before
    app.rpc('command.run', id='tab.rename', tab='t1', error=-32051)
    preserved = (state / 'workspace.json').read_bytes()
    app.config.write_text(configuration + '[layout]\nrestore_workspace = false\n')
    app.rpc('config.reload')
    assert command('tab.title.set', tab='t1', title='Disabled save')['workspacePersistence'] == 'disabled'
    assert (state / 'workspace.json').read_bytes() == preserved
    app.config.write_text(configuration)
    app.rpc('config.reload')
    key_before = app.rpc('workspace.get')['keyTabID']
    command('tab.title.set', tab='t1', title='Persisted after restart')
    assert tab()['title'] == native()['title'] == 'Persisted after restart'
    assert app.rpc('workspace.get')['keyTabID'] == key_before
    app.rpc('plugins.service.stop', id='tabworker')
    app.process.terminate()
    app.process.wait(timeout=10)
    app.ready.unlink()
    app.process = subprocess.Popen([str(APP)], env=app.env, stdout=app.log, stderr=app.log, start_new_session=True)
    eventually('restored app ready', lambda: app.ready.exists() and app.process.poll() is None)
    app.path = app.ready.read_text().strip()
    app.env['SLATE_TERM_SOCKET'] = app.path
    assert tab()['manualTitle'] == native()['title'] == 'Persisted after restart'
    assert app.cli('tabs', 'clear-title', '--tab', 't1')['title'] == 'Slate Terminal'
    print('PASS tab titles: shared CLI/page/service set/clear, native shortcut/picker/Return/Escape, validation/conflicts, atomic facts, focus/session retention, no-op save recovery, recipe capture/open and restart')
