#!/usr/bin/env python3
"""Native regression: restore an empty workspace and recover after closing all windows."""
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = pathlib.Path(os.environ.get('SLATE_TERM_TEST_APP', ROOT / '.derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal'))
CLI = APP.parent.parent / 'Helpers/slate-term'


def eventually(label, check):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.05)
    raise AssertionError(label)


with tempfile.TemporaryDirectory(prefix='slate-window-recovery-', dir='/tmp') as temporary:
    directory = pathlib.Path(temporary)
    state = directory / 'state'
    state.mkdir(mode=0o700)
    (state / 'workspace.json').write_text(json.dumps({
        'schemaVersion': 2, 'panes': [], 'tabs': [], 'groups': [],
        'nextPane': 17, 'nextTab': 8, 'nextGroup': 6,
    }))
    ready = directory / 'socket'
    env = dict(os.environ, SLATE_TERM_INTEGRATION='1', SLATE_TERM_STATE_DIR=temporary,
               SLATE_TERM_SOCKET_FILE=str(ready))
    for key in ['SLATE_TERM_PANE_ID', 'SLATE_TERM_TAB_ID', 'SLATE_TERM_SOCKET', 'SLATE_TERM_CONFIG_FILE']:
        env.pop(key, None)
    (ROOT / 'artifacts').mkdir(exist_ok=True)
    with (ROOT / 'artifacts/window-recovery-process.log').open('w') as log:
        app = subprocess.Popen([str(APP)], env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            eventually('app readiness', lambda: app.poll() is None and ready.exists())
            env['SLATE_TERM_SOCKET'] = ready.read_text().strip()

            def rpc(method, **params):
                result = subprocess.run([str(CLI), 'rpc', method, '--params', json.dumps(params), '--json'],
                                        env=env, capture_output=True, text=True, timeout=25)
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)

            def close_all():
                for tab in rpc('workspace.get')['tabs']:
                    rpc('command.run', id='tab.close', tab=tab['id'], force=True)
                assert rpc('workspace.get')['tabs'] == []
                assert rpc('debug.inspect')['windows'] == []

            def visible_window():
                return any(window['visible'] for window in rpc('debug.inspect')['windows'])

            workspace = rpc('workspace.get')
            assert [tab['id'] for tab in workspace['tabs']] == ['t8'], ('Empty restoration must open a window without resetting IDs', workspace)
            assert [pane['id'] for pane in workspace['panes']] == ['p17']
            eventually('initial window visible', visible_window)
            rpc('debug.activate')
            for chord in ['cmd+n', 'cmd+t']:
                close_all()
                rpc('debug.key', chord=chord, menu=True)
                eventually('windowless ' + chord, visible_window)
                assert len(rpc('workspace.get')['tabs']) == 1
            # Global creation actions also work while Settings is the only key window.
            close_all()
            rpc('debug.settings')
            rpc('debug.key', chord='cmd+n', menu=True)
            eventually('New Window from Settings', visible_window)
            # AppKit consumes disabled menu equivalents without running them.
            # Settings focus must not let pane commands mutate the workspace.
            rpc('debug.settings')
            before = rpc('workspace.get')
            rpc('debug.key', chord='cmd+d', menu=True)
            assert rpc('workspace.get') == before
            # Reopening from the Dock recovers a closed workspace, without adding
            # another terminal on repeated reopen notifications.
            close_all()
            rpc('debug.reopen')
            eventually('Dock reopen', visible_window)
            before = rpc('workspace.get')
            rpc('debug.reopen')
            assert rpc('workspace.get') == before
            print('PASS: empty-workspace startup, monotonic IDs, windowless Cmd-N/Cmd-T, New Window from Settings, and Dock reopen')
        finally:
            if app.poll() is None:
                os.killpg(app.pid, signal.SIGTERM)
                try:
                    app.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(app.pid, signal.SIGKILL)
                    app.wait()
