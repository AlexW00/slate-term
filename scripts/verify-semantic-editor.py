#!/usr/bin/env python3
"""Native title completion must not block, inherit request attribution, or reach a replacement."""
import json
import socket
from api_fixture import AppFixture, eventually

with AppFixture('semantic-editor') as app:
    def mutate(**params):
        # A short owned deadline detects a nested alert; never retry the mutation.
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(5)
            peer.connect(app.path)
            with peer.makefile('rb') as stream:
                peer.sendall(b'{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":1}}\n')
                assert 'error' not in json.loads(stream.readline())
                peer.sendall(json.dumps({'jsonrpc': '2.0', 'id': 2, 'method': 'command.run', 'params': params}).encode() + b'\n')
                response = json.loads(stream.readline())
                assert 'error' not in response, response
                return response['result']

    def begin(title):
        app.rpc('debug.paneHeader', pane='p1', beginRename=True, draft=title)
        return app.rpc('events.head')['cursor']

    def facts(after):
        return app.rpc('events.poll', after=after, topics=['host.pane.*', 'host.focus.*', 'host.layout.*', 'host.workspace.*'], waitMilliseconds=0)['events']

    def cancelled(after, result):
        emitted = facts(after)
        assert not any(e['topic'] == 'host.pane.title.changed' for e in emitted), emitted
        initiating = [e for e in emitted if e['payload']['operationId'] == result['operationId']]
        assert initiating and all(e['payload']['workspaceRevision'] == result['workspaceRevision'] for e in initiating)
        assert not app.rpc('debug.paneHeader', pane='p1')['editing']

    other = app.cli('panes', 'split', '--pane', 'p1', '--right')['paneId']
    app.rpc('debug.activate')
    start = begin('Discarded during focus change')
    response = mutate(id='pane.focus', pane=other)
    cancelled(start, response)
    assert app.rpc('workspace.get')['tabs'][0]['focusedPane'] == other

    session = app.rpc('pane.inspect', pane='p1')['sessionId']
    start = begin('Discarded through split')
    response = mutate(id='split.right', pane='p1')
    cancelled(start, response)
    assert app.rpc('pane.inspect', pane='p1')['sessionId'] == session

    # An explicit model title update must not clobber the unsent editor draft. The
    # subsequent native completion is a new operation, not part of that API write.
    begin('User commits last')
    mutate(id='pane.title.set', pane='p1', title='API title while editing')
    assert app.rpc('debug.paneHeader', pane='p1')['draft'] == 'User commits last'
    start = app.rpc('events.head')['cursor']
    before = app.rpc('workspace.snapshot')['workspaceRevision']
    app.rpc('debug.paneHeader', pane='p1', finish='commit')
    assert app.rpc('pane.inspect', pane='p1')['manualTitle'] == 'User commits last'
    native = [e for e in facts(start) if e['topic'] == 'host.pane.title.changed']
    assert len(native) == 1 and native[0]['payload']['origin'] == {'kind': 'native'}, native
    assert native[0]['payload']['beforeWorkspaceRevision'] == before
    assert native[0]['payload']['workspaceRevision'] != before

    start = begin('Must not reach a replacement')
    mutate(id='pane.type', pane='p1', type='browser', force=True)
    assert app.rpc('pane.inspect', pane='p1')['manualTitle'] == 'User commits last'
    assert not any(e['topic'] == 'host.pane.title.changed' for e in facts(start))

    start = begin('Must not survive closure')
    mutate(id='pane.close', pane='p1', force=True)
    assert not any(pane['id'] == 'p1' for pane in app.rpc('workspace.get')['panes'])
    assert not any(e['topic'] == 'host.pane.title.changed' for e in facts(start))

print('PASS native rename popover: focus/reparent cancels without mutation/modal error, explicit commit native attribution/revisions, draft preservation, no replacement/closure retargeting')
