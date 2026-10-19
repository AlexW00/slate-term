#!/usr/bin/env python3
"""One owned app: production cross-window transfer and trusted-client/lifecycle parity.
Native callbacks/menu are covered, not hardware AppKit drag-session delivery.
"""
import concurrent.futures
import json
import socket
import sys
import time
from api_fixture import AppFixture, ROOT, eventually
from plugin_package_fixture import package_fixture


def service_call(context, method, params, error=None):
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(20)
        peer.connect(context['SLATE_TERM_SOCKET'])
        with peer.makefile('rb') as stream:
            peer.sendall(json.dumps(dict(jsonrpc='2.0', id=1, method='hello', params=dict(protocolVersion=1))).encode() + b'\n')
            hello = json.loads(stream.readline())['result']['service']
            assert hello['generation'] == context['SLATE_TERM_SERVICE_GENERATION']
            peer.sendall(json.dumps(dict(jsonrpc='2.0', id=2, method=method, params=params)).encode() + b'\n')
            reply = json.loads(stream.readline())
            if error is not None:
                assert reply.get('error', {}).get('code') == error, reply
                return reply['error']
            assert 'error' not in reply, reply
            return reply['result']


with AppFixture('cross-window-pane-movement') as app:
    def inspect(p):
        return app.rpc('pane.inspect', pane=p)

    def command(id, **params):
        return app.rpc('command.run', id=id, **params)

    def window():
        result = command('window.new', focus='new')
        return app.rpc('tabs.list')[-1]['focusedPane']

    def guards(source):
        # Snapshot first: changes between the two reads conflict, never silently refresh/retry.
        snapshot = app.rpc('workspace.snapshot')
        info = inspect(source)
        return dict(pane=source, tab=info['tabId'], expectedInstanceId=snapshot['appInstanceId'],
                    expectedWorkspaceRevision=snapshot['workspaceRevision'], expectedLayoutRevision=info['layoutRevision'])

    def move(source, target, **extra):
        return command('pane.move', target=target, direction='right', **guards(source), **extra)

    def native(source, target, **params):
        return app.rpc('debug.paneMove', pane=source, target=target, x=.95, y=.5, **params)

    def close_tab(pane):
        command('tab.close', tab=inspect(pane)['tabId'], force=True)

    def terminal_native(pane):
        return next(p for p in app.rpc('debug.inspect')['panes'] if p['paneId'] == pane)

    assets = app.root / 'panels'
    assets.mkdir()
    (assets / 'index.html').write_text('<!doctype html><title>Move fixture</title><h1>Live plugin</h1><input value="unchanged">')
    for scope in ['pane', 'tab', 'global']:
        app.rpc('plugins.register', packagePath=package_fixture(dict(id='move.' + scope, title='Move ' + scope, scope=scope,
                    source=dict(kind='directory', path=str(assets))), app.root))
    controller = command('split.right', pane='p1')['paneId']
    command('pane.type', pane=controller, type='move.global', force=True)

    def js(pane, script):
        return app.rpc('debug.pluginEval', pane=pane, script=script)

    eventually('controller bridge', lambda: js(controller, 'typeof workspace') == 'object')
    descriptor = app.rpc('api.describe')['paneMovement']
    assert descriptor['sameAppCrossWindow'] and descriptor['crossTabGuard'] == 'expectedWorkspaceRevision'

    worker = app.root / 'move-service.py'
    context_path = app.root / 'service-context.json'
    worker.write_text('''import json,os,pathlib,subprocess,time
keys=['SLATE_TERM_SOCKET','SLATE_TERM_INSTANCE_ID','SLATE_TERM_SERVICE_PLUGIN_ID','SLATE_TERM_SERVICE_ID','SLATE_TERM_SERVICE_GENERATION']
pathlib.Path(os.environ['CONTEXT_PATH']).write_text(json.dumps({k:os.environ[k] for k in keys}))
subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc','service.ready','--params','{"version":1}'],check=True)
while True: time.sleep(1)
''')
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='move.service', title='Move service', service=dict(executable=sys.executable,
        arguments=[str(worker)], environment=dict(CONTEXT_PATH=str(context_path)), readyTimeoutSeconds=10)), app.root))
    app.rpc('plugins.service.start', id='move.service')
    eventually('service ready', lambda: app.rpc('plugins.service.status', id='move.service')['state'] == 'ready')
    context = json.loads(context_path.read_text())

    # Equivalent fixtures; each source is its window's only pane. No fabricated drag token.
    for client in ['socket', 'cli', 'page', 'service', 'native', 'menu']:
        source, target = window(), window()
        source_info, target_info = inspect(source), inspect(target)
        native_info = terminal_native(source)
        target_window = app.rpc('window.get', windowId=target_info['windowId'])
        command('pane.header.hide', pane=source)
        cursor = app.rpc('events.head')['cursor']
        params = dict(id='pane.move', target=target, direction='right', **guards(source))
        before = app.rpc('workspace.get')
        missing = dict(params)
        missing.pop('expectedWorkspaceRevision')
        app.rpc('command.run', error=-32602, **missing)
        if client == 'cli':
            assert app.cli('panes', 'move', '--pane', source, '--destination', target, '--right',
                '--expected-layout-revision', params['expectedLayoutRevision'], error=True)['code'] == -32602
        elif client == 'page':
            args = {k: v for k, v in missing.items() if k not in ['id', 'target', 'direction']}
            assert js(controller, 'await workspace.panes.move(' + json.dumps(target) + ',"right",' + json.dumps(args) + ').then(()=>null,e=>e.code)') == -32602
        elif client == 'service':
            service_call(context, 'command.run', missing, error=-32602)
        assert app.rpc('workspace.get') == before
        if client == 'socket':
            result = app.rpc('command.run', **params)
        elif client == 'cli':
            result = app.cli('panes', 'move', '--pane', source, '--destination', target, '--right',
                '--expected-layout-revision', params['expectedLayoutRevision'], '--expected-workspace-revision', params['expectedWorkspaceRevision'])
        elif client == 'page':
            args = {k: v for k, v in params.items() if k not in ['id', 'target', 'direction']}
            result = js(controller, 'await workspace.panes.move(' + json.dumps(target) + ',"right",' + json.dumps(args) + ')')
        elif client == 'service':
            result = service_call(context, 'command.run', params)
        else:
            command('pane.header.show', pane=source)
            if client == 'native':
                command('tab.focus', tab=source_info['tabId'])
                assert native(source, target, beginDrag=True)['began']
            assert native(source, target, **({'menu': True, 'direction': 'right'} if client == 'menu' else {'drop': True}))['accepted']
            result = None
        current = inspect(source)
        assert app.rpc('window.get', windowId=target_info['windowId'])['frame'] == target_window['frame']
        assert current['tabId'] == target_info['tabId'] and current['sessionId'] == source_info['sessionId']
        assert terminal_native(source)['surface'] == native_info['surface']
        inherited = dict(app.env, SLATE_TERM_PANE_ID=source, SLATE_TERM_TAB_ID=source_info['tabId'],
            SLATE_TERM_INSTANCE_ID=params['expectedInstanceId'], SLATE_TERM_SESSION_ID=source_info['sessionId'])
        assert app.cli('panes', 'inspect', env=inherited)['tabId'] == target_info['tabId']
        app.rpc('pane.inspect', pane=source, tab=source_info['tabId'], error=-32602)
        assert source_info['tabId'] not in [t['id'] for t in app.rpc('tabs.list')]
        if result:
            assert result['tabId'] == target_info['tabId'] and result['sourceTabId'] == source_info['tabId']
            assert result['sourceTabClosed'] and result['sourceLayoutRevision'] is None and not result['contentRecreated']
        events = app.rpc('events.poll', after=cursor, waitMilliseconds=0)['events']
        facts = [e for e in events if e['topic'] == 'host.pane.moved']
        assert len(facts) == 1 and facts[0].get('tab') is None, facts
        assert not [e for e in events if e['topic'] in ['host.pane.created', 'host.pane.closed']]
        assert facts[0]['payload']['origin']['kind'] == {'page': 'plugin', 'service': 'service', 'native': 'native', 'menu': 'native'}.get(client, 'administrative')
        close_tab(target)

    # Native active-drag admission must not borrow a newly selected sibling's geometry.
    # This drives real source admission/callback guards, not a hardware AppKit drag session.
    source = window()
    source_tab = inspect(source)['tabId']
    sibling_tab = command('tab.new', pane=source)['tabId']
    sibling = next(t['focusedPane'] for t in app.rpc('tabs.list') if t['id'] == sibling_tab)
    target = window()
    command('tab.focus', tab=source_tab)
    assert native(source, target, beginDrag=True)['began']
    command('tab.focus', tab=sibling_tab)
    before = app.rpc('workspace.get')
    assert not native(source, target, drop=True)['accepted']
    assert app.rpc('workspace.get') == before and inspect(source)['tabId'] == source_tab
    # Explicit API movement from an inactive tab remains supported and guarded.
    move(source, target)
    close_tab(target)
    close_tab(sibling)

    # Same native group, inactive source tab: retire only its membership, retaining group/window/frame.
    source = window()
    source_info = inspect(source)
    destination_tab = command('tab.new', pane=source, focus='new')['tabId']
    target = next(t['focusedPane'] for t in app.rpc('tabs.list') if t['id'] == destination_tab)
    target_info = inspect(target)
    target_window = app.rpc('window.get', windowId=target_info['windowId'])
    move(source, target)
    assert inspect(source)['groupId'] == source_info['groupId'] == target_info['groupId']
    assert app.rpc('window.get', windowId=target_info['windowId'])['frame'] == target_window['frame']
    close_tab(target)

    # Browser DOM/private store and web identities survive; all four insertion directions.
    source, target = window(), window()
    command('pane.type', pane=source, type='private-browser', force=True)
    eventually('browser ready', lambda: not app.rpc('browser.get', pane=source)['loading'])
    app.rpc('browser.eval', pane=source, script='window.moveSentinel="retained"')
    identity = app.rpc('web.get', pane=source)
    for direction in ['up', 'down', 'left', 'right']:
        command('pane.move', target=target, direction=direction, **guards(source))
        assert app.rpc('browser.eval', pane=source, script='window.moveSentinel') == 'retained'
        assert app.rpc('web.get', pane=source)['viewId'] == identity['viewId']
        assert app.rpc('web.get', pane=source)['documentId'] == identity['documentId']
    close_tab(target)

    # Plugin scope semantics, reused destination instance, bookkeeping and page state.
    for scope in ['pane', 'global', 'tab']:
        source, target = window(), window()
        for pane in [source, target]:
            command('pane.type', pane=pane, type='move.' + scope, force=True)
            eventually('plugin ready', lambda pane=pane: js(pane, 'typeof workspace') == 'object')
        old, destination = inspect(source), inspect(target)
        js(source, 'window.moveSentinel="retained"')
        js(source, 'await workspace.panelState.get().then(s=>workspace.panelState.patch([{op:"set",key:"owner",value:"source"}],{expectedPanelId:s.panelId,expectedStateRevision:s.revision}))')
        js(target, 'await workspace.panelState.get().then(s=>workspace.panelState.patch([{op:"set",key:"owner",value:"destination"}],{expectedPanelId:s.panelId,expectedStateRevision:s.revision}))')
        if scope == 'tab':
            native(source, target)
            app.rpc('debug.screenshot', path=str(ROOT / 'artifacts/cross-window-tab-plugin-preview.png'))
            app.rpc('debug.menuPreview', pane=source, move=True, path=str(ROOT / 'artifacts/cross-window-move-menu.png'))
            app.rpc('debug.menuPreview', pane=source, move=True, submenu='Tab ' + destination['tabId'],
                    path=str(ROOT / 'artifacts/cross-window-destination-panes.png'))
        # Publication rejection must clean provisional membership without touching source/destination.
        params = dict(id='pane.move', target=target, direction='right', **guards(source))
        before = app.rpc('workspace.get')
        app.rpc('debug.rejectNextWorkspacePublication')
        app.rpc('command.run', error=-32051, **params)
        assert app.rpc('workspace.get') == before
        assert inspect(source)['viewId'] == old['viewId']
        assert js(source, 'window.moveSentinel') == 'retained'
        if scope == 'pane':
            cursor = app.rpc('events.head')['cursor']
            query = dict(after=cursor, topics=['move.destination'], waitMilliseconds=20000)
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(js, source, 'await workspace.call("events.poll",' + json.dumps(query) + ')')
                eventually('inherited plugin poll suspended', lambda: app.rpc('events.head')['pendingPolls'] == 1)
                result = move(source, target)
                rebound = pending.result(timeout=5)
            assert rebound['events'] == []
            assert int(rebound['cursor'].rsplit(':', 1)[1]) >= int(cursor.rsplit(':', 1)[1])
            app.rpc('events.emit', topic='move.destination', tab=inspect(target)['tabId'])
            query.update(after=rebound['cursor'], waitMilliseconds=0)
            delivered = js(source, 'await workspace.call("events.poll",' + json.dumps(query) + ')')
            assert len(delivered['events']) == 1, delivered
        else:
            result = move(source, target)
        eventually('moved plugin ready', lambda: js(source, 'typeof workspace') == 'object')
        current = inspect(source)
        assert result['contentRecreated'] == (scope == 'tab')
        if scope == 'tab':
            assert current['viewId'] != old['viewId'] and current['pluginInstanceId'] == destination['pluginInstanceId']
            assert js(source, 'window.moveSentinel === undefined') is True
            assert js(source, 'await workspace.panelState.get().then(s=>s.values.owner)') == 'source'
            assert not [p for p in app.rpc('plugins.status', id='move.tab') if p['instanceId'] == old['pluginInstanceId']]
        else:
            assert current['viewId'] == old['viewId'] and current['pluginInstanceId'] == old['pluginInstanceId']
            assert js(source, 'window.moveSentinel') == 'retained'
            assert js(source, 'await workspace.context().then(x=>x.tabId)') == current['tabId']
            assert app.rpc('plugins.panelState.get', pane=source, tab=current['tabId'])['values']['owner'] == 'source'
        close_tab(target)

    # A new destination tab instance is provisional until commit, not just reused instances.
    source, target = window(), window()
    command('pane.type', pane=source, type='move.tab', force=True)
    old_instance = inspect(source)['pluginInstanceId']
    before_instances = app.rpc('plugins.status', id='move.tab')
    app.rpc('debug.rejectNextWorkspacePublication')
    command('pane.move', target=target, direction='right', error=-32051, **guards(source))
    assert app.rpc('plugins.status', id='move.tab') == before_instances
    result = move(source, target)
    assert result['contentRecreated'] and inspect(source)['pluginInstanceId'] != old_instance
    assert len(app.rpc('plugins.status', id='move.tab')) == 1
    close_tab(target)

    # A destination backend failure is readiness failure after an accepted placement, never rollback.
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='move.failed', title='Failed backend', scope='tab',
        source=dict(kind='url', url='http://127.0.0.1:0/'),
        process=dict(executable='/usr/bin/false', restartLimit=0, readyTimeoutSeconds=1)), app.root))
    # Repeated immediate exits/moves/close must not invalidate an HTTP session while
    # its async readiness task is still being created (previously an Obj-C crash).
    for _ in range(6):
        source, target = window(), window()
        command('pane.type', pane=source, type='move.failed', force=True)
        panel = app.rpc('plugins.panelState.get', pane=source)
        result = move(source, target)
        assert result['contentRecreated'] and inspect(source)['tabId'] == inspect(target)['tabId']
        assert app.rpc('plugins.panelState.get', pane=source) == panel
        eventually('destination backend failed', lambda: inspect(source)['state'] == 'failed')
        assert len(app.rpc('plugins.status', id='move.failed')) == 1
        close_tab(target)
    assert not app.rpc('plugins.status', id='move.failed')

    # A frozen terminal wait follows its live session, never the new tab's other terminal.
    source, target = window(), window()
    session = inspect(source)['sessionId']
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        waiting = pool.submit(app.rpc, 'terminal.wait', pane=source, sessionId=session,
                              contains='CROSS_WINDOW_WAIT_DONE', timeoutMilliseconds=10000)
        eventually('terminal wait suspended', lambda: app.rpc('debug.inspect')['pendingTerminalWaits'] == 1)
        move(source, target)
        app.rpc('terminal.send', pane=source, sessionId=session, text="printf 'CROSS_WINDOW_WAIT_DONE\\n'\r")
        assert waiting.result(timeout=12)['sessionId'] == session
    close_tab(target)

    # Zoom, stale guard and missing target: no partial source closure.
    source, target = window(), window()
    params = dict(id='pane.move', target=target, direction='right', **guards(source))
    command('pane.zoom', pane=target)
    app.rpc('command.run', error=-32050, **params)
    params = dict(id='pane.move', target=target, direction='right', **guards(source))
    app.rpc('command.run', error=-32051, **params)
    command('pane.zoom', pane=target)
    params = dict(id='pane.move', target='p999999', direction='right', **guards(source))
    app.rpc('command.run', error=-32051, **params)
    wrong_epoch = dict(params, expectedInstanceId='stale-app-epoch')
    app.rpc('command.run', error=-32050, **wrong_epoch)
    assert inspect(source)['tabId'] != inspect(target)['tabId']
    close_tab(source)
    close_tab(target)
    app.rpc('plugins.service.stop', id='move.service')
    print('PASS cross-window socket/CLI/page/service/native/menu parity; sole-pane closure, guards, identities, all edges, private browser DOM, plugin scope/reuse/storage and atomic publication rejection')
