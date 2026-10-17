#!/usr/bin/env python3
"""zsh, Apple bash 3.2, bash 5.2/5.3 and fish as the configured shell of the real app: authenticated
state, shell identity, terminal run/wait, the shell check, startup commands and the launch race.
Run only through verify-vm.py."""
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from api_fixture import AppFixture, APP, ROOT, eventually

assert subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip().startswith('VirtualMac'), 'Run this UI gate through scripts/verify-vm.py'

SHELLS = ROOT / '.build/test-shells'
CASES = [('zsh', 'zsh', '/bin/zsh', True), ('bash-3.2', 'bash', '/bin/bash', False),
         ('bash-5.2', 'bash', str(SHELLS / 'bash-5.2/bash'), True), ('bash-5.3', 'bash', str(SHELLS / 'bash-5.3/bash'), True)]
if (SHELLS / 'WITHOUT_FISH').is_file():
    print('NOT TESTED fish: the host run opted out with SLATE_TEST_SHELLS_WITHOUT_FISH=1', flush=True)
else:
    CASES.append(('fish-4', 'fish', str(SHELLS / 'fish-4/fish'), True))


def idle(app):
    eventually('idle prompt', lambda: app.rpc('pane.inspect', pane='p1').get('state') == 'prompt', timeout=30)


for name, kind, path, runs in CASES:
    home = Path(tempfile.mkdtemp(prefix='slate-shell-home-', dir='/tmp'))
    with AppFixture('shells-' + name, f'[terminal]\nshell = "{path}"\n', environment={'HOME': str(home)}) as app:
      try:
        idle(app)
        pane = app.rpc('pane.inspect', pane='p1')
        assert pane['shell'] == kind and pane['runAvailable'] is runs, pane
        terminal = app.rpc('context.get', pane='p1', scope='pane')['terminal']
        assert terminal['shell'] == kind and terminal['runAvailable'] is runs, terminal

        if runs:
            result = app.cli('terminal', 'run', '--pane', 'p1', '--command', 'printf "RAN-%s\\n" ' + kind, '--shell', kind)
            assert result['exitCode'] == 0 and 'RAN-' + kind in result['text'], result
            failed = app.rpc('terminal.run', pane='p1', command='sh -c "exit 3"')
            assert failed['exitCode'] == 3, failed
            moved = app.rpc('terminal.run', pane='p1', command='cd /tmp')
            assert moved['exitCode'] == 0
            directory = app.rpc('context.get', pane='p1', scope='pane')['terminal']['workingDirectory']
            assert directory in ('/tmp', '/private/tmp'), directory
            # A program in another shell's language is never submitted.
            other = 'fish' if kind != 'fish' else 'zsh'
            mismatch = app.rpc('terminal.run', pane='p1', command='echo nope', shell=other, error=-32041)
            assert f'runs {kind}, not {other}' in mismatch['message'], mismatch
            # Many quick commands in a row: reports cross on separate connections.
            for index in range(10):
                quick = app.rpc('terminal.run', pane='p1', command=f'printf "Q{index}\\n"')
                assert quick['exitCode'] == 0 and f'Q{index}' in quick['text'], quick
        else:
            refused = app.rpc('terminal.run', pane='p1', command='echo nope', error=-32041)
            assert 'bash 4.4 or later' in refused['message'], refused
            # State still follows commands typed into the shell.
            before = app.rpc('pane.inspect', pane='p1')
            app.rpc('terminal.send', pane='p1', text='sleep 2\r')
            eventually('running state', lambda: app.rpc('pane.inspect', pane='p1')['state'] == 'running')
            idle(app)
        waited = app.rpc('terminal.wait', pane='p1', timeoutMilliseconds=5000)
        assert waited['matched'], waited

        # Saved-layout startup commands run in this shell, or fail with a reason.
        marker = home / f'startup-{uuid.uuid4().hex}'
        source = app.rpc('layouts.windows')[0]['id']
        definition = app.rpc('layouts.capture', window=source, name='Startup ' + name)['definition']
        definition['id'] = str(uuid.uuid4())
        definition['tabs'][0]['panes'][0]['configuration'] = {'command': f"printf once >> '{marker}'"}
        app.rpc('layouts.create', definition=definition)
        opened = app.rpc('layouts.open', id=definition['id'])
        started = opened['paneIds'][0]

        def status():
            return next((item for item in app.rpc('layouts.startupStatus') if item['paneId'] == started), None)
        if runs:
            eventually('startup command', lambda: (status() or {}).get('state') == 'finished', timeout=30)
            assert marker.read_text() == 'once'
        else:
            eventually('startup refusal', lambda: (status() or {}).get('state') == 'failed', timeout=30)
            assert 'bash 4.4 or later' in status()['message'], status()
            assert not marker.exists()

        # The launch race: the first prompt report arrives while the app is still busy launching.
        for _ in range(3):
            app.process.terminate(); app.process.wait(timeout=10)
            app.ready.unlink()
            app.process = subprocess.Popen([str(APP)], env=app.env, stdout=app.log, stderr=app.log, start_new_session=True)
            eventually('restarted fixture', lambda: app.ready.exists() and app.process.poll() is None, timeout=30)
            app.path = app.ready.read_text().strip(); app.env['SLATE_TERM_SOCKET'] = app.path
            idle(app)
        print(f'PASS {name}: state, identity, runs={runs}, wait, startup command and three restarts', flush=True)
      except BaseException:
        # The screen and state show what the shell was doing when the check failed.
        try:
            print(app.rpc('terminal.capture', pane='p1')['text'][-3000:], file=sys.stderr)
            print(app.rpc('pane.inspect', pane='p1'), file=sys.stderr)
        except Exception as error:
            print('diagnostics unavailable:', error, file=sys.stderr)
        raise
print('shells ok')
