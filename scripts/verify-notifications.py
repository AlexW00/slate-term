#!/usr/bin/env python3
"""One owned app: notification policy, trusted clients, engine callbacks and native source indicators.
Native Notification Center is replaced by the owned integration backend; no permission prompts.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import sys
import struct
import time
from api_fixture import AppFixture, ROOT, eventually

configuration = '''[terminal]
shell = "/bin/zsh"
[notifications]
minimum_seconds = 1
banners = "off"
'''

with AppFixture('notifications', configuration) as app:
    def listing():
        return app.rpc('notifications.list')

    def clear():
        app.rpc('notifications.dismiss', all=True)

    def patch(**values):
        current = app.rpc('config.get')
        app.rpc('config.patch', expectedSourceRevision=current['sourceRevision'],
                values={'notifications.' + k: v for k, v in values.items()})

    def post(title, **params):
        # Stay within the documented per-source budget outside the explicit flood test.
        time.sleep(1.02)
        return app.rpc('notifications.post', title=title, **params)

    describe = app.rpc('api.describe')
    assert describe['notifications']['capacity'] == 100 and not describe['notifications']['persistent']
    assert not describe['notifications']['submissionIsDelivery']
    assert all('notifications.' + action in describe['methods'] for action in ['post', 'list', 'dismiss', 'status'])
    status = app.cli('notifications', 'status')
    assert status['policy']['sound'] is False and status['policy']['tools'] is True
    assert status['deliveryBackend'] == 'test'
    source = 'p1'
    original_session = app.rpc('pane.inspect', pane=source)['sessionId']
    original_tab = app.rpc('pane.inspect', pane=source)['tabId']
    # Establish the required initial shell state before starting another native window.
    # Socket readiness alone does not mean the first authenticated prompt arrived.
    eventually('source shell prompt', lambda: app.rpc('pane.inspect', pane=source)['state'] == 'prompt')
    target_tab = app.rpc('command.run', id='tab.new')['tabId']
    active = app.rpc('context.get')['focusedPaneId']

    for invalid in [dict(title=''), dict(title='x' * 257), dict(title='x', body='x' * 4097),
                    dict(title='x', key=''), dict(title='x', body=None), dict(title='x', source={'kind': 'native'}),
                    dict(title='x', action='sh'), dict(title='x', active=True, pane=source),
                    dict(title='x', pane=source, tab=target_tab)]:
        app.rpc('notifications.post', error=-32602, **invalid)
    app.rpc('notifications.post', title='stale', pane=source, expectedAnchorSessionId='stale', error=-32050)
    app.rpc('notifications.post', title='wrong app', expectedInstanceId='stale', error=-32050)

    first = post('Tests passed', pane=source, body='248 completed', key='build')
    assert first['retained'] and first['reason'] == 'bannersDisabled', first
    second = post('Tests passed again', pane=source, key='build')
    assert second['id'] != first['id'] and len(listing()) == 1
    assert listing()[0]['source']['kind'] == 'administrative'
    assert app.rpc('pane.inspect', pane=source)['unreadNotificationCount'] == 1
    assert app.rpc('debug.notifications')['tabTitles'][original_tab].startswith('●')
    app.rpc('command.run', id='tab.title.set', tab=original_tab, title='Builds')
    assert app.rpc('debug.notifications')['tabTitles'][original_tab] == '● Builds'
    app.rpc('command.run', id='tab.title.set', tab=original_tab, title='Builds renamed')
    assert app.rpc('debug.notifications')['tabTitles'][original_tab] == '● Builds renamed'
    first_cursor = app.rpc('events.head')['cursor']
    app.cli('notifications', 'dismiss', '--id', second['id'])
    assert not listing()
    assert app.rpc('debug.notifications')['tabTitles'][original_tab] == 'Builds renamed'
    events = app.rpc('events.poll', after=first_cursor, topics=['host.notifications.changed'], waitMilliseconds=0)['events']
    assert events and 'Tests passed' not in json.dumps(events)

    inherited = dict(app.env, SLATE_TERM_PANE_ID=source, SLATE_TERM_TAB_ID=original_tab,
                     SLATE_TERM_SESSION_ID=original_session, SLATE_TERM_INSTANCE_ID=describe['appInstanceId'])
    time.sleep(1.02)
    sent = app.cli('notify', '--title', 'CLI anchored', env=inherited)
    assert sent['retained'] and listing()[0]['anchor']['paneId'] == source
    app.cli('notify', '--title', 'wrong session', '--session-id', 'old', env=inherited, error=True)
    clear()

    # Native completion is independent of the authenticated shell-report channel.
    run = app.rpc('terminal.run', pane=source, command='sleep 1.2; false')
    assert run['exitCode'] == 1
    eventually('one automatic failed completion', lambda: len([n for n in listing() if n['automatic']]) == 1)
    automatic = listing()[0]
    assert automatic['title'] == 'Command failed (exit 1)' and 'sleep' not in automatic['body']
    assert automatic['source']['protocol'] == 'commandFinished'
    time.sleep(.2)
    assert len(listing()) == 1, 'Engine/shell reports duplicated completion'
    clear()
    app.rpc('terminal.run', pane=source, command='true')
    time.sleep(.15)
    assert not listing(), 'Short command notified'
    patch(automatic=False)
    app.rpc('terminal.run', pane=source, command='sleep 1.2')
    assert not listing(), 'Disabled completion notified'
    patch(automatic=True)

    for protocol, command in [
        ('OSC 9', r"printf '\033]9;OSC nine fixture\007'"),
        ('OSC 777', r"printf '\033]777;notify;OSC title;OSC body\007'")]:
        time.sleep(1.05)  # Ghostty independently admits at most one OSC notification per second.
        app.rpc('terminal.run', pane=source, command=command)
        eventually(protocol, lambda: bool(listing()))
        assert len(listing()) == 1 and listing()[0]['source']['protocol'] == 'OSC', listing()
        assert 'OSC' in listing()[0]['body'] or 'OSC' in listing()[0]['title']
        clear()

    # Delivery authorization and failure are not reported as a displayed notification.
    patch(banners='other_panes')
    for authorization, reason in [('denied', 'permissionDenied'), ('notDetermined', 'permissionNotGranted')]:
        app.rpc('debug.notifications', authorization=authorization)
        result = post('Permission fixture', pane=source)
        assert result['disposition'] == 'suppressed' and result['reason'] == reason and result['retained']
        clear()
    app.rpc('debug.notifications', authorization='authorized')
    result = post('Submitted fixture', pane=source)
    assert result['disposition'] == 'submitted' and result['reason'] is None
    clear()
    app.rpc('debug.notifications', submissionSucceeds=False)
    post('Native failure fixture', pane=source)
    assert listing()[0]['disposition'] == 'failed' and listing()[0]['reason'] == 'nativeSubmissionFailed'
    clear()
    app.rpc('debug.notifications', submissionSucceeds=True)
    patch(tools=False)
    result = post('Disabled tools', pane=source)
    assert not result['retained'] and result['reason'] == 'toolsDisabled'
    patch(tools=True, banners='off')

    # A bridge and a service use the same catalog and operations, with host-assigned sources.
    assets = app.root / 'panel'
    assets.mkdir()
    (assets / 'index.html').write_text('<!doctype html><title>Notification fixture</title><p>Notification API fixture</p>')
    app.rpc('plugins.register', manifest=dict(id='notification.fixture', title='Notification fixture', scope='global',
        source=dict(kind='directory', path=str(assets))))
    app.rpc('command.run', id='pane.type', pane=active, type='notification.fixture', force=True)
    def js(script):
        return app.rpc('debug.pluginEval', pane=active, script=script)
    eventually('notification bridge', lambda: js('typeof workspace') == 'object')
    assert js('Object.keys(workspace.notifications).sort()') == ['dismiss', 'list', 'post', 'status']
    bridge = js("await workspace.notifications.post({title:'Bridge fixture',pane:'p1'})")
    assert bridge['retained'] and listing()[0]['source']['kind'] == 'plugin'
    assert js('await workspace.notifications.list()') == listing()
    js('await workspace.notifications.dismiss({all:true})')
    assert not listing()
    worker = app.root / 'notification-service.py'
    worker.write_text('''import json,os,pathlib,subprocess,time
root=pathlib.Path(os.environ['TEST_ROOT'])
context={k:v for k,v in os.environ.items() if k.startswith('SLATE_TERM_')}
path=root/'service-context.json'; path.write_text(json.dumps(context)); path.chmod(0o600)
subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc','service.ready','--params','{"version":1}','--json'],check=True)
while True:time.sleep(1)
''')
    app.rpc('plugins.register', manifest=dict(id='notification.service', title='Notification service',
        service=dict(executable=sys.executable, arguments=[str(worker)], environment={'TEST_ROOT': str(app.root)})))
    app.rpc('plugins.service.start', id='notification.service')
    eventually('notification service ready', lambda: app.rpc('plugins.service.status', id='notification.service')['state'] == 'ready')
    service_env = dict(app.env, **json.loads((app.root / 'service-context.json').read_text()))
    service = app.cli('notify', '--title', 'Service fixture', '--pane', source, env=service_env)
    assert service['retained'] and listing()[0]['source']['kind'] == 'service'
    assert app.cli('notifications', 'list', env=service_env) == listing()
    app.cli('notifications', 'dismiss', '--all', env=service_env)
    app.rpc('plugins.service.stop', id='notification.service')

    # One pending submission must not retarget a replacement terminal in the same pane slot.
    app.rpc('debug.notifications', delayMilliseconds=1200)
    inspection_count = app.rpc('debug.notifications')['authorizationInspections']
    with concurrent.futures.ThreadPoolExecutor(max_workers=41) as pool:
        pending = pool.submit(app.rpc, 'notifications.post', title='Must not follow replacement', pane=source)
        eventually('pending notification authorization', lambda: app.rpc('debug.notifications')['pending'] == 1)
        statuses = [pool.submit(app.rpc, 'notifications.status') for _ in range(40)]
        time.sleep(.15)
        assert app.rpc('debug.notifications')['authorizationInspections'] == inspection_count + 1, 'Status queries bypassed shared authorization coalescing'
        app.rpc('command.run', id='pane.type', pane=source, type='browser', force=True)
        app.rpc('command.run', id='pane.type', pane=source, type='terminal', force=True)
        try:
            pending.result(timeout=4)
            raise AssertionError('A pending notification followed a replacement session')
        except AssertionError as error:
            assert 'source was closed or replaced' in str(error), error
        for status_result in statuses:
            assert status_result.result(timeout=4)['authorization'] == 'authorized'
    app.rpc('debug.notifications', delayMilliseconds=0)
    assert app.rpc('pane.inspect', pane=source)['sessionId'] != original_session
    assert not listing()
    assert app.cli('notify', '--title', 'Old inherited session', env=inherited, error=True)['code'] == -32050

    # Bring the owned source forward once through the production click operation before captures.
    initial_open = post('Open source fixture', pane=source)
    assert app.cli('notifications', 'open', '--id', initial_open['id'])['opened']
    app.rpc('command.run', id='notifications.settings')
    time.sleep(.5)
    # Use a newly created, nonfocused split source: OS activation can leave the
    # original source selected even after Settings was requested. Never fake focus.
    revision = app.rpc('pane.inspect', pane=source)['layoutRevision']
    source = app.rpc('command.run', id='pane.split', pane=source, direction='right', target='pane',
                     focus='preserve', expectedLayoutRevision=revision)['paneId']
    # Source indicators are visible without native permission, even when chrome is hidden.
    app.rpc('command.run', id='pane.title.set', pane=source, title='Build terminal')
    unread = post('Unread build', pane=source)
    assert unread['retained'], unread
    app.rpc('command.run', id='pane.header.hide', pane=source)
    assert app.rpc('pane.inspect', pane=source)['unreadNotificationCount'] == 1
    assert app.rpc('debug.notifications')['tabTitles'][original_tab].startswith('●')
    app.rpc('command.run', id='pane.header.show', pane=source)
    screenshots = ROOT / 'artifacts'
    def capture(name, settings=False):
        path = screenshots / ('notifications-' + name + '.png')
        app.rpc('debug.screenshot', settings=settings, path=str(path))
        width, height = struct.unpack('>II', path.read_bytes()[16:24])
        if width < 800 or height < 500:
            print('UNVERIFIED composited capture ' + name + ': OS supplied a thumbnail; saving AppKit view evidence separately', flush=True)
            app.rpc('debug.screenshot', settings=settings, renderContent=True,
                    path=str(screenshots / ('notifications-' + name + '-view.png')))
    capture('tabs')
    app.rpc('command.run', id='appearance.light')
    app.rpc('debug.settings', section='Notifications', width=1060, height=680)
    time.sleep(.5)
    capture('settings-light', settings=True)
    app.rpc('debug.notifications', authorization='notDetermined')
    app.rpc('command.run', id='notifications.settings')
    eventually('permission request UI state', lambda: app.rpc('debug.settings', inspectOnly=True)['notificationAuthorization'] == 'notDetermined')
    capture('settings-permission-request', settings=True)
    app.rpc('debug.notifications', authorization='authorized')
    app.rpc('command.run', id='notifications.settings')
    app.rpc('command.run', id='appearance.dark')
    eventually('authorized UI state', lambda: app.rpc('debug.settings', inspectOnly=True)['notificationAuthorization'] == 'authorized')
    time.sleep(.5)
    capture('settings-dark', settings=True)
    app.rpc('command.run', id='appearance.light')
    # The production command is also the native notification-click handler.
    opened = app.cli('notifications', 'open', '--id', listing()[0]['id'])
    assert opened['opened'] and app.rpc('context.get')['focusedPaneId'] == source
    assert not listing() and app.rpc('pane.inspect', pane=source)['unreadNotificationCount'] == 0
    native = app.rpc('debug.notifications')
    viewed = app.rpc('notifications.post', title='Already viewing', pane=source)
    if native['appActive'] and native['keyTab'] == original_tab:
        assert not listing() and viewed['reason'] == 'sourceFocused', 'Focused pane acquired an unread notification'
    else:
        print('UNVERIFIED real foreground suppression: macOS did not activate the owned source window; pure policy checks passed', flush=True)
        clear()
    app.rpc('command.run', id='tab.focus', tab=target_tab)
    next_record = post('Next unread application')
    assert next_record['retained'], next_record
    assert app.cli('notifications', 'next')['opened'] is True and not listing()
    app.rpc('command.run', id='notifications.settings')
    result = post('Closed source', pane='p1')
    assert result['retained'], result
    app.rpc('command.run', id='pane.close', pane='p1', force=True)
    assert not listing()
    app.rpc('command.run', id='notifications.open', notificationId=result['id'], error=-32051)
    assert app.cli('notifications', 'next')['opened'] is False
    print('PASS notification bounds/policy, CLI/bridge/service parity, authorization/submission semantics, real Ghostty completion + OSC 9/777, replacement race, unread/source navigation and settings captures')
