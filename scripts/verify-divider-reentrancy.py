#!/usr/bin/env python3
"""One-shot owned callbacks exercise normalization's editor and admission barriers."""
import json
import socket
from api_fixture import AppFixture, eventually

for oversized in [False, True]:
    with AppFixture('divider-reentrancy-' + str(oversized).lower()) as app:
        def bounded(method, **params):
            # Never retry a timed-out mutation; a nested modal must fail this gate.
            with socket.socket(socket.AF_UNIX) as peer:
                peer.settimeout(5)
                peer.connect(app.path)
                with peer.makefile('rb') as stream:
                    peer.sendall(b'{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":1}}\n')
                    assert 'error' not in json.loads(stream.readline())
                    peer.sendall(json.dumps(dict(jsonrpc='2.0', id=2, method=method, params=params)).encode() + b'\n')
                    response = json.loads(stream.readline())
                    assert 'error' not in response, response
                    return response['result']

        app.cli('panes', 'split', '--pane', 'p1', '--right')
        revision = app.rpc('pane.inspect', pane='p1')['layoutRevision']
        app.cli('panes', 'split', '--pane', 'p1', '--right', '--new-pane-fraction', '.75', '--expected-layout-revision', revision)
        app.rpc('command.run', id='layout.resize', tab='t1', path=[], firstChildFraction=.7,
                expectedLayoutRevision=app.rpc('pane.inspect', pane='p1')['layoutRevision'])
        app.rpc('debug.activate', tab='t1')
        eventually('owned editor window active', lambda: app.rpc('debug.inspect')['applicationActive'])
        title = 'x' * 4097 if oversized else 'native completion after normalization'
        app.rpc('debug.paneHeader', pane='p2', beginRename=True, draft=title)
        cursor = app.rpc('events.head')['cursor']
        app.rpc('debug.nativeLayoutProbe', pane='p2', arm=True)
        bounded('debug.windowGeometry', tab='t1', width=440, height=650)
        probe = bounded('debug.nativeLayoutProbe')
        assert probe['geometryState'] == 'unavailable' and probe['geometryWasWithheld'] and probe['inFlightGeometryWithheld'], probe
        assert probe['reentrantErrorCode'] == -32050, probe
        assert not app.rpc('debug.paneHeader', pane='p2')['editing']
        info = app.rpc('pane.inspect', pane='p2')
        assert info['manualTitle'] == (None if oversized else title), info
        emitted = app.rpc('events.poll', after=cursor, topics=['host.layout.resized', 'host.pane.title.changed'], waitMilliseconds=0)['events']
        resized = [e for e in emitted if e['topic'] == 'host.layout.resized']
        renamed = [e for e in emitted if e['topic'] == 'host.pane.title.changed']
        assert resized and len({e['payload']['operationId'] for e in resized}) == 1, emitted
        assert len(renamed) == (0 if oversized else 1), emitted
        if renamed:
            assert renamed[0]['payload']['operationId'] != resized[0]['payload']['operationId']
            assert renamed[0]['payload']['beforeWorkspaceRevision'] == resized[0]['payload']['workspaceRevision']
        assert app.process.poll() is None

print('PASS normalization reentrancy: geometry withholding, mutation refusal, deferred title correlation, oversized draft without modal')
