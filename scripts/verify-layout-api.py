#!/usr/bin/env python3
"""Production split/move/resize/title/tab/window adapters, atomic rejection and retained content."""
import json
import subprocess
import socket
import time
from api_fixture import AppFixture, CLI, ROOT, eventually
from plugin_package_fixture import package_fixture

with AppFixture('layout-api') as app:
    def pane(pane_id='p1'):
        return app.rpc('pane.inspect', pane=pane_id)

    def layout_revision(pane_id='p1'):
        return pane(pane_id)['layoutRevision']

    def workspace_revision():
        previous = None
        for _ in range(100):
            current = app.rpc('workspace.snapshot')['workspaceRevision']
            if current == previous:
                return current
            previous = current
            time.sleep(.04)
        raise AssertionError('Workspace geometry did not settle')

    session = pane()['sessionId']
    cursor = app.rpc('events.head')['cursor']
    preparations = app.rpc('debug.inspect')['terminalPreparationCount']
    split = app.cli('panes', 'split', '--pane', 'p1', '--right', '--type', 'browser', '--new-pane-fraction', '.25',
                    '--focus-policy', 'preserve', '--expected-layout-revision', layout_revision())
    assert split['paneId'] == 'p2'
    assert pane('p2')['type'] == 'browser' and 'sessionId' not in pane('p2')
    assert app.rpc('context.inspect', pane='p1')['focusedPaneId'] == 'p1'
    assert pane()['sessionId'] == session
    assert app.rpc('debug.inspect')['terminalPreparationCount'] == preparations, 'Browser split transiently prepared a terminal'
    events = app.rpc('events.poll', after=cursor, waitMilliseconds=0)['events']
    assert len([e for e in events if e['topic'] == 'host.pane.created' and e.get('pane') == 'p2']) == 1, events
    assert not [e for e in events if e['topic'] in ['host.pane.type.changed', 'host.context.changed'] and e.get('pane') == 'p2'], events
    root = app.cli('panes', 'split', '--pane', 'p1', '--up', '--root', '--type', 'browser', '--new-pane-fraction', '.2',
                   '--focus-policy', 'preserve', '--expected-layout-revision', layout_revision())
    assert root['paneId'] == 'p3'
    tree = app.rpc('layout.get', tab='t1')
    assert tree['axis'] == 'vertical' and tree['first']['pane'] == 'p3', tree
    assert abs(tree['fraction'] - .2) < .003, tree
    for params, error in [({'type': 'not-installed', 'newPaneFraction': .3}, -32602), ({'newPaneFraction': .001}, -32051)]:
        before = app.rpc('workspace.get')
        app.rpc('command.run', id='pane.split', pane='p1', direction='right', target='root', expectedLayoutRevision=layout_revision(), error=error, **params)
        assert app.rpc('workspace.get') == before
    app.rpc('command.run', id='pane.split', pane='p1', direction='right', error=-32602)
    def terminal_children():
        # The pinned macOS engine owns /usr/bin/login, which owns the zsh child.
        found = subprocess.run(['pgrep', '-P', str(app.process.pid), '-x', 'login'], capture_output=True, text=True)
        assert found.returncode in [0, 1], found.stderr
        return set(found.stdout.split())
    eventually('owned terminal child', lambda: bool(terminal_children()))
    children = terminal_children()
    before = app.rpc('workspace.get')
    app.rpc('debug.rejectNextTerminalPreparation')
    app.rpc('command.run', id='pane.split', pane='p1', direction='right', newPaneFraction=.25,
            expectedLayoutRevision=layout_revision(), error=-32051)
    assert app.rpc('workspace.get') == before and pane()['sessionId'] == session
    assert app.rpc('debug.inspect')['terminalPreparationCount'] == preparations + 1
    eventually('provisional terminal cleaned up', lambda: terminal_children() == children)
    stale = layout_revision()
    moved = app.cli('panes', 'move', '--pane', 'p2', '--destination', 'p1', '--down', '--expected-layout-revision', stale)
    assert moved['paneId'] == 'p2' and pane()['sessionId'] == session
    before = app.rpc('workspace.get')
    app.rpc('command.run', id='layout.resize', tab='t1', path=[], firstChildFraction=.4, expectedLayoutRevision=stale, error=-32050)
    assert app.rpc('workspace.get') == before
    app.cli('layout', 'resize', '--tab', 't1', '--path', '', '--first-child-fraction', '.35', '--expected-layout-revision', layout_revision())
    assert abs(app.rpc('layout.get', tab='t1')['fraction'] - .35) < .003
    app.rpc('command.run', id='pane.zoom', pane='p1')
    before = app.rpc('workspace.get')
    app.rpc('command.run', id='pane.move', pane='p2', target='p1', direction='left', expectedLayoutRevision=layout_revision(), error=-32051)
    assert app.rpc('workspace.get') == before
    app.rpc('command.run', id='pane.zoom', pane='p1')

    app.rpc('terminal.send', pane='p1', text='sleep 30\n')
    eventually('busy title target', lambda: pane().get('state') == 'running')
    app.cli('panes', 'set-title', '--pane', 'p1', '--title', '  owned build  ')
    assert pane()['manualTitle'] == 'owned build' and pane()['sessionId'] == session
    app.cli('panes', 'clear-title', '--pane', 'p1')
    assert pane()['manualTitle'] is None
    app.rpc('terminal.key', pane='p1', key='ctrl+c')

    t2 = app.cli('tabs', 'new', '--tab', 't1')['tabId']
    windows = app.cli('windows', 'list')['windows']
    window_ids = {w['tabId']: w['windowId'] for w in windows}
    first = app.cli('windows', 'list', '--limit', '1')
    second = app.cli('windows', 'list', '--limit', '1', '--cursor', first['nextCursor'])
    assert [first['windows'][0]['tabId'], second['windows'][0]['tabId']] == ['t1', t2]
    assert second['nextCursor'] is None and second['eventCursor'] == first['eventCursor']
    for limit in [0, -1, 65, True, '1']:
        app.rpc('window.list', limit=limit, error=-32602)
    app.rpc('window.list', cursor=42, error=-32602)
    app.rpc('window.list', cursor='not-a-cursor', error=-32050)
    app.rpc('window.list', pane='p1', error=-32602)
    app.rpc('window.get', windowId=window_ids['t1'], activate=True, error=-32602)
    other_cursor = app.rpc('workspace.snapshot', limit=1)['nextCursor']
    app.rpc('window.list', cursor=other_cursor, error=-32050)
    app.cli('tabs', 'reorder', '--tab', t2, '--index', '0', '--expected-workspace-revision', workspace_revision())
    assert app.rpc('debug.inspect')['nativeTabGroups'] == [[t2, 't1']]
    app.rpc('window.list', cursor=first['nextCursor'], error=-32050)
    detached = app.cli('tabs', 'detach', '--tab', t2, '--expected-workspace-revision', workspace_revision())
    group = detached['groupId']
    assert sorted(app.rpc('debug.inspect')['nativeTabGroups']) == [['t1'], [t2]]
    assert {w['tabId']: w['windowId'] for w in app.cli('windows', 'list')['windows']} == window_ids
    app.cli('tabs', 'move', '--tab', 't1', '--group', group, '--index', '0', '--expected-workspace-revision', workspace_revision())
    assert app.rpc('debug.inspect')['nativeTabGroups'] == [['t1', t2]]
    assert app.rpc('workspace.get')['groups'][0]['id'] == group
    assert pane()['sessionId'] == session
    app.cli('windows', 'focus', '--window-id', window_ids['t1'])
    assert app.rpc('workspace.get')['keyTabID'] == 't1'
    app.rpc('command.run', id='window.focus', windowId='missing-window', error=-32051)
    # Move the first tab into a differently sized destination while preserving its
    # selected tab, then reorder a three-tab group without rebuilding live contents.
    t3 = app.rpc('command.run', id='window.new')['tabId']
    app.rpc('debug.commandPicker', show=True, tab=t3)
    app.rpc('debug.commandPicker', sourceWidth=720, sourceHeight=700)
    app.rpc('debug.commandPicker', dismiss=True)
    workspace_revision()
    third = next(w for w in app.cli('windows', 'list')['windows'] if w['tabId'] == t3)
    destination_frame = third['frame']
    app.cli('panes', 'split', '--pane', 'p1', '--right', '--type', 'browser', '--focus-policy', 'preserve', '--expected-layout-revision', layout_revision())
    assert app.rpc('workspace.get')['keyTabID'] == t3
    background_context = app.rpc('context.inspect', pane='p1')
    assert background_context['focusedPaneId'] == 'p1' and background_context['activeTerminalPaneId'] == 'p1'
    app.cli('tabs', 'move', '--tab', 't1', '--group', third['groupId'], '--index', '0', '--expected-workspace-revision', workspace_revision())
    assert app.rpc('workspace.get')['keyTabID'] == t3
    current_third = app.cli('windows', 'get', '--window-id', third['windowId'])
    assert current_third['selected'] and current_third['frame'] == destination_frame, (current_third, destination_frame)
    before = app.rpc('workspace.get')
    app.rpc('command.run', id='pane.split', pane='p1', direction='right', type='browser', newPaneFraction=.2,
            expectedLayoutRevision=layout_revision(), error=-32051)
    assert app.rpc('workspace.get') == before, 'Background admission uses the destination presentation geometry'
    app.rpc('command.run', id='layout.resize', pane='p1', path=['second', 'first'], firstChildFraction=.9,
            expectedLayoutRevision=layout_revision(), error=-32051)
    assert app.rpc('workspace.get') == before
    assert not pane()['visible'], 'An unselected native tab is not a visible pane'
    app.rpc('command.run', id='layout.resize', pane='p1', path=['second', 'first'], firstChildFraction=.6,
            expectedLayoutRevision=layout_revision())
    assert app.rpc('workspace.get')['keyTabID'] == t3
    assert app.cli('windows', 'get', '--window-id', third['windowId'])['frame'] == destination_frame
    app.cli('tabs', 'move', '--tab', 't1', '--group', group, '--index', '0', '--expected-workspace-revision', workspace_revision())
    assert app.rpc('workspace.get')['keyTabID'] == t3
    assert app.cli('windows', 'get', '--window-id', window_ids[t2])['selected']
    app.cli('tabs', 'move', '--tab', t3, '--group', group, '--index', '1', '--expected-workspace-revision', workspace_revision())
    assert app.rpc('debug.inspect')['nativeTabGroups'] == [['t1', t3, t2]]
    app.cli('tabs', 'reorder', '--tab', t2, '--index', '0', '--expected-workspace-revision', workspace_revision())
    assert app.rpc('debug.inspect')['nativeTabGroups'] == [[t2, 't1', t3]]
    assert {w['tabId']: w['windowId'] for w in app.cli('windows', 'list')['windows'] if w['tabId'] != t3} == window_ids
    app.rpc('command.run', id='tab.close', tab=t3, force=True)
    app.cli('windows', 'focus', '--window-id', window_ids['t1'])

    directory = app.root / 'panel'
    directory.mkdir()
    (directory / 'index.html').write_text('<!doctype html><title>Layout fixture</title>')
    app.rpc('plugins.register', packagePath=package_fixture({'id': 'fixture', 'title': 'Fixture', 'source': {'kind': 'directory', 'path': str(directory)}}, app.root))
    app.rpc('command.run', id='pane.type', pane='p3', type='fixture', force=True)

    def evaluate(script):
        try:
            return app.rpc('debug.pluginEval', pane='p3', script=script)
        except TimeoutError:
            # Diagnose the owned app before fixture cleanup; never retry the mutation.
            try:
                with socket.socket(socket.AF_UNIX) as probe:
                    probe.settimeout(2)
                    probe.connect(app.path)
                    with probe.makefile('rb') as stream:
                        probe.sendall(b'{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":1}}\n')
                        stream.readline(2**20)
                        probe.sendall(b'{"jsonrpc":"2.0","id":2,"method":"debug.inspect","params":{}}\n')
                        (ROOT / 'artifacts/layout-timeout-inspect.json').write_bytes(stream.readline(2**20))
            except Exception as diagnostic:
                print('Timeout state probe:', repr(diagnostic), flush=True)
            try:
                subprocess.run(['/usr/bin/sample', str(app.process.pid), '1', '-file', str(ROOT / 'artifacts/layout-timeout.sample')],
                               capture_output=True, text=True, timeout=8)
            except Exception as diagnostic:
                print('Timeout sample:', repr(diagnostic), flush=True)
            raise

    eventually('layout plugin bridge', lambda: evaluate('typeof workspace') == 'object')
    own = evaluate('await workspace.self()')['caller']
    evaluate('window.__layoutNonce = "unchanged"')
    evaluate('await workspace.panes.setTitle("plugin user title")')
    assert pane('p3')['manualTitle'] == 'plugin user title'
    evaluate('await workspace.panes.clearTitle()')
    assert pane('p3')['manualTitle'] is None
    evaluate('await workspace.command("window.focus",{windowId:' + json.dumps(pane('p3')['windowId']) + '})')
    assert evaluate('await workspace.command("tab.detachCurrent",{tab:"t999"}).then(()=>null,e=>e.code)') == -32602
    assert 'tab.detachCurrent' in [c['id'] for c in evaluate('await workspace.api()')['commands']]
    revision = layout_revision('p3')
    created = evaluate('await workspace.panes.split({direction:"right",type:"browser",focus:"preserve",expectedLayoutRevision:' + json.dumps(revision) + '})')['paneId']
    assert pane(created)['type'] == 'browser'
    revision = layout_revision('p3')
    evaluate('await workspace.panes.move("p3","down",{pane:' + json.dumps(created) + ',expectedLayoutRevision:' + json.dumps(revision) + '})')
    revision = layout_revision('p3')
    evaluate('await workspace.layout.resize(["first"],0.55,{expectedLayoutRevision:' + json.dumps(revision) + '})')
    revision = workspace_revision()
    evaluate('await workspace.tabs.detach({expectedWorkspaceRevision:' + json.dumps(revision) + '})')
    revision = workspace_revision()
    evaluate('await workspace.tabs.move(' + json.dumps(group) + ',{index:1,expectedWorkspaceRevision:' + json.dumps(revision) + '})')
    revision = workspace_revision()
    evaluate('await workspace.tabs.reorder(0,{expectedWorkspaceRevision:' + json.dumps(revision) + '})')
    assert app.rpc('debug.inspect')['nativeTabGroups'] == [['t1', t2]]
    assert evaluate('await workspace.self()')['caller']['viewId'] == own['viewId']
    assert evaluate('window.__layoutNonce') == 'unchanged'
    assert pane()['sessionId'] == session
    app.rpc('command.run', id='tab.close', tab=t2, force=True)
    workspace_revision()
    app.rpc('command.run', id='window.focus', windowId=window_ids[t2], error=-32051)
    assert app.rpc('workspace.get')['keyTabID'] == 't1'
    assert pane()['sessionId'] == session
    for attempt in range(8):
        before = app.rpc('workspace.get')
        result = subprocess.run([str(CLI), 'command', 'run', 'split.right', '--pane', 'p1', '--json'],
                                env=app.env, text=True, capture_output=True, timeout=35)
        if result.returncode:
            assert not result.stdout and json.loads(result.stderr)['error']['code'] == -32051, result
            assert app.rpc('workspace.get') == before
            break
        assert json.loads(result.stdout)['paneId'] != 'p1'
    else:
        raise AssertionError('Legacy splits must stop before violating native minimum geometry')
    app.rpc('command.run', id='pane.focus', pane='p1')
    app.rpc('debug.activate')
    menu = next(item for item in app.rpc('debug.menuTree') if item['title'] == 'Workspace')
    split_menu = next(item for item in menu['children'] if item['title'] == 'Split Pane')
    assert not next(item for item in split_menu['children'] if item['command'] == 'split.right')['enabled']
    before = app.rpc('workspace.get')
    app.rpc('debug.key', chord='cmd+d', dispatch=True)
    assert app.rpc('workspace.get') == before, 'Unavailable split shortcut must not mutate the workspace'
    picker = app.rpc('debug.commandPicker', show=True, pane='p1', query='split right')
    assert not any(item['id'] == 'split.right' for item in picker['results']), picker
    app.rpc('debug.commandPicker', dismiss=True)
print('Atomic split/type/fractions, geometry/conflict guards, busy titles, native tab parity and stable windows/views passed')
