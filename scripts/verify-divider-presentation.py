#!/usr/bin/env python3
"""Native presentation resizing preserves feasible model fractions; constraints are observations."""
from api_fixture import AppFixture, eventually

with AppFixture('divider-presentation') as app:
    def layout():
        return app.rpc('layout.get', tab='t1')

    def pane():
        return app.rpc('pane.inspect', pane='p1')

    def facts(cursor):
        return app.rpc('events.poll', after=cursor, topics=['host.layout.*', 'host.workspace.*'], waitMilliseconds=0)['events']

    app.cli('panes', 'split', '--pane', 'p1', '--right')
    app.cli('panes', 'split', '--pane', 'p1', '--right', '--new-pane-fraction', '.75',
            '--expected-layout-revision', pane()['layoutRevision'])
    app.rpc('command.run', id='layout.resize', tab='t1', path=[], firstChildFraction=.7,
            expectedLayoutRevision=pane()['layoutRevision'])
    app.rpc('debug.activate', tab='t1')
    eventually('owned presentation active', lambda: app.rpc('debug.inspect')['applicationActive'])
    before, revision = layout(), pane()['layoutRevision']
    cursor = app.rpc('events.head')['cursor']
    for width in [1200, 900, 1100]:
        app.rpc('debug.windowGeometry', tab='t1', width=width, height=650)
        after = layout()
        assert after == before, dict(message='Feasible window resize imported incidental autoresize fractions', width=width, before=before, after=after, events=facts(cursor))
        assert pane()['layoutRevision'] == revision and not facts(cursor)

    cursor = app.rpc('events.head')['cursor']
    app.rpc('debug.windowGeometry', tab='t1', width=440, height=650)
    constrained = layout()
    assert constrained != before, 'A real constrained adjustment was not observed'
    emitted = facts(cursor)
    resized = [e for e in emitted if e['topic'] == 'host.layout.resized']
    assert resized and all(e['payload']['origin'] == {'kind': 'native'} for e in emitted)
    assert all(e['payload']['actionKind'] != 'layout.resize' for e in resized), 'A presentation constraint was mislabeled as a user drag'
    assert len({e['payload']['operationId'] for e in emitted}) == 1, emitted
    for p in app.rpc('panes.list'):
        info = app.rpc('pane.inspect', pane=p['id'])
        assert info['geometryState'] == 'sampled' and info['geometry']['width'] >= 80 and info['geometry']['height'] >= 80
    app.rpc('debug.windowGeometry', tab='t1', width=1000, height=650)
    assert layout() == constrained

print('PASS native presentation: preserve feasible fractions, one attributed constrained observation, native minimum and stable widening')
