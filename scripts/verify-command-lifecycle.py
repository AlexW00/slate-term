#!/usr/bin/env python3
"""Admitted command jobs have one start/finish, captured lineage and value-free facts."""
import concurrent.futures
import json
import socket
from api_fixture import AppFixture, eventually

with AppFixture('command-lifecycle') as app:
    missing = app.root / 'removed-working-directory'
    missing.mkdir()
    commands = [
        dict(id='ok', title='OK', executable='/bin/sh', arguments=['-c', 'printf PRIVATE_OUTPUT']),
        dict(id='fail', title='Fail', executable='/bin/sh', arguments=['-c', 'printf PRIVATE_ERROR >&2; exit 7']),
        dict(id='spawn', title='Spawn failure', executable='/bin/sh', arguments=['-c', 'true'], directory=str(missing)),
        dict(id='timeout', title='Timeout', executable='/bin/sleep', arguments=['10'], timeoutSeconds=1),
        dict(id='cancel', title='Cancel', executable='/bin/sleep', arguments=['10']),
        dict(id='delayed', title='Delayed', executable='/bin/sleep', arguments=['1']),
    ]
    app.rpc('plugins.register', manifest=dict(id='lifecycle', title='Lifecycle', commands=commands))
    missing.rmdir()

    def facts(cursor):
        return app.rpc('events.poll', after=cursor, topics=['host.command.*'], waitMilliseconds=0)['events']

    def pair(events, state):
        assert [e['topic'] for e in events] == ['host.command.started', 'host.command.finished'], events
        start, finish = [e['payload'] for e in events]
        assert start['state'] == 'running' and finish['state'] == state, events
        assert start['invocationId'] == finish['invocationId'] and start['operationId'] == finish['operationId'], events
        assert start['launchWorkspaceRevision'] == finish['launchWorkspaceRevision']
        for e in events:
            assert e['source'] == {'kind': 'host'}
            p = e['payload']
            assert p['beforeWorkspaceRevision'] == p['workspaceRevision']
            assert p['beforeLayoutRevision'] == p['layoutRevision']
            assert not {'stdout', 'stderr', 'error', 'params', 'arguments', 'settings', 'environment'} & p.keys(), p
        assert 'PRIVATE_' not in json.dumps(events), events
        return start, finish

    for command, state, error in [('ok', 'succeeded', None), ('fail', 'failed', -32025),
                                   ('spawn', 'failed', -32025), ('timeout', 'timedOut', -32024)]:
        cursor = app.rpc('events.head')['cursor']
        result = app.rpc('command.run', id='plugin.lifecycle.' + command, pane='p1', privateArgument='PRIVATE_ARGUMENT', error=error)
        start, finish = pair(facts(cursor), state)
        assert finish['commandId'] == 'plugin.lifecycle.' + command
        if command == 'ok': assert result['instanceId'] == finish['invocationId'] and finish['exitCode'] == 0
        if command == 'fail': assert finish['exitCode'] == 7

    cursor = app.rpc('events.head')['cursor']
    peer = socket.socket(socket.AF_UNIX)
    peer.settimeout(5)
    peer.connect(app.path)
    stream = peer.makefile('rb')
    try:
        peer.sendall(b'{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":1}}\n')
        assert 'result' in json.loads(stream.readline())
        peer.sendall(b'{"jsonrpc":"2.0","id":2,"method":"command.run","params":{"id":"plugin.lifecycle.cancel","pane":"p1"}}\n')
        eventually('command admitted', lambda: len(facts(cursor)) == 1)
    finally:
        stream.close(); peer.close()
    eventually('cancel fact', lambda: len(facts(cursor)) == 2)
    pair(facts(cursor), 'cancelled')

    # A parent reference may be consumed by an asynchronous invocation. Intervening
    # workspace changes must not be attributed to that command's publication ranges.
    cursor = app.rpc('events.head')['cursor']
    app.rpc('command.run', id='pane.title.set', pane='p1', title='parent')
    parent = app.rpc('events.poll', after=cursor, topics=['host.pane.title.changed'], waitMilliseconds=0)['events'][0]
    cursor = parent['cursor']
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(app.rpc, 'command.run', id='plugin.lifecycle.delayed', pane='p1',
                              request_metadata=dict(version=1, cause=parent['deliveryContext']))
        eventually('delayed command admitted', lambda: len(facts(cursor)) == 1)
        app.rpc('command.run', id='pane.close', pane='p1', force=True)
        pending.result(timeout=5)
    start, finish = pair(facts(cursor), 'succeeded')
    assert start['workspaceRevision'] != finish['workspaceRevision']
    assert finish['paneId'] == 'p1' and finish['tabId'] == 't1'
    assert finish['targetAvailable'] is False and finish['layoutRevision'] is None
    assert finish['causalDepth'] == 1 and finish['parentOperationId'] == parent['payload']['operationId']

    cursor = app.rpc('events.head')['cursor']
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(app.rpc, 'command.run', id='plugin.lifecycle.cancel', error=-32022)
        eventually('unregister fixture admitted', lambda: len(facts(cursor)) == 1)
        app.rpc('plugins.unregister', id='lifecycle', force=True)
        pending.result(timeout=5)
    start, finish = pair(facts(cursor), 'cancelled')
    assert finish['terminationReason'] == 'unregistered' and finish['targetAvailable'] is None
    # Peer cleanup and supervisor completion must not append a second finish.
    app.rpc('workspace.snapshot')
    assert len(facts(cursor)) == 2

print('PASS command lifecycle: success/failure/spawn/timeout/cancel, one terminal fact, async lineage, current revision samples, deleted targets and envelope privacy')
