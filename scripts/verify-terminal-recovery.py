#!/usr/bin/env python3
"""VM-only terminal shutdown, previous-output recovery, retention controls and inline display."""
import json
import os
from pathlib import Path
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time

from api_fixture import ROOT, AppFixture, eventually
from terminal_recovery_codex import check_codex_shutdown

MAXIMUM_BYTES = 4 * 1024 * 1024
FINAL_MARKER = 'RECOVERY_FINAL_片付け_🧪'
READY_MARKER = 'RECOVERY_FOREGROUND_READY'


def prompt(app, pane='p1'):
    eventually('authenticated prompt ' + pane,
               lambda: app.rpc('context.get', pane=pane, scope='pane')['terminal']['state'] == 'prompt')


def snapshot(app):
    path = app.root / 'state/workspace.json'
    return json.loads(path.read_text()) if path.exists() else {}


def saved_output(app, pane='p1'):
    return snapshot(app).get('restoration', {}).get('terminalOutput', {}).get(pane)


def set_limit(app, value):
    app.rpc('config.patch', values={'terminal.saved_output_lines': value},
            expectedSourceRevision=app.rpc('config.get')['sourceRevision'])
    assert app.rpc('config.get')['current']['terminal']['saved_output_lines'] == value


def owned_alive(pid, script):
    # These fixtures own the uniquely named script and all PID files it creates.
    # Recheck its exact path before cleanup, so a reused PID is never signalled.
    result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat=', '-o', 'command='],
                            capture_output=True, text=True, timeout=3)
    fields = result.stdout.strip().split(None, 1)
    return len(fields) == 2 and not fields[0].startswith('Z') and str(script) in fields[1]


def cleanup_owned(directory, script):
    pids = set()
    for path in directory.glob('*.pid'):
        try:
            pids.add(int(path.read_text()))
        except (OSError, ValueError):
            continue
    for pid in pids:
        if owned_alive(pid, script):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    for pid in pids:
        eventually('owned process cleanup', lambda pid=pid: not owned_alive(pid, script), timeout=5)


def start_worker(app, pane, script, mode, directory):
    command = ' '.join(shlex.quote(part) for part in [sys.executable, str(script), mode, str(directory)])
    app.rpc('terminal.send', pane=pane, text=command + '\r')
    path = directory / (mode + '.pid')
    eventually(mode + ' started', path.exists)
    pid = int(path.read_text())
    eventually(mode + ' live', lambda: owned_alive(pid, script))
    return pid


def quit_normally(app):
    # Integration-only dispatch uses the real application termination delegate.
    started = time.monotonic()
    app.rpc('debug.quit')
    app.process.wait(timeout=6)
    elapsed = time.monotonic() - started
    assert app.process.returncode == 0, app.process.returncode
    assert elapsed < 4.5, f'Normal quit exceeded the bounded shutdown allowance: {elapsed:.2f}s'
    return elapsed


with tempfile.TemporaryDirectory(prefix='slate-terminal-recovery-', dir='/tmp') as temporary:
    directory = Path(temporary)
    replay = directory / 'printed-command-must-never-run'
    script = directory / 'owned-terminal-worker.py'
    script.write_text('''import json, os, signal, subprocess, sys, time, termios, tty
from pathlib import Path
mode, directory = sys.argv[1], Path(sys.argv[2])
def publish(name):
    (directory / (name + '.pid')).write_text(str(os.getpid()))
if mode in ('interrupt', 'interrupt-once'):
    helper = subprocess.Popen([sys.executable, __file__, 'interrupt-helper', str(directory)])
    while not (directory / 'interrupt-helper.pid').exists(): time.sleep(.01)
    original = termios.tcgetattr(sys.stdin)
    tty.setraw(sys.stdin)
    try:
        for number in range(20): print(f'INTERRUPT_TRANSCRIPT_{number:03d}', end='\\r\\n')
        print('INTERRUPT_READY', end='\\r\\n', flush=True)
        publish(mode)
        presses = 0
        while presses < (2 if mode == 'interrupt' else 1):
            if os.read(sys.stdin.fileno(), 1) == b'\\x03':
                assert helper.poll() is None, 'Shutdown killed the helper before the foreground exit handler'
                presses += 1
                (directory / (mode + '.count')).write_text(str(presses))
                if presses == 1 and mode == 'interrupt':
                    print('Press Ctrl-C again to exit', end='\\r\\n', flush=True)
        if mode == 'interrupt-once':
            termios.tcsetattr(sys.stdin, termios.TCSANOW, original)
            time.sleep(.4)
        else:
            time.sleep(.1)
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSANOW, original)
    print('RESUME_AFTER_KEYBOARD_INTERRUPT', flush=True)
    raise SystemExit(0)
if mode in ('background', 'detached', 'stubborn', 'interrupt-helper'):
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    publish(mode)
    while True: time.sleep(0.1)
signal.signal(signal.SIGINT, signal.SIG_IGN)
if mode == 'alternate':
    def leave_alternate(signum, frame):
        print(chr(27) + '[?1049l' + 'ALTERNATE_FINAL_OUTPUT', flush=True)
        raise SystemExit(0)
    signal.signal(signal.SIGHUP, leave_alternate)
    signal.signal(signal.SIGTERM, leave_alternate)
    print(chr(27) + '[?1049h' + chr(27) + '[2J' + chr(27) + '[H' + 'ALTERNATE_SCREEN_READY', flush=True)
    publish(mode)
    while True: time.sleep(0.1)
def finish(signum, frame):
    for number in range(128):
        print(f'FINAL_BURST_{number:03d} ' + 'x' * 1000)
    print('RECOVERY_FINAL_片付け_🧪', flush=True)
    (directory / 'foreground.finished').write_text('handler completed')
    raise SystemExit(0)
signal.signal(signal.SIGHUP, finish)
signal.signal(signal.SIGTERM, finish)
subprocess.Popen([sys.executable, __file__, 'background', str(directory)], preexec_fn=os.setpgrp)
with open(os.devnull, 'r+') as null:
    subprocess.Popen([sys.executable, __file__, 'detached', str(directory)], start_new_session=True,
                     stdin=null, stdout=null, stderr=null)
for number in range(120): print(f'recovered-line-{number:04d} 日本語 e\\u0301 🧪')
print('touch ' + str(directory / 'printed-command-must-never-run'))
print('RECOVERY_FOREGROUND_READY', flush=True)
publish(mode)
while True: time.sleep(0.1)
''')
    try:
        with AppFixture('terminal-recovery-interrupt') as app:
            prompt(app)
            interrupted = start_worker(app, 'p1', script, 'interrupt', directory)
            eventually('raw-mode foreground ready', lambda: 'INTERRUPT_READY' in app.rpc('terminal.capture', pane='p1')['text'])
            helper_pid = int((directory / 'interrupt-helper.pid').read_text())
            helper_before = subprocess.check_output(['/bin/ps', '-p', str(helper_pid), '-o', 'pid=,ppid=,pgid=,tty=,stat=,command='], text=True)
            quit_normally(app)
            assert not owned_alive(interrupted, script)
            if owned_alive(helper_pid, script):
                helper_after = subprocess.check_output(['/bin/ps', '-p', str(helper_pid), '-o', 'pid=,ppid=,pgid=,tty=,stat=,command='], text=True)
                raise AssertionError('Quit left helper running. Before: ' + helper_before + 'After: ' + helper_after)
            interrupted_text = saved_output(app)['text']
            assert 'RESUME_AFTER_KEYBOARD_INTERRUPT' in interrupted_text, 'Quit skipped the foreground Ctrl-C exit path'
            assert (directory / 'interrupt.count').read_text() == '2'
            assert interrupted_text.count('INTERRUPT_TRANSCRIPT_000') == 1, 'Quit duplicated the transcript'
            interrupt_source = (app.root / 'state/workspace.json').read_text()
        with AppFixture('terminal-recovery-interrupt-load', workspace_source=interrupt_source) as app:
            prompt(app)
            screen = app.rpc('terminal.capture', pane='p1')['text']
            assert 'RESUME_AFTER_KEYBOARD_INTERRUPT' in screen
            assert saved_output(app)['text'].count('INTERRUPT_TRANSCRIPT_000') == 1
            app.rpc('debug.screenshot', pane='p1', path=str(ROOT / 'artifacts/terminal-recovery-interrupt-restored.png'))
        print('PASS raw-mode Ctrl-C exit: two keypresses, final resume output, restored transcript without duplication', flush=True)

        (directory / 'interrupt-helper.pid').unlink()
        with AppFixture('terminal-recovery-interrupt-once') as app:
            prompt(app)
            interrupted = start_worker(app, 'p1', script, 'interrupt-once', directory)
            eventually('single-interrupt foreground ready', lambda: 'INTERRUPT_READY' in app.rpc('terminal.capture', pane='p1')['text'])
            quit_normally(app)
            assert not owned_alive(interrupted, script)
            assert not owned_alive(int((directory / 'interrupt-helper.pid').read_text()), script), 'Quit left the single-interrupt helper running'
            assert 'RESUME_AFTER_KEYBOARD_INTERRUPT' in saved_output(app)['text']
            assert (directory / 'interrupt-once.count').read_text() == '1'
        print('PASS single Ctrl-C exit: foreground helper survives until the exit handler, shell return stops retries', flush=True)

        check_codex_shutdown(directory, prompt, quit_normally, saved_output)

        listing = directory / 'listing'
        listing.mkdir()
        for name in ['restored-alpha.txt', 'restored-beta.txt']:
            (listing / name).touch()
        with AppFixture('terminal-recovery-listing-save') as app:
            prompt(app)
            app.rpc('command.run', id='welcome.read')
            app.rpc('terminal.run', pane='p1', shell='zsh', command='ls -1 ' + shlex.quote(str(listing)))
            quit_normally(app)
            listing_source = (app.root / 'state/workspace.json').read_text()
        for iteration in range(2):
            with AppFixture(f'terminal-recovery-listing-load-{iteration}', workspace_source=listing_source) as app:
                prompt(app)
                assert app.rpc('debug.paneHeader', pane='p1')['headerActions'] == []
                screen = app.rpc('terminal.capture', pane='p1')['text']
                assert 'restored-alpha.txt' in screen and 'restored-beta.txt' in screen
                assert 'New terminal session' in screen and screen.rstrip().endswith('API_TEST>')
                assert screen.count('restored-alpha.txt') == 1, 'Restart duplicated restored output'
                app.rpc('terminal.search', pane='p1', action='set', query='restored-beta.txt')
                eventually('restored output searchable', lambda: (app.rpc('terminal.search', pane='p1', action='get')['total'] or 0) >= 1)
                app.rpc('terminal.search', pane='p1', action='end')
                app.rpc('debug.screenshot', pane='p1', path=str(ROOT / f'artifacts/terminal-restored-inline-{iteration}.png'))
                quit_normally(app)
                listing_source = (app.root / 'state/workspace.json').read_text()
                assert json.loads(listing_source)['restoration']['terminalOutput']['p1']['text'].count('restored-alpha.txt') == 1
        print('PASS inline restoration: visible listing, fresh prompt, terminal search, and two relaunches without duplication', flush=True)

        clear_snapshot = json.loads(listing_source)
        clear_snapshot['restoration']['terminalOutput']['p1']['text'] = '\n'.join(
            f'restored-before-clear-{i:03d}' for i in range(200))
        with AppFixture('terminal-recovery-cleared-screen', workspace_source=json.dumps(clear_snapshot)) as app:
            prompt(app)
            app.rpc('terminal.run', pane='p1', shell='zsh', command="printf '\\033[Hpartial-overwrite\\n'")
            eventually('cursor rewrite saves fresh output', lambda: 'partial-overwrite' in (saved_output(app) or {}).get('text', ''))
            assert saved_output(app)['text'].count('restored-before-clear-000') == 1
            app.rpc('terminal.run', pane='p1', shell='zsh',
                    command="printf 'before-full-clear\\n\\033[H\\033[2Jafter-full-clear\\n'")
            eventually('full clear saves new output', lambda: 'after-full-clear' in (saved_output(app) or {}).get('text', ''))
            assert saved_output(app)['text'].count('restored-before-clear-000') == 1
            set_limit(app, 0)
            set_limit(app, 10000)
            eventually('disabled restored scrollback stays forgotten', lambda: 'restored-before-clear-' not in (saved_output(app) or {}).get('text', ''))
            assert 'after-full-clear' in saved_output(app)['text']
        print('PASS cursor rewrite and full-screen clear: separate capture prevents duplication and re-saving forgotten output', flush=True)

        with AppFixture('terminal-recovery-save') as app:
            app.capture_contracts()
            prompt(app)
            app.rpc('command.run', id='welcome.read')
            assert app.rpc('config.get')['current']['terminal']['saved_output_lines'] == 10000
            app.rpc('command.run', id='settings.open')
            state = app.rpc('debug.settings', section='General', savedOutputLines='10001', apply=True)
            assert state['error'] is None and not state['dirty']
            assert state['values']['terminal.saved_output_lines'] == '10001'
            assert app.rpc('config.get')['current']['terminal']['saved_output_lines'] == 10001
            before_invalid = app.config.read_text()
            invalid = app.rpc('debug.settings', savedOutputLines='-1', apply=True)
            assert invalid['error'] and app.config.read_text() == before_invalid
            reverted = app.rpc('debug.settings', revert=True)
            assert reverted['values']['terminal.saved_output_lines'] == '10001'
            state = app.rpc('debug.settings', savedOutputLines='10000', apply=True)
            assert state['error'] is None and not state['dirty']
            for width, height, name in [(1060, 680, 'regular'), (1000, 560, 'compact')]:
                app.rpc('debug.settings', section='General', width=width, height=height)
                time.sleep(.2)  # Let the native Settings layout settle before its window capture.
                path = ROOT / f'artifacts/terminal-recovery-settings-{name}.png'
                app.rpc('debug.screenshot', settings=True, path=str(path))
                assert path.stat().st_size > 1000
            app.rpc('debug.settings', restoreWorkspace=False)
            time.sleep(.2)
            app.rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/terminal-recovery-settings-disabled.png'))
            app.rpc('debug.settings', restoreWorkspace=True)
            assert app.rpc('debug.settings')['values']['terminal.saved_output_lines'] == '10000'
            app.rpc('debug.settings', section='Terminal')
            time.sleep(.2)
            app.rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/terminal-recovery-settings-terminal.png'))
            app.rpc('debug.key', settings=True, chord='cmd+w')
            original_session = app.rpc('pane.inspect', pane='p1')['sessionId']
            foreground = start_worker(app, 'p1', script, 'foreground', directory)
            eventually('foreground output rendered', lambda: READY_MARKER in app.rpc('terminal.capture', pane='p1')['text'])
            eventually('owned background and detached processes', lambda: (directory / 'background.pid').exists() and (directory / 'detached.pid').exists())
            background = int((directory / 'background.pid').read_text())
            detached = int((directory / 'detached.pid').read_text())
            assert os.getsid(background) == os.getsid(foreground)
            assert os.getsid(detached) != os.getsid(foreground)

            sibling = app.rpc('command.run', id='split.right', pane='p1')['paneId']
            prompt(app, sibling)
            stubborn = start_worker(app, sibling, script, 'stubborn', directory)
            started = time.monotonic()
            app.rpc('command.run', id='pane.close', pane=sibling, force=True)
            eventually('forced close kills stubborn attached process', lambda: not owned_alive(stubborn, script), timeout=4)
            assert time.monotonic() - started < 3.5, 'Forced pane teardown was not bounded'
            assert owned_alive(foreground, script), 'Closing a sibling signalled this terminal'
            assert owned_alive(background, script), 'Closing a sibling signalled this terminal background job'
            assert owned_alive(detached, script), 'Closing a pane signalled a detached session'

            (directory / 'stubborn.pid').unlink()
            concurrent = app.rpc('command.run', id='split.right', pane='p1')['paneId']
            prompt(app, concurrent)
            concurrent_pid = start_worker(app, concurrent, script, 'stubborn', directory)
            elapsed = quit_normally(app)
            assert not owned_alive(concurrent_pid, script), 'Quit left a second terminal running'
            assert (directory / 'foreground.finished').read_text() == 'handler completed'
            eventually('foreground and background stopped', lambda: not owned_alive(foreground, script) and not owned_alive(background, script), timeout=3)
            assert owned_alive(detached, script), 'App quit killed the detached session'
            source = (app.root / 'state/workspace.json').read_text()
            stored = json.loads(source)['restoration']['terminalOutput']['p1']
            assert FINAL_MARKER in stored['text'], 'Final exit-handler output was lost before snapshot capture'
            assert 'FINAL_BURST_000' in stored['text'] and 'FINAL_BURST_127' in stored['text']
            assert READY_MARKER in stored['text'] and 'recovered-line-0000' in stored['text']
            assert len(stored['text'].encode()) <= MAXIMUM_BYTES
            assert '\ufffd' not in stored['text']
            assert stat.S_IMODE((app.root / 'state/workspace.json').stat().st_mode) == 0o600
            assert not replay.exists()
            print(f'PASS normal quit {elapsed:.2f}s: final trap output, attached process cleanup, detached survival')

        with AppFixture('terminal-recovery-load', workspace_source=source) as app:
            app.capture_contracts()
            prompt(app)
            assert app.rpc('pane.inspect', pane='p1')['sessionId'] != original_session
            old = saved_output(app)
            assert old is not None and old['capturedAt'] is not None
            assert isinstance(old['ended'], bool)
            assert FINAL_MARKER in old['text'] and READY_MARKER in old['text']
            # Once unchanged output has been saved, periodic capture must not
            # rewrite the same potentially large snapshot on every tick.
            time.sleep(6)
            saved_at = (app.root / 'state/workspace.json').stat().st_mtime_ns
            time.sleep(6)
            assert (app.root / 'state/workspace.json').stat().st_mtime_ns == saved_at
            assert saved_output(app)['text'].count(FINAL_MARKER) == 1
            assert not replay.exists(), 'Restoration executed printed output'
            set_limit(app, 5)
            eventually('lower cap persisted', lambda: saved_output(app) is not None and len(saved_output(app)['text'].splitlines()) <= 5)
        # A loaded snapshot near the byte cap exercises UTF-8 storage independently
        # of the engine's separate scrollback-cell budget and terminal wrapping.
        unicode_source = json.loads(source)
        line = ('日本語🧪e\u0301' * 64) + '\n'
        large_text = line * ((MAXIMUM_BYTES - 100) // len(line.encode())) + 'UNICODE_RECOVERY_TAIL\n'
        assert 3 * 1024 * 1024 < len(large_text.encode()) <= MAXIMUM_BYTES
        unicode_source['restoration']['terminalOutput']['p1']['text'] = large_text
        configuration = '[terminal]\nshell = "/bin/zsh"\nsaved_output_lines = 100000\n'
        with AppFixture('terminal-recovery-unicode', configuration=configuration,
                        workspace_source=json.dumps(unicode_source, ensure_ascii=False)) as app:
            app.capture_contracts()
            prompt(app)
            screen = app.rpc('terminal.capture', pane='p1')['text']
            assert '\ufffd' not in screen and 'UNICODE_RECOVERY_TAIL' in screen
            assert not app.rpc('config.get')['workspace']['savingSuspended']
            assert len(saved_output(app)['text'].encode()) <= MAXIMUM_BYTES
            assert not replay.exists()
            set_limit(app, 0)
            eventually('zero removes all stored output', lambda: not snapshot(app).get('restoration', {}).get('terminalOutput'))
            app.rpc('terminal.run', pane='p1', command="printf 'DISABLED_%s\\n' OUTPUT")
            assert 'DISABLED_OUTPUT' in app.rpc('terminal.capture', pane='p1')['text']
            quit_normally(app)
            zero_source = (app.root / 'state/workspace.json').read_text()
            assert not json.loads(zero_source)['restoration'].get('terminalOutput')

        with AppFixture('terminal-recovery-zero-restart', configuration='[terminal]\nshell = "/bin/zsh"\nsaved_output_lines = 0\n',
                        workspace_source=zero_source) as app:
            app.capture_contracts()
            prompt(app)
            assert 'DISABLED_OUTPUT' not in app.rpc('terminal.capture', pane='p1')['text']
            assert not replay.exists()
        with AppFixture('terminal-recovery-alternate') as app:
            prompt(app)
            alternate = start_worker(app, 'p1', script, 'alternate', directory)
            eventually('alternate screen rendered', lambda: 'ALTERNATE_SCREEN_READY' in app.rpc('terminal.capture', pane='p1')['text'])
            quit_normally(app)
            assert not owned_alive(alternate, script)
            alternate_text = saved_output(app)['text']
            assert 'ALTERNATE_SCREEN_READY' in alternate_text, 'Closing discarded the earlier alternate screen'
            assert 'ALTERNATE_FINAL_OUTPUT' in alternate_text, 'Closing lost output after leaving the alternate screen'

        with AppFixture('terminal-recovery-empty') as app:
            prompt(app)
            app.rpc('command.run', id='pane.close', pane='p1', force=True)
            time.sleep(2.5)
            quit_normally(app)
    finally:
        cleanup_owned(directory, script)

print('PASS terminal recovery: bounded shutdown, final output, detached/sibling isolation, fresh-shell history, inline display, Unicode caps, lower/zero retention and no replay')
