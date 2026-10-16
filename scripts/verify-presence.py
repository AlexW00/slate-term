#!/usr/bin/env python3
"""Agent presence: CLI actor metadata, pane and element frames, holds, events and the display setting.
Run only through verify-vm.py."""
import subprocess
import time
from api_fixture import AppFixture, ROOT, eventually

assert subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip().startswith('VirtualMac'), 'Run this UI gate through scripts/verify-vm.py'

HTML = '''<!doctype html><title>Presence fixture</title><style>body{padding:40px}input,button{display:block;margin:12px}</style>
<input id="email"><button id="go" onclick="document.title='clicked'">Go</button>'''

with AppFixture('presence') as app:
    assert app.rpc('api.describe')['presence']['version'] == 1

    def activities():
        return app.rpc('presence.list')['activities']

    def shown(pane):
        return app.rpc('debug.presence').get(pane, [])

    def snapshot(name):
        # Visual evidence for review; fade-ins take 0.45 s.
        time.sleep(0.6)
        subprocess.run(['/usr/sbin/screencapture', '-x', str(ROOT / f'artifacts/presence-{name}.png')], check=False)

    def presence_events(cursor):
        return [e for e in app.rpc('events.poll', after=cursor, topics=['host.presence.changed'], waitMilliseconds=0)['events']]

    target = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    eventually('target prompt', lambda: app.rpc('pane.inspect', pane=target).get('state') == 'prompt')
    agent = dict(app.env, SLATE_TERM_ACTOR='claude', SLATE_TERM_PANE_ID='p1')
    other = dict(app.env, SLATE_TERM_ACTOR='claude', SLATE_TERM_PANE_ID='p9')
    cursor = app.rpc('events.head')['cursor']

    # Calls without an agent identity never show presence.
    app.cli('terminal', 'capture', '--pane', target)
    assert activities() == [] and shown(target) == []
    assert app.cli('terminal', 'capture', '--pane', target, '--note', 'orphan note', error=True)

    # An agent call frames the pane and shows its tag with the note.
    app.cli('terminal', 'capture', '--pane', target, '--note', 'reading failing test output', env=agent)
    [activity] = activities()
    assert activity['actor'] == 'claude' and activity['pane'] == target and activity['home'] == 'p1', activity
    assert activity['note'] == 'reading failing test output' and activity['actionKind'] == 'read', activity
    [tag] = shown(target)
    assert tag['label'] == 'claude' and tag['target'] == 'pane' and tag['note'] == 'reading failing test output', tag
    snapshot('pane')

    # The agent's own pane never shows presence.
    app.cli('terminal', 'capture', '--pane', 'p1', env=agent)
    assert all(a['pane'] != 'p1' for a in activities()) and shown('p1') == []

    # A second session of the same agent gets a disambiguated label. Holds pin both
    # records, so the check does not race the minimum hold on a slow VM.
    app.cli('presence', 'hold', '--pane', target, env=agent)
    app.cli('presence', 'hold', '--pane', target, env=other)
    labels = sorted(t['label'] for t in shown(target))
    assert labels == ['claude · p1', 'claude · p9'], labels
    app.cli('presence', 'release', '--pane', target, env=agent)
    app.cli('presence', 'release', '--pane', target, env=other)

    # Tags fade after the minimum hold; events report transitions, never notes.
    eventually('presence ends', lambda: activities() == [], timeout=6)
    eventually('overlay clears', lambda: shown(target) == [], timeout=3)
    events = presence_events(cursor)
    phases = [e['payload']['phase'] for e in events]
    # One began and one ended per activity, never one event per call.
    ids = [e['payload']['activityId'] for e in events]
    assert phases.count('began') == phases.count('ended') == len(set(ids)) >= 2, phases
    assert all(ids.count(i) == 2 for i in set(ids)), events
    assert all(e['pane'] == target and 'note' not in e['payload'] for e in events), events
    assert 'reading failing' not in str(events)

    # Event-caused calls are not shown, so subscribers cannot loop on presence.
    app.rpc('terminal.capture', pane=target, request_metadata={'version': 1, 'actor': {'name': 'claude', 'home': 'p1'}})
    assert [a['actor'] for a in activities()] == ['claude'], 'A CLI-style metadata actor shows presence'
    eventually('presence ends', lambda: activities() == [], timeout=6)
    token = presence_events(cursor)[-1]['deliveryContext']
    app.rpc('terminal.capture', pane=target, request_metadata={'version': 1, 'cause': token, 'actor': {'name': 'claude'}})
    assert activities() == [], 'Caused calls never show presence'
    app.rpc('terminal.capture', pane=target, request_metadata={'version': 1, 'actor': {'name': 'bad name'}}, error=-32600)

    # A long run stays live, then shows its result.
    app.cli('terminal', 'run', '--pane', target, '--command', 'sleep 1; false', env=agent)
    [run] = activities()
    assert run['actionKind'] == 'run' and run['result'] == 'failed', run
    assert shown(target)[0]['status'] == 'failed'
    eventually('run presence ends', lambda: activities() == [], timeout=6)

    # A hold keeps the tag across calls until release.
    held = app.cli('presence', 'hold', '--pane', target, '--ttl', '30', '--note', 'triaging', env=agent)
    assert held['pane'] == target
    assert app.cli('presence', 'hold', '--pane', 'p1', env=agent, error=True)
    assert app.cli('presence', 'hold', '--pane', target, error=True), 'hold requires an agent'
    app.cli('terminal', 'capture', '--pane', target, '--note', 'peeking', env=agent)
    [lease] = activities()
    assert lease['leased'] and lease['note'] == 'triaging', lease
    assert shown(target)[0]['status'] == 'held'
    time.sleep(2.0)
    assert activities(), 'A hold outlives the minimum hold'
    assert app.cli('presence', 'release', '--pane', target, env=agent)['released'] is True
    eventually('released presence ends', lambda: activities() == [], timeout=6)

    # The display setting hides overlays but keeps the API and events.
    app.cli('agent-activity', 'hide')
    app.cli('presence', 'hold', '--pane', target, env=agent)
    listed = app.rpc('presence.list')
    assert listed['visible'] is False and len(listed['activities']) == 1
    assert shown(target) == []
    app.cli('agent-activity', 'show')
    eventually('overlay returns', lambda: len(shown(target)) == 1, timeout=3)
    app.cli('presence', 'release', '--pane', target, env=agent)
    eventually('presence ends', lambda: activities() == [], timeout=6)
    assert app.rpc('presence.hold', pane=target, tab='t1', error=-32602)

    # Invalid inherited names are ignored instead of breaking calls; shell hooks never carry one.
    assert app.cli('terminal', 'capture', '--pane', target, env=dict(agent, SLATE_TERM_ACTOR='Claude Code'))
    assert activities() == []

    # Web element actions frame the element, not the pane. This is the browser pane's
    # first agent call, so overlay updates must not disturb web readiness checks.
    assets = app.root / 'assets'; assets.mkdir()
    (assets / 'index.html').write_text(HTML)
    app.rpc('command.run', id='pane.type', pane=target, type='private-browser', force=True)
    app.rpc('browser.navigate', pane=target, url=str(assets / 'index.html'))
    eventually('renderable', lambda: app.rpc('web.get', pane=target).get('renderable') is True)
    info = app.rpc('web.get', pane=target)
    clicked = app.cli('web', 'click', '--pane', target, '--selector', '#go', '--expected-view-id', info['viewId'],
                      '--expected-document-id', info['documentId'], '--note', 'submitting', env=agent)
    assert clicked['rect']['width'] > 0 and clicked['viewport']['width'] > 0, clicked
    [frame] = shown(target)
    assert frame['target'] == 'element' and frame['element']['width'] > 0 and frame['element']['y'] > 28, frame
    snapshot('element')
    app.cli('web', 'snapshot', '--pane', target, env=agent)
    assert shown(target)[0]['target'] == 'pane', 'A new pane-level call returns the frame to the pane'
    eventually('presence ends', lambda: activities() == [], timeout=6)

    # Three agents on one pane compress all but the newest tag.
    for name in ['gemini', 'codex', 'claude']:
        app.cli('presence', 'hold', '--pane', target, '--note', f'{name} is looking', env=dict(app.env, SLATE_TERM_ACTOR=name, SLATE_TERM_PANE_ID='p1'))
    tags = shown(target)
    assert [t['label'] for t in tags] == ['gemini', 'codex', 'claude'], tags
    assert [t['compact'] for t in tags] == [True, True, False], tags
    snapshot('crowded')

    # Closing the pane drops its presence.
    app.rpc('command.run', id='pane.close', pane=target, force=True)
    eventually('closed pane presence ends', lambda: activities() == [], timeout=3)
print('presence ok')
