#!/usr/bin/env python3
"""Native invocation fences must settle a divider before availability or self-captured guards."""
import json
import socket
import sys
from api_fixture import AppFixture, eventually

for action in (sys.argv[1:] or ['split', 'close', 'tab-close']):
    assert action in ['split', 'close', 'tab-close']
    with AppFixture('divider-native-' + action) as app:
        app.cli('panes', 'split', '--pane', 'p1', '--right')
        app.rpc('debug.activate', tab='t1')
        eventually('owned native window active', lambda: app.rpc('debug.inspect')['applicationActive'])
        eventually('idle shells need no close prompt', lambda: all(not p['needsConfirmClose'] for p in app.rpc('debug.inspect')['panes']))
        cursor = app.rpc('events.head')['cursor']
        assert app.rpc('debug.dividerGesture', phase='begin', tab='t1', path=[])['active']
        app.rpc('debug.dividerGesture', phase='move', tab='t1', fraction=.6)
        # A single, short-deadline input detects nested error alerts; never replay it.
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(5)
            peer.connect(app.path)
            with peer.makefile('rb') as stream:
                peer.sendall(b'{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":1}}\n')
                assert 'error' not in json.loads(stream.readline())
                chord = {'split': 'cmd+d', 'close': 'cmd+w', 'tab-close': 'cmd+shift+w'}[action]
                params = dict(chord=chord, workspaceOnly=True, tab='t1')
                peer.sendall(json.dumps(dict(jsonrpc='2.0', id=2, method='debug.key', params=params)).encode() + b'\n')
                response = json.loads(stream.readline())
                assert 'error' not in response, response
        panes = app.rpc('panes.list')
        assert len(panes) == {'split': 3, 'close': 1, 'tab-close': 0}[action], {
            'panes': panes, 'workspace': app.rpc('workspace.get'),
            'events': app.rpc('events.poll', after=cursor, waitMilliseconds=0)['events'],
            'native': app.rpc('debug.inspect'), 'menus': app.rpc('debug.menuTree')}
        emitted = app.rpc('events.poll', after=cursor, topics=['host.layout.resized', 'host.pane.created', 'host.pane.closed'], waitMilliseconds=0)['events']
        resized = [e for e in emitted if e['topic'] == 'host.layout.resized']
        changed = [e for e in emitted if e['topic'] != 'host.layout.resized']
        assert len(resized) == 1 and len(changed) == (2 if action == 'tab-close' else 1), emitted
        assert len({e['payload']['operationId'] for e in changed}) == 1
        assert all(e['payload']['origin'] == {'kind': 'native'} for e in emitted)
        assert resized[0]['payload']['operationId'] != changed[0]['payload']['operationId']
        before = app.rpc('workspace.get')
        app.rpc('debug.dividerGesture', phase='end', tab='t1')
        assert app.rpc('workspace.get') == before
        print('PASS native divider settlement before ' + action + ' shortcut')
