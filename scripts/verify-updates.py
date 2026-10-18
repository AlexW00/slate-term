#!/usr/bin/env python3
"""VM-only native update consent, reading continuity, and trusted-client parity.

The owned fixture supplies transport outcomes. Production actions, native controls,
quit confirmations, and client routing remain real; no release is installed.
"""
import json
import sys
import time

from api_fixture import AppFixture, ROOT, eventually
from plugin_package_fixture import package_fixture


with AppFixture('updates', '[terminal]\nshell="/bin/zsh"\n') as app:
    app.capture_contracts()
    def debug(**params):
        return app.rpc('debug.updates', **params)

    def snapshot():
        return app.rpc('updates.get')

    def fixture(phase):
        debug(phase=phase)
        shown = app.rpc('updates.show')
        assert shown['phase'] == phase and shown['windowVisible'], shown
        return shown

    def phase_is(phase):
        return snapshot()['phase'] == phase

    def events(after):
        return app.rpc('events.poll', after=after, topics=['host.updates.changed'],
                       scope='global', waitMilliseconds=0)['events']

    def press(control):
        return debug(operation='press', control='updates.' + control)

    def assert_unarmed(before, state=None):
        state = state or debug()
        assert state['installReplies'] == before, state
        return state

    def expect_origin(after, kind):
        changes = events(after)
        assert changes and changes[-1]['payload']['origin']['kind'] == kind, changes
        for change in changes:
            payload = change['payload']
            assert 'revision' in payload and 'phase' in payload, change
            assert not {'notes', 'signature', 'downloadURL', 'release'} & payload.keys(), change
        return changes

    def terminal_busy():
        return next(p for p in app.rpc('debug.inspect')['panes'] if p['paneId'] == 'p1')['needsConfirmClose']

    descriptor = app.rpc('api.describe')
    methods = {'updates.' + action for action in ['get', 'show', 'check', 'download', 'cancel', 'install']}
    assert methods <= set(descriptor['methods']), descriptor
    assert descriptor['updates']['scope'] == 'application'
    assert descriptor['updates']['automaticInstallation'] is False
    assert descriptor['updates']['installationRequiresConfirmation'] is True
    assert descriptor['updates']['eventTopic'] == 'host.updates.changed'
    commands = {command['id']: command for command in app.rpc('command.list')}
    assert {name for name in commands if name.startswith('updates.')} == {'updates.show', 'updates.check'}
    assert all(commands[name]['contract']['workspaceIndependent'] and not commands[name]['contract']['requiresArguments']
               for name in ['updates.show', 'updates.check'])
    before = snapshot()
    assert app.cli('updates', 'get') == before == snapshot(), 'Reading update state changed the update'
    assert before['phase'] == 'unavailable', 'The unprovisioned fixture must fail closed'
    assert app.rpc('command.run', id='updates.check')['phase'] == 'unavailable'
    debug(operation='hide')
    assert app.rpc('command.run', id='updates.show')['windowVisible']
    def menu_commands(items):
        return [item.get('command') for item in items] + [value for item in items for value in menu_commands(item.get('children', []))]
    assert 'updates.check' in menu_commands(app.rpc('debug.menuTree'))

    # No install choice may be issued by a fresh check, download, verification, or dismiss.
    for phase in ['available', 'downloading', 'verifying', 'ready', 'downloadError', 'verificationError', 'checkError']:
        state = fixture(phase)
        count = debug()['installReplies']
        callback = debug(operation='readyCallback')
        assert callback['readyChoices'][-1] == 'skip', callback
        assert_unarmed(count, callback)
        assert callback['phase'] == phase
        debug(operation='hide')
        assert not snapshot()['windowVisible']
        reopened = app.rpc('updates.show')
        assert reopened['phase'] == phase and reopened['updateId'] == state['updateId']
        assert_unarmed(count)
    ready = fixture('ready')
    count = debug()['installReplies']
    time.sleep(0.3)
    debug(screenshot=str(ROOT / 'artifacts/updates-initial-ready.png'))
    press('secondary')  # The actual Later button only hides the window.
    eventually('Later hides the update window', lambda: not snapshot()['windowVisible'])
    assert snapshot()['phase'] == 'ready'
    app.rpc('updates.show')
    debug(operation='close')  # Native close-button delegate, not a second state transition.
    assert not snapshot()['windowVisible'] and snapshot()['updateId'] == ready['updateId']
    assert_unarmed(count)
    app.rpc('updates.show')

    # Required consent and current-session identities are checked before any mutation.
    ready = fixture('ready')
    count = debug()['installReplies']
    cursor = app.rpc('events.head')['cursor']
    for params in [dict(), dict(updateId=ready['updateId']), dict(updateId=None, confirm=True),
                   dict(updateId=ready['updateId'], confirm=False), dict(updateId=ready['updateId'], confirm='true'),
                   dict(updateId=ready['updateId'], confirm=1), dict(updateId=ready['updateId'], confirm=True, pane='p1'),
                   dict(updateId=ready['updateId'], confirm=True, expectedDocumentId='unsupported')]:
        app.rpc('updates.install', error=-32602, **params)
    app.rpc('updates.install', updateId=ready['updateId'], confirm=True, expectedInstanceId='stale', error=-32050)
    assert app.cli('updates', 'install', '--update-id', ready['updateId'], error=True)['code'] == -32602
    assert snapshot() == ready and not events(cursor)
    previous_id = ready['updateId']
    replacement = fixture('ready')
    assert replacement['updateId'] != previous_id
    for action in ['download', 'cancel', 'install']:
        params = dict(updateId=previous_id)
        if action == 'install':
            params['confirm'] = True
        app.rpc('updates.' + action, error=-32050, **params)
    assert snapshot() == replacement
    assert_unarmed(count)

    # Scroll and focus the actual NSTextView once, then keep reading through progress.
    available = fixture('available')
    eventually('native release notes', lambda: debug(operation='notesProbe').get('notesLength', 0) > 500)
    debug(operation='more')
    eventually('continuation scrolls and focuses release notes',
               lambda: debug(operation='notesProbe').get('notesOffset', 0) > 0 and debug(operation='notesProbe')['notesFocused'])
    reading = debug(operation='notesProbe')
    count = reading['installReplies']
    cursor = app.rpc('events.head')['cursor']
    downloading = app.rpc('updates.download', updateId=available['updateId'])
    assert downloading['phase'] == 'downloading'
    expect_origin(cursor, 'administrative')

    def same_reading():
        current = debug(operation='notesProbe')
        assert current['updateId'] == available['updateId'], current
        assert current['notesLength'] == reading['notesLength'], current
        assert abs(current['notesOffset'] - reading['notesOffset']) <= 1, (reading, current)
        assert current['notesFocused'], current
        assert_unarmed(count, current)

    same_reading()
    cursor = app.rpc('events.head')['cursor']
    debug(operation='progress', receivedBytes=14_000_000)
    assert snapshot()['receivedBytes'] == 14_000_000
    assert not events(cursor), 'Byte progress must not flood the semantic event journal'
    same_reading()
    for phase in ['verifying', 'ready']:
        debug(operation='progress', receivedBytes=24_600_000, nextPhase=phase)
        assert phase_is(phase)
        same_reading()
    app.rpc('updates.cancel', updateId=available['updateId'])
    assert phase_is('available')
    same_reading()

    # Native Download/Cancel and retry controls share the public operations.
    count = debug()['installReplies']
    cursor = app.rpc('events.head')['cursor']
    press('primary')
    eventually('native Download button', lambda: phase_is('downloading'))
    expect_origin(cursor, 'native')
    press('secondary')
    eventually('native Cancel Download button', lambda: phase_is('available'))
    fixture('verifying')
    press('secondary')
    eventually('native verification cancellation', lambda: phase_is('available'))
    fixture('downloadError')
    press('primary')
    eventually('native download retry', lambda: phase_is('downloading'))
    for phase in ['verificationError', 'checkError']:
        fixture(phase)
        press('primary')
        eventually('native check retry', lambda: phase_is('checking'))
    assert_unarmed(count)

    # Release-note failure closes the pending offer; cancel cannot restore that consent.
    state = fixture('available')
    debug(operation='notesFailure')
    assert phase_is('verificationError')
    app.rpc('updates.download', updateId=state['updateId'], error=-32051)
    app.rpc('updates.install', updateId=state['updateId'], confirm=True, error=-32051)
    app.rpc('updates.cancel', updateId=state['updateId'])
    app.rpc('updates.download', updateId=state['updateId'], error=-32051)
    assert_unarmed(count)

    checking = fixture('checking')
    press('secondary')
    eventually('native check cancellation', lambda: phase_is('idle'))
    checking = fixture('checking')
    canceled = app.rpc('updates.cancel', updateId=checking['updateId'])
    assert canceled['phase'] == 'idle'
    debug(operation='lateCheck')
    assert snapshot() == canceled, 'A late check callback revived a canceled update'
    assert_unarmed(count)

    # CLI calls remain app-wide even with stale inherited pane/tab/session context.
    state = fixture('available')
    stale_context = dict(app.env, SLATE_TERM_PANE_ID='p999', SLATE_TERM_TAB_ID='t999', SLATE_TERM_SESSION_ID='old')
    assert app.cli('updates', 'get', env=stale_context) == state
    debug(operation='hide')
    assert app.cli('updates', 'show', env=stale_context)['windowVisible']
    assert app.cli('updates', 'download', '--update-id', state['updateId'], env=stale_context)['phase'] == 'downloading'
    assert app.cli('updates', 'cancel', '--update-id', state['updateId'], env=stale_context)['phase'] == 'available'
    fixture('current')
    assert app.cli('updates', 'check', env=stale_context)['phase'] == 'checking'
    eventually('idle shell before explicit install', lambda: not terminal_busy())
    state = fixture('ready')
    count = debug()['installReplies']
    assert app.cli('updates', 'install', '--update-id', state['updateId'], '--confirm', env=stale_context)['phase'] == 'installing'
    assert debug()['installReplies'] == count + 1
    callback = debug(operation='readyCallback')
    assert callback['readyChoices'][-1] == 'install'
    app.rpc('updates.cancel', updateId=state['updateId'], error=-32051)
    debug(operation='installationCallback')
    assert 'quit' in snapshot()['detail'].lower()
    assert debug()['installReplies'] == count + 1, 'A retry callback started another offer automatically'

    # A registered page uses its ordinary bridge and the same guarded operations.
    assets = app.root / 'updates-panel'
    assets.mkdir()
    (assets / 'index.html').write_text('<!doctype html><title>Updates fixture</title><p>Update API fixture</p>')
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='updates.fixture', title='Updates fixture',
            source=dict(kind='directory', path=str(assets))), app.root))
    panel = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=panel, type='updates.fixture', force=True)

    def js(source):
        return app.rpc('debug.pluginEval', pane=panel, script=source)

    def js_error(expression, code):
        result = js('(async () => { try { await (' + expression + '); return null } catch (error) { return error.code } })()')
        assert result == code, result

    eventually('updates plugin bridge', lambda: js('typeof workspace') == 'object')
    assert methods <= set(js('workspace.methods'))
    state = fixture('available')
    assert js('await workspace.updates.get()') == state
    debug(operation='hide')
    assert js('await workspace.updates.show()')['windowVisible']
    cursor = app.rpc('events.head')['cursor']
    assert js('await workspace.updates.download(' + json.dumps(state['updateId']) + ')')['phase'] == 'downloading'
    expect_origin(cursor, 'plugin')
    assert js('await workspace.updates.cancel(' + json.dumps(state['updateId']) + ')')['phase'] == 'available'
    fixture('current')
    assert js('await workspace.updates.check()')['phase'] == 'checking'
    state = fixture('ready')
    count = debug()['installReplies']
    for consent in ['undefined', 'false', '"true"', '1', 'null', '{confirm:true}']:
        js_error('workspace.updates.install(' + json.dumps(state['updateId']) + ',' + consent + ')', -32602)
    js_error('workspace.updates.install("stale",true)', -32050)
    assert_unarmed(count)
    cursor = app.rpc('events.head')['cursor']
    assert js('await workspace.updates.install(' + json.dumps(state['updateId']) + ',true)')['phase'] == 'installing'
    assert debug()['installReplies'] == count + 1
    expect_origin(cursor, 'plugin')

    # Managed services retain their bound identity while using the same CLI/catalog.
    context = app.root / 'updates-service-context.json'
    worker = app.root / 'updates-service.py'
    worker.write_text('''import json,os,pathlib,subprocess,time
subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc','service.ready','--params','{"version":1}'],check=True)
keys=['SLATE_TERM_SOCKET','SLATE_TERM_INSTANCE_ID','SLATE_TERM_SERVICE_PLUGIN_ID','SLATE_TERM_SERVICE_ID','SLATE_TERM_SERVICE_GENERATION']
p=pathlib.Path(os.environ['UPDATES_CONTEXT']); t=p.with_suffix('.tmp'); t.write_text(json.dumps({k:os.environ[k] for k in keys})); t.replace(p)
while True: time.sleep(1)
''')
    app.rpc('plugins.register', packagePath=package_fixture(dict(id='updates.service', title='Updates service',
            service=dict(executable=sys.executable, arguments=[str(worker)], environment={'UPDATES_CONTEXT': str(context)})), app.root))
    app.rpc('plugins.service.start', id='updates.service')
    eventually('updates service ready', context.exists)
    service_env = dict(app.env, **json.loads(context.read_text()))
    assert methods <= set(app.cli('rpc', 'api.describe', env=service_env)['methods'])
    state = fixture('available')
    assert app.cli('updates', 'get', env=service_env) == state
    debug(operation='hide')
    assert app.cli('updates', 'show', env=service_env)['windowVisible']
    cursor = app.rpc('events.head')['cursor']
    assert app.cli('updates', 'download', '--update-id', state['updateId'], env=service_env)['phase'] == 'downloading'
    expect_origin(cursor, 'service')
    assert app.cli('updates', 'cancel', '--update-id', state['updateId'], env=service_env)['phase'] == 'available'
    fixture('current')
    assert app.cli('updates', 'check', env=service_env)['phase'] == 'checking'
    state = fixture('ready')
    count = debug()['installReplies']
    assert app.cli('updates', 'install', '--update-id', state['updateId'], '--confirm', env=service_env)['phase'] == 'installing'
    assert debug()['installReplies'] == count + 1
    app.rpc('plugins.service.stop', id='updates.service')

    # The real process quit prompt still protects a running terminal command.
    app.rpc('terminal.send', pane='p1', text="printf '\\nUPDATE_BUSY_READY\\n'; /bin/sleep 120\r")
    eventually('owned foreground process', terminal_busy)
    state = fixture('ready')
    count = debug()['installReplies']
    denied = debug(operation='install', confirmQuit=False)
    assert denied['phase'] == 'ready' and denied['updateId'] == state['updateId'], denied
    assert any('running processes' in prompt['message'] for prompt in denied['quitPrompts']), denied
    assert terminal_busy() and app.process.poll() is None
    assert_unarmed(count, denied)
    assert app.rpc('debug.closeConfirmation', quit=True, answer='cancel') is False
    app.rpc('debug.updates', operation='install', confirmQuit=True, replaceWhileConfirming=True, error=-32050)
    assert snapshot()['updateId'] != state['updateId'] and phase_is('ready')
    assert_unarmed(count)
    callback = debug(operation='readyCallback')
    assert callback['readyChoices'][-1] == 'skip'
    accepted = debug(operation='install', confirmQuit=True)
    assert accepted['phase'] == 'installing' and accepted['installReplies'] == count + 1, accepted
    assert any('running processes' in prompt['message'] for prompt in accepted['quitPrompts']), accepted
    assert debug(operation='readyCallback')['readyChoices'][-1] == 'install'
    app.rpc('terminal.key', pane='p1', key='ctrl+c')
    eventually('owned foreground process stopped', lambda: not terminal_busy())

    # Press the actual native install button after quit protection has been exercised.
    fixture('ready')
    count = debug()['installReplies']
    cursor = app.rpc('events.head')['cursor']
    press('primary')
    eventually('native explicit installation', lambda: phase_is('installing'))
    assert debug()['installReplies'] == count + 1
    expect_origin(cursor, 'native')
    rejected = debug(operation='oversizedInstall')
    assert rejected['phase'] == 'verificationError', rejected
    assert debug(operation='readyCallback')['readyChoices'][-1] == 'skip'
    assert debug()['installReplies'] == count + 1, 'Oversized installation bytes created another install choice'

    # Fresh native captures, including errors and empty states, in both appearances.
    captures = []
    states = ['available', 'downloading', 'verifying', 'ready', 'downloadError', 'verificationError',
              'checkError', 'checking', 'current', 'unavailable', 'idle', 'installing']
    for appearance in ['light', 'dark']:
        for phase in states:
            fixture(phase)
            debug(appearance=appearance)
            time.sleep(0.15)  # Let the compositor present the already-observed native state.
            capture = ROOT / f'artifacts/updates-{phase}-{appearance}.png'
            capture.unlink(missing_ok=True)
            state = debug(screenshot=str(capture))
            assert state['phase'] == phase and state['windowVisible']
            image = capture.read_bytes()
            assert image.startswith(b'\x89PNG\r\n\x1a\n') and len(image) > 1_000, capture
            captures.append(capture.name)
    (ROOT / 'artifacts/updates-summary.json').write_text(json.dumps({
        'status': 'passed', 'transport': 'fixture', 'realInstallation': False,
        'captures': captures, 'installReplies': debug()['installReplies'],
        'readyChoices': debug()['readyChoices'],
        'coverage': ['native controls', 'normal process quit confirmation', 'stale consent',
                     'CLI/plugin/service parity', 'notes focus and scroll', 'semantic update events']
    }, indent=2) + '\n')

print('PASS updates: explicit consent, denied unsolicited ready callbacks, native Download/Cancel/Later/Install, '
      'normal process quit protection, stale consent rejection, persistent release-note reading, '
      'CLI/plugin/service parity, semantic events, and 24 light/dark native captures; transport is simulated, no release installed')
