#!/usr/bin/env python3
"""Owned host divider previews, guarded settlement, native attribution and retired input."""
import os
import time
from api_fixture import AppFixture, ROOT, eventually

with AppFixture('divider-events') as app:
    def pane(p='p1'):
        return app.rpc('pane.inspect', pane=p)

    def tree():
        return app.rpc('layout.get', tab='t1')

    def snapshot():
        return app.rpc('workspace.snapshot')

    def head():
        return app.rpc('events.head')['cursor']

    def facts(cursor):
        return app.rpc('events.poll', after=cursor, topics=['host.layout.*', 'host.workspace.*'], waitMilliseconds=0)['events']

    def gesture(phase, **kw):
        return app.rpc('debug.dividerGesture', phase=phase, tab='t1', **kw)

    app.cli('panes', 'split', '--pane', 'p1', '--right')
    app.cli('panes', 'split', '--pane', 'p1', '--right', '--new-pane-fraction', '.75',
            '--expected-layout-revision', pane()['layoutRevision'])
    app.rpc('debug.activate', tab='t1')
    eventually('owned window active', lambda: app.rpc('debug.inspect')['applicationActive'])
    eventually('all owned shells at prompt', lambda: all(pane(p).get('state') == 'prompt' for p in ['p1', 'p2', 'p3']))
    sessions = {p: pane(p)['sessionId'] for p in ['p1', 'p2', 'p3']}
    before, revision, cursor = tree(), pane()['layoutRevision'], head()
    workspace_revision = snapshot()['workspaceRevision']
    assert gesture('begin', path=[])['active']
    for fraction in [.01, .4, .55, .7]:
        sample = gesture('move', fraction=fraction)
        assert sample['active']
        assert all(p['width'] >= 80 and p['height'] >= 80 for p in sample['leaves'])
        measured = {p['paneId']: p for p in sample['leaves']}
        available = measured['p1']['width'] + measured['p3']['width']
        assert abs(measured['p1']['width'] - available * before['first']['fraction']) <= 1 / sample['backingScale'], sample
        assert tree() == before and snapshot()['workspaceRevision'] == workspace_revision
        assert not facts(cursor)
        if os.environ.get('SLATE_CAPTURE_DIVIDERS') == '1' and fraction == .01:
            # The synchronous capture blocks the app thread; allow the display link and
            # PTY resize redraw to run first. Geometry assertions above never depend on this.
            time.sleep(.2)
            app.rpc('debug.screenshot', path=str(ROOT / 'artifacts/divider-host-preview.png'))
        for p in sessions:
            assert pane(p)['geometry'] is None and pane(p)['geometryState'] == 'unavailable'
    assert not gesture('end')['active']
    assert abs(tree()['fraction'] - .7) < .002 and tree()['first']['fraction'] == before['first']['fraction']
    emitted = facts(cursor)
    resize = [e for e in emitted if e['topic'] == 'host.layout.resized']
    assert len(resize) == 1 and resize[0]['payload']['path'] == [], emitted
    payload = resize[0]['payload']
    assert payload['origin'] == {'kind': 'native'} and payload['actionKind'] == 'layout.resize'
    assert all(e['payload']['operationId'] == payload['operationId'] for e in emitted)
    assert pane()['layoutRevision'] != revision
    assert all(pane(p)['sessionId'] == session for p, session in sessions.items())
    assert all(pane(p)['geometryState'] == 'sampled' for p in sessions)
    if os.environ.get('SLATE_CAPTURE_DIVIDERS') == '1':
        time.sleep(.2)
        app.rpc('debug.screenshot', path=str(ROOT / 'artifacts/divider-host-settled.png'))

    # Cancel and click-without-movement never publish invented mutations.
    for phase in ['cancel', 'end']:
        before, cursor = tree(), head()
        assert gesture('begin', path=['first'])['active']
        if phase == 'cancel':
            gesture('move', fraction=.6)
        assert not gesture(phase)['active']
        if phase == 'cancel':
            gesture('end')
        assert tree() == before and not facts(cursor)

    # Finish the real pending native edit BEFORE the caller's old guard is checked.
    revision, cursor = pane()['layoutRevision'], head()
    gesture('begin', path=[])
    gesture('move', fraction=.6)
    app.rpc('command.run', id='layout.resize', tab='t1', path=[], firstChildFraction=.5,
            expectedLayoutRevision=revision, error=-32050)
    after = tree()
    assert abs(after['fraction'] - .6) < .002
    assert len([e for e in facts(cursor) if e['topic'] == 'host.layout.resized']) == 1
    gesture('move', fraction=.8)
    gesture('end')
    assert tree() == after, 'Retired controller retargeted its replacement'

print('PASS divider host: local preview, tab geometry withholding, one native shared commit, cancellation/no-op, guard ordering and retired-controller input')
