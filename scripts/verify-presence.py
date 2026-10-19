#!/usr/bin/env python3
"""Agent presence: CLI actor metadata, pane and element frames, holds, events and the display setting.
Run only through verify-vm.py."""
import json
import subprocess
import sys
import time
from plugin_package_fixture import package_fixture
from api_fixture import AppFixture, ROOT, eventually

assert subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip().startswith('VirtualMac'), 'Run this UI gate through scripts/verify-vm.py'

HTML = '''<!doctype html><title>Presence fixture</title><style>body{padding:40px}input,button{display:block;margin:12px}button{width:240px;height:48px}</style>
<input id="email"><button id="go" onclick="document.title='clicked'">Go</button>'''

with AppFixture('presence') as app:
    app.capture_contracts()
    assert app.rpc('api.describe')['presence']['version'] == 1
    app.cli('appearance', 'dark')
    app.rpc('debug.activate')

    def fixture_is_active():
        state = app.rpc('debug.notifications')
        return state['appActive'] and state['keyTab'] == 't1'

    # Reject a locked or inactive desktop before accepting any rendered evidence.
    eventually('presence fixture active with its native key window', fixture_is_active)

    def activities():
        return app.rpc('presence.list')['activities']

    def shown(pane):
        return app.rpc('debug.presence').get(pane, [])

    def snapshot(name, *, settle=0.6, activate=True):
        # Capture the on-screen glass composite, not an offscreen view rendering.
        if activate:
            app.rpc('debug.activate')
        time.sleep(settle)
        subprocess.run(['/usr/sbin/screencapture', '-x', str(ROOT / f'artifacts/presence-{name}.png')], check=False)

    def presence_events(cursor):
        return [e for e in app.rpc('events.poll', after=cursor, topics=['host.presence.changed'], waitMilliseconds=0)['events']]

    target = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    eventually('target prompt', lambda: app.rpc('pane.inspect', pane=target).get('state') == 'prompt')
    agent = dict(app.env, SLATE_TERM_ACTOR='claude', SLATE_TERM_PANE_ID='p1')
    other = dict(app.env, SLATE_TERM_ACTOR='claude', SLATE_TERM_PANE_ID='p9')
    # Both split routes put presence on the new pane, including splits from home.
    # Preserving focus also lets an agent run and capture without interrupting typing.
    app.rpc('command.run', id='pane.focus', pane='p1')
    for source, direction in [('p1', 'down'), (target, 'left')]:
        cursor = app.rpc('events.head')['cursor']
        revision = app.rpc('pane.inspect', pane=source)['layoutRevision']
        created = app.cli('panes', 'split', '--pane', source, '--' + direction,
                          '--focus-policy', 'preserve', '--expected-layout-revision', revision,
                          '--note', 'creating a command pane', env=agent)['paneId']
        [split] = activities()
        assert split['pane'] == created and split['actionKind'] == 'command', split
        assert shown(source) == [] and shown(created)[0]['note'] == 'creating a command pane'
        assert next(t for t in app.rpc('tabs.list') if t['id'] == 't1')['focusedPane'] == 'p1'
        assert all(e['pane'] == created for e in presence_events(cursor))
        time.sleep(2)
        assert any(a['pane'] == created for a in activities()), 'Split tag must remain readable'
        snapshot('split-' + direction, settle=0)
        eventually('new split prompt', lambda: app.rpc('pane.inspect', pane=created).get('state') == 'prompt')
        info = app.rpc('pane.inspect', pane=created)
        app.cli('terminal', 'run', '--pane', created, '--session-id', info['sessionId'],
                '--shell', info['shell'], '--command', 'echo PRESERVED_FOCUS', env=agent)
        app.cli('terminal', 'capture', '--pane', created, env=agent)
        assert next(t for t in app.rpc('tabs.list') if t['id'] == 't1')['focusedPane'] == 'p1'
        native = next(p for p in app.rpc('debug.inspect')['panes'] if p['paneId'] == 'p1')
        assert native['firstResponder'], native
        app.rpc('command.run', id='pane.close', pane=created, force=True)
        eventually('split presence clears', lambda: activities() == [])

    for direction in ['left', 'right', 'up', 'down']:
        created = app.cli('command', 'run', 'split.' + direction, '--pane', target,
                          '--note', 'creating a split', env=agent)['paneId']
        assert [a['pane'] for a in activities()] == [created]
        assert shown(target) == [] and shown(created)
        app.rpc('command.run', id='pane.close', pane=created, force=True)
        eventually('split presence clears', lambda: activities() == [])

    revision = app.rpc('pane.inspect', pane=target)['layoutRevision']
    app.cli('panes', 'split', '--pane', target, '--right', '--focus-policy', 'preserve',
            '--type', 'missing-plugin', '--expected-layout-revision', revision, env=agent, error=True)
    assert activities() == [] and shown(target) == [], 'A rejected split has no new pane to highlight'

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
    assert tag['glass'] and tag['outsidePassesThrough'], tag
    snapshot('pane')

    # The agent's own pane never shows presence.
    app.cli('terminal', 'capture', '--pane', 'p1', env=agent)
    assert all(a['pane'] != 'p1' for a in activities()) and shown('p1') == []

    # Labels remain stable when another session of the same agent joins.
    # Holds pin distinct records so this does not race the minimum display time.
    for environment in [agent, other]:
        held = app.cli('presence', 'hold', '--pane', target, env=environment)
        app.contract_capture.record('presence.hold', {'pane': target}, held, client='cli')
    labels = sorted(t['label'] for t in shown(target))
    assert labels == ['claude', 'claude'], labels
    assert len({t['id'] for t in shown(target)}) == 2
    for environment in [agent, other]:
        released = app.cli('presence', 'release', '--pane', target, env=environment)
        app.contract_capture.record('presence.release', {'pane': target}, released, client='cli')

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

    # A long run stays live, then shows its result. Its entrance has already settled;
    # capture immediately, before the short result hold starts fading out.
    app.rpc('debug.activate')
    app.cli('terminal', 'run', '--pane', target, '--command', 'sleep 1; false', env=agent)
    snapshot('failed', settle=0, activate=False)
    [run] = activities()
    assert run['actionKind'] == 'run' and run['result'] == 'failed', run
    assert shown(target)[0]['status'] == 'failed'
    eventually('run presence ends', lambda: activities() == [], timeout=6)

    # A start returns before completion; its activity survives the submitting CLI.
    started = app.cli('terminal', 'start', '--pane', target, '--shell', 'zsh',
                      '--command', 'sleep 8; false', '--note', 'checking async work', env=agent)
    time.sleep(5.5)
    [running] = activities()
    assert running['live'] and running['actionKind'] == 'run' and 'result' not in running, running
    assert shown(target)[0]['status'] == 'live', shown(target)
    snapshot('async-running', settle=0, activate=False)
    result = app.cli('terminal', 'operationWait', '--command-id', started['commandId'], env=agent)
    assert result['exitCode'] == 1, result
    [finished] = activities()
    assert not finished['live'] and finished['result'] == 'failed', finished
    assert shown(target)[0]['status'] == 'failed', shown(target)
    eventually('start presence ends', lambda: activities() == [], timeout=6)

    # Previously omitted pane reads and edits use the same actor metadata.
    metadata = {'version': 1, 'actor': {'name': 'claude', 'home': 'p1'}}
    for method, params, action in [
        ('terminal.history', {}, 'read'),
        ('terminal.historyExport', {'path': str(app.root / 'history.txt')}, 'read'),
        ('terminal.search', {'action': 'set', 'query': 'sleep'}, 'write'),
        ('terminal.search', {'action': 'end'}, 'write'),
    ]:
        app.rpc(method, pane=target, request_metadata=metadata, **params)
        [activity] = activities()
        assert activity['pane'] == target and activity['actionKind'] == action, (method, activity)
        assert shown(target), method
    eventually('pane edits presence ends', lambda: activities() == [], timeout=6)

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
    snapshot('held-dark')
    [pill] = shown(target)
    assert pill['detail'] == '', pill
    assert pill['holdIconCenterY'] == pill['frame']['height'] / 2, pill
    motion = pill['holdAnimation']
    assert motion['active'] != motion['reduceMotion'], motion
    samples = []
    for _ in range(15):
        sample = shown(target)[0]['holdAnimation']
        assert abs(sample['centerY'] - pill['frame']['height'] / 2) < 0.01, sample
        samples.append(sample)
        time.sleep(0.2)
    (ROOT / 'artifacts/presence-hold-animation-samples.json').write_text(json.dumps(samples, indent=2))
    if motion['reduceMotion']:
        assert all(s['opacity'] == s['scale'] == 1 for s in samples), samples
    else:
        assert max(s['opacity'] for s in samples) - min(s['opacity'] for s in samples) > 0.4, samples
        assert max(s['scale'] for s in samples) - min(s['scale'] for s in samples) > 0.07, samples
        for name, predicate in [('low', lambda m: m['opacity'] < 0.55), ('high', lambda m: m['opacity'] > 0.9)]:
            eventually('hold breath ' + name, lambda: predicate(shown(target)[0]['holdAnimation']))
            snapshot('hold-breath-' + name, settle=0, activate=False)
    top_left, top_right, bottom_right, bottom_left = pill['ringCornerRadii']
    assert top_left == top_right == bottom_left == 7 and bottom_right > 7, pill
    assert pill['hitTarget'] and not pill['clickable'], pill
    assert pill['frame']['bottomInset'] == 14 and pill['cornerRadius'] == pill['frame']['height'] / 2, pill
    # Outer window corners follow the window; split intersections keep the pane radius.
    app.cli('presence', 'hold', '--pane', 'p1', '--ttl', '30', env=other)
    [left_pill] = shown('p1')
    assert left_pill['ringCornerRadii'][:3] == [7, 7, 7] and left_pill['ringCornerRadii'][3] > 7, left_pill
    snapshot('outer-corners-dark')
    app.rpc('command.run', id='pane.zoom', pane=target)
    eventually('zoomed outer corners', lambda: all(radius > 7 for radius in shown(target)[0]['ringCornerRadii'][2:]))
    snapshot('zoomed-corners-dark')
    app.rpc('command.run', id='pane.zoom', pane=target)
    eventually('split corners restored', lambda: shown(target)[0]['ringCornerRadii'][3] == 7)
    app.cli('presence', 'release', '--pane', 'p1', env=other)
    app.cli('appearance', 'light')
    snapshot('held-light')
    app.cli('appearance', 'dark')
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
    assert frame['glass'] and frame['outsidePassesThrough'], frame
    snapshot('element')
    assert shown(target)[0]['frame']['bottomInset'] > shown(target)[0]['frame']['height'], shown(target)
    app.cli('web', 'snapshot', '--pane', target, env=agent)
    assert shown(target)[0]['target'] == 'pane', 'A new pane-level call returns the frame to the pane'
    eventually('presence ends', lambda: activities() == [], timeout=6)

    # Identical element targets share one native ring, including when membership changes.
    def click_as(name, selector='#go'):
        return app.rpc('web.click', pane=target, selector=selector,
                       expectedViewId=info['viewId'], expectedDocumentId=info['documentId'],
                       request_metadata={'version': 1, 'actor': {'name': name, 'home': 'p1'}})

    def shared_ring(count):
        tags = shown(target)
        assert len(tags) == count and all(t['target'] == 'element' for t in tags), tags
        assert len({t['ringID'] for t in tags}) == 1, tags
        assert all(t['ringColors'] == count for t in tags), tags
        expected = [0] + [(i + 0.5) / count for i in range(count)] + [1]
        assert tags[0]['ringStops'] == expected, tags
        assert tags[0]['ringWidth'] == tags[0]['element']['width'] + 9.5, tags
        return tags[0]['ringID']

    click_as('claude')
    shared = shared_ring(1)
    click_as('codex')
    assert shared_ring(2) == shared
    snapshot('shared-two')
    click_as('claude')
    click_as('gemini')
    assert shared_ring(3) == shared
    snapshot('shared-three')

    # Moving one agent to another element leaves two colors on the original ring.
    click_as('gemini', '#email')
    tags = shown(target)
    assert [t['ringColors'] for t in tags] == [2, 2, 1], tags
    assert tags[0]['ringID'] == tags[1]['ringID'] == shared != tags[2]['ringID'], tags
    snapshot('separate-elements')
    # Refresh the short holds before checking rapid membership changes.
    click_as('claude')
    click_as('codex')
    # Rejoining and leaving during a color fade must preserve the shared ring.
    click_as('gemini')
    assert shared_ring(3) == shared
    app.rpc('web.snapshot', pane=target,
            request_metadata={'version': 1, 'actor': {'name': 'codex', 'home': 'p1'}})
    tags = shown(target)
    assert [t['ringColors'] for t in tags] == [2, 1, 2], tags
    assert tags[0]['ringID'] == tags[2]['ringID'] == shared, tags
    assert tags[1]['target'] == 'pane', tags
    snapshot('shared-departure')
    app.rpc('web.snapshot', pane=target,
            request_metadata={'version': 1, 'actor': {'name': 'gemini', 'home': 'p1'}})
    tags = shown(target)
    assert [t['ringColors'] for t in tags] == [1, 2, 2], tags
    assert tags[0]['ringID'] == shared and tags[1]['ringID'] == tags[2]['ringID'], tags
    eventually('shared presence ends', lambda: activities() == [], timeout=6)
    eventually('shared overlay clears', lambda: shown(target) == [], timeout=3)

    # Three agents on one pane compress all but the newest tag.
    for name in ['gemini', 'codex', 'claude']:
        app.cli('presence', 'hold', '--pane', target, '--note', f'{name} is looking', env=dict(app.env, SLATE_TERM_ACTOR=name, SLATE_TERM_PANE_ID='p1'))
    tags = shown(target)
    assert [t['label'] for t in tags] == ['gemini', 'codex', 'claude'], tags
    assert [t['compact'] for t in tags] == [True, True, False], tags
    assert len({t['ringID'] for t in tags}) == 1 and all(t['ringColors'] == 3 for t in tags), tags
    assert all(t['glass'] and t['outsidePassesThrough'] for t in tags), tags
    snapshot('crowded')

    # Overflow retains the newest tag and hides older tags behind a +N glass chip.
    for index in range(8):
        app.cli('presence', 'hold', '--pane', target, env=dict(app.env, SLATE_TERM_ACTOR=f'extra{index}', SLATE_TERM_PANE_ID='p1'))
    eventually('overflow hides older tags', lambda: any(not t['shown'] for t in shown(target)))
    assert shown(target)[-1]['shown'], shown(target)
    snapshot('overflow')

    # Closing the pane drops its presence.
    app.rpc('command.run', id='pane.close', pane=target, force=True)
    eventually('closed pane presence ends', lambda: activities() == [], timeout=3)
print('presence presentation ok')

with AppFixture('presence-focus') as app:
    def command(id, **params):
        return app.rpc('command.run', id=id, **params)

    def inspect(pane):
        return app.rpc('pane.inspect', pane=pane)

    def listed(id):
        return next(a for a in app.rpc('presence.list')['activities'] if a['activityId'] == id)

    def shown(pane):
        return app.rpc('debug.presence').get(pane, [])

    def focus_is(pane):
        info = inspect(pane)
        window = app.rpc('window.get', windowId=info['windowId'])
        tab = next(t for t in app.rpc('tabs.list') if t['id'] == info['tabId'])
        native = next(p for p in app.rpc('debug.inspect')['panes'] if p['paneId'] == pane)
        application = app.rpc('debug.notifications')
        return (application['appActive'] and application['keyTab'] == info['tabId']
                and window['key'] and tab['focusedPane'] == pane and native.get('firstResponder') is True)

    instance = app.rpc('workspace.snapshot')['appInstanceId']
    origin = 'p1'
    session = inspect(origin)['sessionId']
    origin_window = inspect(origin)['windowId']
    command('window.new', focus='new')
    target = app.rpc('tabs.list')[-1]['focusedPane']
    eventually('focus target prompt', lambda: inspect(target).get('state') == 'prompt')
    env = dict(app.env, SLATE_TERM_ACTOR='claude', SLATE_TERM_PANE_ID=origin,
               SLATE_TERM_INSTANCE_ID=instance, SLATE_TERM_SESSION_ID=session)
    held = app.cli('presence', 'hold', '--pane', target, '--ttl', '300', '--note', 'checking output', env=env)
    activity = held['activityId']
    assert listed(activity)['canFocus'] is True
    describe = app.rpc('api.describe')
    assert describe['presence']['originVersion'] == 1 and 'presence.focus' in describe['methods']
    app.rpc('presence.focus', error=-32602)
    app.rpc('presence.focus', activityId=activity, pane=target, error=-32602)
    app.rpc('presence.focus', activityId=activity, expectedAnchorSessionId=session, error=-32602)
    app.rpc('presence.focus', activityId=activity, expectedInstanceId='stale-app', error=-32050)

    # Real native NSButton action, shared with the public operation; pill hit-testing is isolated.
    eventually('native pill shown', lambda: any(t['id'] == activity and t['shown'] and t['hitTarget'] for t in shown(target)))
    pill = next(t for t in shown(target) if t['id'] == activity)
    assert pill['clickable'] and pill['outsidePassesThrough'] and pill['glass'], pill
    assert pill['frame']['bottomInset'] == 14 and pill['cornerRadius'] == pill['frame']['height'] / 2
    app.rpc('command.run', id='window.focus', windowId=inspect(target)['windowId'], activate=True)
    eventually('native target active and focused before click', lambda: focus_is(target))
    time.sleep(0.6)
    subprocess.run(['/usr/sbin/screencapture', '-x', str(ROOT / 'artifacts/presence-clickable.png')], check=True)
    assert app.rpc('debug.presenceClick', pane=target, activityId=activity)['clicked']
    eventually('native origin focus', lambda: focus_is(origin))
    command('pane.focus', pane=target)
    assert app.cli('presence', 'focus', '--activity-id', activity, env=app.env)['paneId'] == origin
    eventually('CLI origin focus', lambda: focus_is(origin))
    command('pane.focus', pane=target)
    command('window.minimize', windowId=origin_window)
    eventually('origin minimized', lambda: app.rpc('window.get', windowId=origin_window)['minimized'])
    assert app.rpc('presence.focus', activityId=activity)['focused']
    eventually('origin restored and focused', lambda: not app.rpc('window.get', windowId=origin_window)['minimized'] and focus_is(origin))

    # Registered pages and services discover/use the same operation, without becoming actors.
    panel = app.root / 'panel'; panel.mkdir()
    (panel / 'index.html').write_text('<!doctype html><title>Presence controller</title><p>Presence controller</p>')
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='presence.controller', title='Presence controller',
        source=dict(kind='directory', path=str(panel))), app.root))
    controller = command('split.right', pane=target)['paneId']
    command('pane.type', pane=controller, type='presence.controller', force=True)
    eventually('presence page bridge', lambda: app.rpc('debug.pluginEval', pane=controller, script='typeof workspace') == 'object')
    actor_metadata = dict(version=1, actor=dict(name='codex', home=origin))
    view = app.rpc('web.get', pane=controller)
    app.rpc('pane.title', pane=controller, title='Presence controller title',
            expectedViewId=view['viewId'], expectedDocumentId=view['documentId'], request_metadata=actor_metadata)
    for action in ['patch', 'reset']:
        [editing] = [a for a in app.rpc('presence.list')['activities'] if a['pane'] == controller]
        assert editing['actor'] == 'codex' and editing['actionKind'] == 'write', editing
        assert shown(controller), action
        state = app.rpc('plugins.panelState.get', pane=controller)
        params = dict(pane=controller, expectedPanelId=state['panelId'], expectedStateRevision=state['revision'])
        if action == 'patch':
            params['operations'] = [dict(op='set', key='presenceTest', value=True)]
        app.rpc('plugins.panelState.' + action, request_metadata=actor_metadata, **params)
    [editing] = [a for a in app.rpc('presence.list')['activities'] if a['pane'] == controller]
    assert editing['count'] == 3 and editing['actionKind'] == 'write', editing
    assert shown(controller)
    script = 'await workspace.presence.focus({activityId:' + json.dumps(activity) + '})'
    assert app.rpc('debug.pluginEval', pane=controller, script=script)['paneId'] == origin
    eventually('page origin focus', lambda: focus_is(origin))
    worker = app.root / 'service.py'
    context_path = app.root / 'service-context.json'
    worker.write_text('''import json,os,pathlib,subprocess,time
keys=['SLATE_TERM_SOCKET','SLATE_TERM_INSTANCE_ID','SLATE_TERM_SERVICE_PLUGIN_ID','SLATE_TERM_SERVICE_ID','SLATE_TERM_SERVICE_GENERATION']
pathlib.Path(os.environ['CONTEXT_PATH']).write_text(json.dumps({k:os.environ[k] for k in keys}))
subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc','service.ready','--params','{"version":1}'],check=True)
while True: time.sleep(1)
''')
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='presence.service', title='Presence service', service=dict(
        executable=sys.executable, arguments=[str(worker)], environment=dict(CONTEXT_PATH=str(context_path)), readyTimeoutSeconds=10)), app.root))
    app.rpc('plugins.service.start', id='presence.service')
    eventually('presence service ready', lambda: app.rpc('plugins.service.status', id='presence.service')['state'] == 'ready')
    service_env = dict(app.env, **json.loads(context_path.read_text()))
    command('pane.focus', pane=target)
    assert app.cli('presence', 'focus', '--activity-id', activity, env=service_env)['paneId'] == origin
    eventually('service origin focus', lambda: focus_is(origin))

    # Self-declared actors remain supported. A home alone is never sufficient for navigation.
    claimed_origin = dict(instanceId=instance, sessionId=session)
    invalid_actors = [
        dict(name='external'),
        dict(name='legacy', home=origin),
        dict(name='missing', home='p999', origin=claimed_origin),
        dict(name='old-session', home=origin, origin=dict(instanceId=instance, sessionId='stale-session')),
        dict(name='foreign-app', home=origin, origin=dict(instanceId='foreign-app', sessionId=session)),
        dict(name='not-terminal', home=controller, origin=claimed_origin),
    ]
    command('pane.focus', pane=target)
    for actor in invalid_actors:
        item = app.rpc('presence.hold', pane=target, ttlSeconds=300, request_metadata=dict(version=1, actor=actor))
        assert listed(item['activityId'])['canFocus'] is False
        before = app.rpc('workspace.get')
        assert app.rpc('presence.focus', activityId=item['activityId']) == dict(focused=False)
        assert app.rpc('workspace.get') == before
        eventually('disabled pill visible', lambda: any(t['id'] == item['activityId'] and t['shown'] for t in shown(target)))
        assert app.rpc('debug.presenceClick', pane=target, activityId=item['activityId'])['clicked']
        assert app.rpc('workspace.get') == before
        assert focus_is(target), actor
    assert app.rpc('presence.focus', activityId='missing-activity') == dict(focused=False)

    # Current membership, not the origin's captured tab/window, determines navigation.
    move_snapshot = app.rpc('workspace.snapshot')
    move_origin = inspect(origin)
    command('pane.move', pane=origin, tab=move_origin['tabId'], target=target, direction='left',
            expectedLayoutRevision=move_origin['layoutRevision'], expectedWorkspaceRevision=move_snapshot['workspaceRevision'])
    assert inspect(origin)['windowId'] != origin_window and inspect(origin)['sessionId'] == session
    command('pane.zoom', pane=target)
    assert app.rpc('presence.focus', activityId=activity)['windowId'] == inspect(target)['windowId']
    eventually('moved/zoomed origin focused', lambda: focus_is(origin) and inspect(origin)['visible'])
    command('pane.focus', pane=target)
    assert app.rpc('debug.commandPicker', show=True)['visible']
    assert app.rpc('presence.focus', activityId=activity)['focused']
    assert not app.rpc('debug.commandPicker')['visible']
    eventually('origin focused after picker dismissal', lambda: focus_is(origin))

    # Replacing a terminal invalidates old activity permanently, including later same-slot shells.
    command('pane.type', pane=origin, type='private-browser', force=True)
    command('pane.type', pane=origin, type='terminal', force=True)
    replacement = inspect(origin)['sessionId']
    assert replacement != session
    command('pane.focus', pane=target)
    before = app.rpc('workspace.get')
    assert app.rpc('presence.focus', activityId=activity) == dict(focused=False)
    assert app.rpc('workspace.get') == before
    assert not listed(activity)['canFocus']
    # A fresh call from the old environment must not rebind an old origin to the replacement.
    assert app.cli('presence', 'hold', '--pane', target, env=env)['activityId'] == activity
    assert app.rpc('presence.focus', activityId=activity) == dict(focused=False)
    new_env = dict(env, SLATE_TERM_SESSION_ID=replacement)
    fresh = app.cli('presence', 'hold', '--pane', target, '--ttl', '300', env=new_env)['activityId']
    assert fresh != activity and listed(fresh)['canFocus']
    assert app.rpc('presence.focus', activityId=fresh)['paneId'] == origin
    command('pane.close', pane=origin, force=True)
    before = app.rpc('workspace.get')
    assert app.rpc('presence.focus', activityId=fresh) == dict(focused=False)
    assert app.rpc('workspace.get') == before
    app.rpc('plugins.service.stop', id='presence.service')
print('presence focus routing, native/CLI/page/service parity and stale-origin checks ok')
