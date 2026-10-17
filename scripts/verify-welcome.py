#!/usr/bin/env python3
"""One owned app plus one restart: real surfaces, explicit state and trusted clients.
No installs/user startup edits; bash uses a temporary no-startup-files test launcher.
"""
import json
import subprocess
import shlex
import sys
import time
from api_fixture import APP, CLI, ROOT, AppFixture, eventually
from plugin_package_fixture import package_fixture

with AppFixture('welcome', '[terminal]\nshell="/bin/zsh"\nshell_integration="off"\n[keybind]\n"cmd+shift+r"="welcome.reset"\n') as app:
    def command(id, **params):
        return app.rpc('command.run', id=id, **params)

    def native(pane='p1'):
        return next(p for p in app.rpc('debug.inspect')['panes'] if p['paneId'] == pane)

    def welcome_events(cursor):
        return app.rpc('events.poll', after=cursor, topics=['host.welcome.changed'], scope='global', waitMilliseconds=0)['events']

    descriptor = app.rpc('api.describe')
    assert 'welcome.get' in descriptor['methods']
    assert descriptor['welcome']['shellIntegrationRequired'] is False
    assert descriptor['welcome']['unreadCommand'] == 'welcome.unread'
    commands = {c['id']: c for c in app.rpc('command.list')}
    assert {'welcome.read', 'welcome.unread', 'welcome.reset'} <= commands.keys()
    initial = app.rpc('welcome.get')
    assert initial['acknowledged'] is False and initial['automaticDisplayEnabled']
    assert app.cli('welcome') == initial
    plain = subprocess.run([str(CLI), 'welcome'], env=app.env, text=True, capture_output=True, timeout=15)
    assert plain.returncode == 0 and plain.stdout == '\n\n'.join([initial['content']['title']] + initial['content']['paragraphs']) + '\n', plain
    app.cli('rpc', 'api.describe')
    assert app.rpc('welcome.get') == initial, 'Reading welcome or an unrelated CLI command acknowledged it'
    assert not (app.root / 'state/welcome.json').exists()
    command('pane.focus', pane='p1')
    eventually('native welcome', lambda: native()['welcomeVisible'])
    before = native()
    session = app.rpc('pane.inspect', pane='p1')['sessionId']
    assert before['firstResponder']
    app.rpc('terminal.send', pane='p1', text='clear\r')
    assert native()['welcomeVisible'], 'Terminal clear dismissed native welcome'
    app.rpc('debug.screenshot', path=str(ROOT / 'artifacts/welcome-real-initial.png'))

    # Press the actual native control with another pane focused. Insertion is
    # literal input at the cursor, not execution, acknowledgement or draft replacement.
    read_command = 'slate-term welcome --read'
    other = command('split.right', pane='p1')['paneId']
    for pane in ['p1', other]:
        eventually('shell ready for insert', lambda pane=pane: 'API_TEST>' in app.rpc('terminal.capture', pane=pane)['text'])
    other_text = app.rpc('terminal.capture', pane=other)['text']
    app.rpc('debug.welcomeInsert', pane='p1')
    eventually('native button inserts', lambda: read_command in app.rpc('terminal.capture', pane='p1')['text'])
    assert app.rpc('terminal.capture', pane='p1')['text'].strip().endswith(read_command), 'Button submitted instead of inserting'
    assert app.rpc('terminal.capture', pane=other)['text'] == other_text, 'Input went to the focused sibling'
    assert native()['firstResponder'] and native()['surface'] == before['surface']
    assert app.rpc('welcome.get') == initial and native()['welcomeVisible']
    app.rpc('terminal.key', pane='p1', key='ctrl+u')
    app.rpc('terminal.send', pane='p1', text='echo ')
    app.rpc('debug.welcomeInsert', pane='p1')
    eventually('insert preserves draft', lambda: 'echo ' + read_command in app.rpc('terminal.capture', pane='p1')['text'])
    assert app.rpc('welcome.get') == initial
    app.rpc('terminal.key', pane='p1', key='ctrl+u')
    # The second native play button opens the real interactive installer, still
    # using the same isolated skill operations as Settings and parameterized CLI.
    command('pane.focus', pane=other)
    app.rpc('debug.welcomeInsert', pane='p1', skillSetup=True)
    eventually('skill button inserts', lambda: app.rpc('terminal.capture', pane='p1')['text'].strip().endswith('slate-term skill setup'))
    assert app.rpc('terminal.capture', pane=other)['text'] == other_text
    assert native()['firstResponder'] and app.rpc('welcome.get') == initial
    app.rpc('terminal.send', pane='p1', text='\r')
    eventually('interactive agent selection', lambda: 'Enter to cancel' in app.rpc('terminal.capture', pane='p1')['text'])
    app.rpc('terminal.send', pane='p1', text='1, 2\r')
    eventually('interactive install confirmation', lambda: 'Install? [y/N]:' in app.rpc('terminal.capture', pane='p1')['text'])
    assert all(agent['status'] == 'notInstalled' for agent in app.rpc('skills.list')['agents'])
    time.sleep(0.3)  # Allow the compositor to present the confirmation already observed in capture.
    app.rpc('debug.screenshot', path=str(ROOT / 'artifacts/welcome-skill-setup.png'))
    app.rpc('terminal.send', pane='p1', text='y\r')
    eventually('interactive install completes', lambda: 'Skill installed for' in app.rpc('terminal.capture', pane='p1')['text'])
    statuses = {agent['id']: agent['status'] for agent in app.rpc('skills.list')['agents']}
    assert statuses['agents'] == statuses['claude'] == 'installed' and statuses['codex'] == 'notInstalled', statuses
    assert app.rpc('welcome.get') == initial and native()['welcomeVisible'], 'Skill setup acknowledged welcome'
    command('pane.close', pane=other, force=True)
    before = native()

    cursor = app.rpc('events.head')['cursor']
    app.rpc('welcome.get', unexpected=True, error=-32602)
    app.rpc('command.run', id='welcome.read', expectedInstanceId='stale', error=-32050)
    app.rpc('command.run', id='welcome.read', pane='p1', error=-32602)
    # A failing private write cannot dismiss content or claim acknowledgement.
    preference = app.root / 'state/welcome.json'
    preference.mkdir()
    failed = app.cli('welcome', '--read', error=True)
    assert failed['code'] == -32054 and failed['data']['persisted'] is False, failed
    assert app.rpc('welcome.get') == initial and native()['welcomeVisible']
    assert not welcome_events(cursor)
    preference.rmdir()

    # Actual Cmd-K/native dispatch, not a second test-only implementation.
    shown = app.rpc('debug.commandPicker', show=True, query='Mark Welcome Message as Read')
    assert shown['selected'] == 'welcome.read', shown
    assert shown['results'][0]['title'] == 'Mark Welcome Message as Read', shown
    app.rpc('debug.commandPicker', clickRow=0)  # first click selects
    app.rpc('debug.commandPicker', clickRow=0, doubleClick=True)
    eventually('native acknowledgement', lambda: app.rpc('welcome.get')['acknowledged'])
    eventually('welcome removed', lambda: not native()['welcomeVisible'])
    app.rpc('debug.welcomeInsert', pane='p1', error=-32051)
    after = native()
    assert after['surface'] == before['surface'] and app.rpc('pane.inspect', pane='p1')['sessionId'] == session
    assert after['height'] > before['height'] and after['firstResponder'], (before, after)
    events = welcome_events(cursor)
    assert len(events) == 1 and events[0]['payload']['acknowledged'] is True, events
    unchanged = app.cli('welcome', '--read')
    assert unchanged['changed'] is False and len(welcome_events(cursor)) == 1
    # External changes refresh a picker already on screen; the hidden reset alias
    # still works as a configured shortcut while that picker owns the keyboard.
    def picker_ids():
        return {row['id'] for row in app.rpc('debug.commandPicker')['results']}
    app.rpc('debug.activate', tab=app.rpc('pane.inspect', pane='p1')['tabId'])
    app.rpc('debug.commandPicker', show=True, query='Welcome')
    assert picker_ids() == {'welcome.unread'}
    app.cli('welcome', '--unread')
    assert picker_ids() == {'welcome.read'}
    app.cli('welcome', '--read')
    assert picker_ids() == {'welcome.unread'}
    shortcut_state = app.rpc('debug.commandPicker')
    shortcut_verified = shortcut_state['keyWindow'] and shortcut_state['applicationActive']
    if shortcut_verified:
        app.rpc('debug.key', chord='cmd+shift+r', picker=True, dispatch=True)
        eventually('reset alias shortcut in picker', lambda: not app.rpc('welcome.get')['acknowledged'])
        assert not app.rpc('debug.commandPicker')['visible']
    else:
        print('UNVERIFIED picker shortcut: macOS did not activate the owned picker; no keyboard event dispatched', flush=True)
        app.rpc('debug.commandPicker', dismiss=True)
    app.cli('welcome', '--read')
    app.rpc('debug.screenshot', path=str(ROOT / 'artifacts/welcome-real-dismissed.png'))
    sibling = command('split.right', pane='p1')['paneId']
    assert not native(sibling)['welcomeVisible']
    unread = app.cli('welcome', '--unread')
    reset = command('welcome.reset')
    assert reset['changed'] is False and reset['revision'] == unread['revision'], 'Reset diverged from unread'
    assert not native()['welcomeVisible'] and not native(sibling)['welcomeVisible'], 'Reset reopened an existing welcome'
    future = command('split.down', pane='p1')['paneId']
    eventually('reset applies to next terminal', lambda: native(future)['welcomeVisible'])
    future_surface = native(future)['surface']
    command('pane.zoom', pane=future)
    assert native(future)['welcomeVisible'] and native(future)['surface'] == future_surface
    command('pane.zoom', pane=future)
    app.rpc('debug.windowGeometry', pane=future, width=640, height=600)
    assert native(future)['welcomeVisible'] and native(future)['height'] > 80
    app.rpc('debug.windowGeometry', pane=future, width=900, height=650)
    assert native(future)['surface'] == future_surface

    # Registered page convenience helpers reach the same global operation without
    # inheriting its own pane target, while retaining document/caller validation.
    assets = app.root / 'welcome-panel'
    assets.mkdir()
    (assets / 'index.html').write_text('<!doctype html><title>Welcome fixture</title>')
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='welcome.fixture', title='Welcome fixture', source=dict(kind='directory', path=str(assets))), app.root))
    command('pane.type', pane=sibling, type='welcome.fixture', force=True)
    def js(source):
        return app.rpc('debug.pluginEval', pane=sibling, script=source)
    eventually('welcome bridge', lambda: js('typeof workspace') == 'object')
    assert js('await workspace.welcome.get()') == app.rpc('welcome.get')
    assert js('workspace.methods.includes("welcome.get")')
    assert native(future)['surface'] == future_surface and native(future)['welcomeVisible']
    read = js('await workspace.welcome.read()')
    assert read['acknowledged'] and read['persisted'] and not native(future)['welcomeVisible']
    assert js('await workspace.welcome.unread()')['acknowledged'] is False
    assert js('await workspace.welcome.reset()')['changed'] is False

    # A real managed service's bound socket, used via the same CLI adapter.
    worker = app.root / 'welcome-service.py'
    context_path = app.root / 'service-context.json'
    worker.write_text('''import json,os,pathlib,subprocess,time
keys=['SLATE_TERM_SOCKET','SLATE_TERM_INSTANCE_ID','SLATE_TERM_SERVICE_PLUGIN_ID','SLATE_TERM_SERVICE_ID','SLATE_TERM_SERVICE_GENERATION']
pathlib.Path(os.environ['CONTEXT_PATH']).write_text(json.dumps({k:os.environ[k] for k in keys}))
subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc','service.ready','--params','{"version":1}'],check=True)
while True: time.sleep(1)
''')
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='welcome.service', title='Welcome service', service=dict(executable=sys.executable,
        arguments=[str(worker)], environment=dict(CONTEXT_PATH=str(context_path)), readyTimeoutSeconds=10)), app.root))
    app.rpc('plugins.service.start', id='welcome.service')
    eventually('welcome service', lambda: app.rpc('plugins.service.status', id='welcome.service')['state'] == 'ready')
    service_env = dict(app.env, **json.loads(context_path.read_text()))
    assert app.cli('welcome', env=service_env) == app.rpc('welcome.get')
    assert app.cli('welcome', '--read', env=service_env)['acknowledged'] is True
    assert app.cli('welcome', '--unread', env=service_env)['acknowledged'] is False
    assert app.cli('welcome', '--reset', env=service_env)['changed'] is False
    app.rpc('plugins.service.stop', id='welcome.service')

    # Neither automatic nor host shell integration supplies the welcome. Test a
    # second shell without reading/writing any real bash startup/history files.
    shell = app.root / 'clean-bash'
    shell.write_text('#!/bin/sh\nexport HISTFILE=/dev/null\nexec /bin/bash --noprofile --norc -i\n')
    shell.chmod(0o700)
    app.config.write_text('[terminal]\nshell=' + json.dumps(str(shell)) + '\nshell_integration="off"\n')
    app.rpc('config.reload')
    bash_pane = command('split.down', pane='p1')['paneId']
    eventually('bash native welcome', lambda: native(bash_pane)['welcomeVisible'])
    bash_session = app.rpc('pane.inspect', pane=bash_pane)['sessionId']
    app.rpc('terminal.send', pane=bash_pane, text='printf "BASH_WELCOME_CHECK_%s\\n" "$BASH_VERSION"\r')
    eventually('bash is live', lambda: 'BASH_WELCOME_CHECK_3.' in app.rpc('terminal.capture', pane=bash_pane)['text'])
    app.rpc('terminal.send', pane=bash_pane, text=shlex.quote(str(CLI)) + ' welcome --read\r')
    eventually('CLI acknowledgement from live bash', lambda: app.rpc('welcome.get')['acknowledged'])
    assert not native(bash_pane)['welcomeVisible']
    assert app.rpc('pane.inspect', pane=bash_pane)['sessionId'] == bash_session
    assert json.loads(preference.read_text()) is True and preference.stat().st_mode & 0o777 == 0o600

    # One restart of the same owned app/state root verifies persisted dismissal.
    app.process.terminate()
    app.process.wait(timeout=10)
    app.ready.unlink(missing_ok=True)
    launch_env = dict(app.env)
    launch_env.pop('SLATE_TERM_SOCKET', None)
    app.process = subprocess.Popen([str(APP)], env=launch_env, stdout=app.log, stderr=app.log, start_new_session=True)
    eventually('restarted owned app', lambda: app.ready.exists() and app.process.poll() is None)
    app.path = app.ready.read_text().strip()
    app.env['SLATE_TERM_SOCKET'] = app.path
    assert app.cli('welcome')['acknowledged'] is True
    assert all(not pane['welcomeVisible'] for pane in app.rpc('debug.inspect')['panes'])
    app.cli('welcome', '--reset')
    new_pane = command('split.right', pane='p1')['paneId']
    eventually('reset after restart', lambda: native(new_pane)['welcomeVisible'])

print('PASS welcome: same-pane command insertion without submission/draft loss, native/CLI/page/service parity, isolated restart persistence, explicit read/unread/reset/no-ops, write failure, stale guards, retained surface/focus/geometry, zsh and bash with integration off; picker shortcut verified:', shortcut_verified)
