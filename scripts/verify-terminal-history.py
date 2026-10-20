#!/usr/bin/env python3
"""Owned VM app: retained history, active screen, native Find and trusted adapters."""
from plugin_package_fixture import package_fixture
import json
import stat
from api_fixture import ROOT, AppFixture, eventually

with AppFixture('terminal-history') as app:
    app.capture_contracts()
    # Let the startup report complete before resizing native chrome: the shell
    # reporter deliberately has a short deadline and fails closed on busy hosts.
    try:
        eventually('authenticated prompt', lambda: app.rpc('context.get')['terminal']['state'] == 'prompt')
    except AssertionError:
        print('SHELL_STARTUP_DIAGNOSTIC', app.rpc('context.get'), app.rpc('terminal.capture', pane='p1'), flush=True)
        raise
    app.rpc('command.run', id='welcome.read')
    session = app.rpc('pane.inspect', pane='p1')['sessionId']
    # The echoed command deliberately does not contain the complete search needle.
    app.rpc('terminal.run', pane='p1', command="printf 'HISTORY_%s\\n' ONLY; for i in {1..400}; do printf 'line-%04d 日本語\\n' $i; done; printf 'TAIL_%s\\n' READY")
    def history(**params):
        return app.rpc('terminal.history', pane='p1', **params)
    eventually('rendered retained output', lambda: 'TAIL_READY' in history()['text'])
    captured = app.rpc('terminal.capture', pane='p1')
    assert 'HISTORY_ONLY' not in captured['text'], 'Screen capture leaked scrollback'
    assert 'HISTORY_ONLY' in history()['text']
    assert history()['sessionId'] == session
    tail = history(maxLines=4)
    assert tail['truncated'] and tail['lineCount'] <= 4 and 'HISTORY_ONLY' not in tail['text']
    bounded = history(maxBytes=61)
    assert bounded['truncated'] and bounded['byteCount'] <= 61 and '\ufffd' not in bounded['text']
    assert app.cli('terminal', 'history', '--pane', 'p1', '--max-lines', '4') == tail
    app.rpc('terminal.history', pane='p1', maxBytes=0, error=-32602)
    app.rpc('terminal.history', pane='p1', maxLines=True, error=-32602)
    app.rpc('terminal.history', pane='p1', sessionId='stale', error=-32022)
    app.rpc('terminal.search', pane='p1', action='get', query='ignored', error=-32602)

    path = app.root / 'history.txt'
    exported = app.rpc('terminal.historyExport', pane='p1', path=str(path), maxLines=4)
    assert path.read_text() == tail['text']
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert exported['path'] == str(path) and exported['truncated']
    app.rpc('terminal.historyExport', pane='p1', path=str(path), error=-32020)
    assert path.read_text() == tail['text']
    link = app.root / 'export-link'
    link.symlink_to(path)
    app.rpc('terminal.historyExport', pane='p1', path=str(link), error=-32020)
    app.rpc('terminal.historyExport', pane='p1', path='relative.txt', error=-32602)

    def search(**params):
        return app.rpc('terminal.search', pane='p1', **params)
    search(action='set', query='HISTORY_ONLY')
    eventually('search reaches offscreen history', lambda: (search().get('total') or 0) >= 1)
    assert search()['active'] and search()['query'] == 'HISTORY_ONLY'
    total = search()['total']
    assert search(action='set', query='history_only')['total'] == total, 'Equivalent search lost its settled count'
    assert search(action='set', query='HISTORY_ONLY')['total'] == total
    app.rpc('command.run', id='terminal.find', pane='p1')
    def native():
        return next(p for p in app.rpc('debug.inspect')['panes'] if p['paneId'] == 'p1')
    eventually('native Find is visible and focused', lambda: native()['findVisible'] and native()['findFocused'])
    app.rpc('command.run', id='terminal.find.next', pane='p1')
    eventually('selected match', lambda: search()['selected'] is not None)
    assert search()['total'] == total, 'Reopening Find discarded settled results'
    other = app.rpc('command.run', id='split.right', pane='p1', focus='new')['paneId']
    app.rpc('debug.terminalFindFocus', pane='p1')
    eventually('editing Find selects its pane', lambda: app.rpc('context.get')['focusedPaneId'] == 'p1')
    revision = app.rpc('pane.inspect', pane='p1')['layoutRevision']
    app.rpc('command.run', id='pane.move', pane='p1', target=other, direction='down', expectedLayoutRevision=revision)
    eventually('Find focus survives reparenting', lambda: native()['findFocused'])
    app.rpc('debug.terminalFindFocus', pane='p1', input=True)
    assert native()['firstResponder']
    app.rpc('command.run', id='pane.focus', pane=other)
    revision = app.rpc('pane.inspect', pane='p1')['layoutRevision']
    app.rpc('command.run', id='pane.move', pane='p1', target=other, direction='right', focus='target', expectedLayoutRevision=revision)
    eventually('PTY focus survives inactive pane reparenting', lambda: native()['firstResponder'] and not native()['findFocused'])
    app.rpc('debug.terminalFindFocus', pane='p1')
    app.rpc('command.run', id='pane.close', pane=other, force=True)
    eventually('Find focus survives sibling close', lambda: native()['findFocused'])
    # Search scrolling must not change the active-screen capture contract.
    assert 'HISTORY_ONLY' not in app.rpc('terminal.capture', pane='p1')['text']
    app.rpc('debug.screenshot', path=str(ROOT / 'artifacts/terminal-history-find.png'))
    app.rpc('debug.windowGeometry', width=480, height=480)
    app.rpc('debug.screenshot', path=str(ROOT / 'artifacts/terminal-history-find-compact.png'))
    app.rpc('debug.windowGeometry', width=1000, height=700)
    app.rpc('command.run', id='terminal.find.end', pane='p1')
    assert not search()['active']
    eventually('Find closes and returns terminal focus', lambda: not native()['findVisible'] and native()['firstResponder'])
    search(action='set', query='')
    assert search()['active'] and search()['query'] == ''
    search(action='end')

    assets = app.root / 'history-panel'
    assets.mkdir()
    (assets / 'index.html').write_text('<!doctype html><title>History fixture</title>')
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='history.fixture', title='History fixture', source=dict(kind='directory', path=str(assets))), app.root))
    panel = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=panel, type='history.fixture', force=True)
    def js(script):
        return app.rpc('debug.pluginEval', pane=panel, script=script)
    eventually('plugin bridge', lambda: js('typeof workspace') == 'object')
    assert js('await workspace.terminal.history({pane:"p1",maxLines:4})') == history(maxLines=4)
    assert js('await workspace.terminal.search({pane:"p1",action:"set",query:"HISTORY_ONLY"})')['active']
    eventually('bridge search', lambda: (search()['total'] or 0) >= 1)
    assert app.cli('terminal', 'search', '--pane', 'p1', '--search-action', 'end')['active'] is False
    app.rpc('command.run', id='terminal.find', pane=panel, error=-32051)
    before = app.rpc('pane.inspect', pane='p1')['sessionId']
    app.rpc('command.run', id='pane.type', pane='p1', type='browser', force=True)
    app.rpc('command.run', id='pane.type', pane='p1', type='terminal', force=True)
    assert app.rpc('pane.inspect', pane='p1')['sessionId'] != before
    app.rpc('terminal.history', pane='p1', sessionId=before, error=-32022)
    assert not search()['active'] and 'HISTORY_ONLY' not in history()['text']
    eventually('replacement authenticated prompt', lambda: app.rpc('context.get', pane='p1')['terminal']['state'] == 'prompt')
    tab = app.rpc('pane.inspect', pane='p1')['tabId']
    app.rpc('command.run', id='tab.close', tab=tab, force=True)

print('PASS bounded history/export, active screen, engine Find, native commands, CLI/page parity, stale sessions')
