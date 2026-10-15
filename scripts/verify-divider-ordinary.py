#!/usr/bin/env python3
"""Legacy/native programmatic divider movement is distinct from window autoresize."""
from api_fixture import AppFixture, eventually

with AppFixture('divider-ordinary') as app:
    app.cli('panes', 'split', '--pane', 'p1', '--right')
    revision = app.rpc('pane.inspect', pane='p1')['layoutRevision']
    app.cli('panes', 'split', '--pane', 'p1', '--right', '--new-pane-fraction', '.75', '--expected-layout-revision', revision)
    app.rpc('command.run', id='layout.resize', tab='t1', path=[], firstChildFraction=.7,
            expectedLayoutRevision=app.rpc('pane.inspect', pane='p1')['layoutRevision'])
    app.rpc('debug.activate', tab='t1')
    eventually('owned native window active', lambda: app.rpc('debug.inspect')['applicationActive'])
    before = app.rpc('layout.get', tab='t1')
    cursor = app.rpc('events.head')['cursor']
    app.rpc('debug.divider', tab='t1', fraction=.6)
    after = app.rpc('layout.get', tab='t1')
    events = app.rpc('events.poll', after=cursor, topics=['host.layout.resized'], waitMilliseconds=0)['events']
    assert abs(after['fraction'] - .6) < .001, dict(before=before, after=after, events=events)
    assert after['first']['fraction'] == before['first']['fraction'], dict(before=before, after=after, events=events)
    assert len(events) == 1 and events[0]['payload']['path'] == [], events
    assert events[0]['payload']['origin'] == {'kind': 'native'} and events[0]['payload']['actionKind'] == 'native.resize', events

print('PASS ordinary native divider: ancestor adjustment retained, descendant proportions preserved, one native observation')
