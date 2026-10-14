#!/usr/bin/env python3
"""Owned native menus, keyboard routing and persistent close-warning consent."""
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
ARTIFACTS = ROOT / 'artifacts'


def eventually(label, condition, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.05)
    raise AssertionError('Timed out: ' + label)


with tempfile.TemporaryDirectory(prefix='slate-menu-', dir='/tmp') as temporary:
    directory = pathlib.Path(temporary)
    ready = directory / 'socket-path'
    env = dict(os.environ, SLATE_TERM_INTEGRATION='1', SLATE_TERM_STATE_DIR=temporary,
               SLATE_TERM_SOCKET_FILE=str(ready), SLATE_TERM_CONFIG_FILE=str(directory / 'config.toml'))
    for key in ['SLATE_TERM_PANE_ID', 'SLATE_TERM_TAB_ID', 'SLATE_TERM_SOCKET']:
        env.pop(key, None)
    app = None

    def cli(*args, success=True):
        result = subprocess.run([str(CLI), *args, '--json'], env=env, capture_output=True, text=True, timeout=20)
        if not success:
            assert result.returncode != 0, args
            return result.stderr
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    def rpc(method, **params):
        return cli('rpc', method, '--params', json.dumps(params))

    def start(log):
        global app
        ready.unlink(missing_ok=True)
        app = subprocess.Popen([str(APP)], env=env, stdout=log, stderr=log, start_new_session=True)
        eventually('app ready', lambda: app.poll() is None and ready.exists())
        env['SLATE_TERM_SOCKET'] = ready.read_text().strip()
        rpc('debug.activate')
        eventually('active fixture window', lambda: rpc('debug.inspect')['applicationActive'])

    def stop():
        global app
        if app and app.poll() is None:
            os.killpg(app.pid, signal.SIGTERM)
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(app.pid, signal.SIGKILL)
                app.wait()
        app = None

    def busy_pane():
        pane = cli('panes', 'split', '--right', '--pane', 'p1')['paneId']
        cli('terminal', 'send', '--pane', pane, '--text', "printf '\\nMENU_BUSY_READY\\n'; /bin/sleep 30\r")
        eventually('owned busy shell', lambda: 'MENU_BUSY_READY' in cli('terminal', 'capture', '--pane', pane)['text'].splitlines()
                   and next(p for p in rpc('debug.inspect')['panes'] if p['paneId'] == pane)['needsConfirmClose'])
        return pane

    with (ARTIFACTS / 'menu-ui-process.log').open('w') as log:
        try:
            start(log)
            tree = rpc('debug.menuTree')
            workspace = next(item for item in tree if item['title'] == 'Workspace')
            groups = {item['title']: item for item in workspace['children'] if item['children']}
            assert set(groups) == {'Tabs', 'Browser', 'Split Pane', 'Focus Pane', 'Layout'}, groups
            shortcuts = []

            def check(items):
                for item in items:
                    if item['children']:
                        check(item['children'])
                    else:
                        assert item['key'], item
                        shortcuts.append((item['key'], item['modifiers']))
            check(workspace['children'])
            assert len(shortcuts) == len(set(shortcuts)), 'Duplicate workspace shortcuts'
            pane_menu = next(item for item in tree if item['title'] == 'Pane')
            assert not any('Switching discards' in item['title'] or 'Rename' in item['title'] for item in pane_menu['children'])
            assert all(item['key'] for item in pane_menu['children']), pane_menu
            rpc('debug.key', chord='cmd+alt+d', dispatch=True)
            layout = cli('layout', 'get')
            assert layout.get('axis') == 'horizontal' and layout.get('first') == {'kind': 'pane', 'pane': 'p2'}, (layout, rpc('debug.inspect'), rpc('config.get')['current']['keybind'])
            rpc('debug.key', chord='cmd+alt+right', dispatch=True)
            assert rpc('workspace.get')['tabs'][0]['focusedPane'] == 'p1'
            rpc('debug.key', chord='cmd+alt+left', dispatch=True)
            assert rpc('workspace.get')['tabs'][0]['focusedPane'] == 'p2'
            rpc('debug.key', chord='cmd+alt+shift+d', dispatch=True)
            assert len(cli('panes', 'list')) == 3
            rpc('debug.key', chord='cmd+alt+down', dispatch=True)
            assert rpc('workspace.get')['tabs'][0]['focusedPane'] == 'p2'
            rpc('debug.key', chord='cmd+alt+up', dispatch=True)
            assert rpc('workspace.get')['tabs'][0]['focusedPane'] == 'p3'
            rpc('debug.key', chord='cmd+shift+e', dispatch=True)
            assert abs(cli('layout', 'get')['fraction'] - 2 / 3) < 0.001
            rpc('debug.key', chord='cmd+shift+r', dispatch=True)
            for pane in ['p2', 'p3']:
                cli('panes', 'close', '--pane', pane, '--force')

            rpc('debug.paneTypeMenu', pane='p1', select='browser', answer='cancel', suppress=True,
                screenshot=str(ARTIFACTS / 'pane-type-warning.png'))
            assert 'terminal' in cli('panes', 'list')[0]['type']
            assert not rpc('config.get')['typeWarning']['suppressed'], 'Cancel must not save type-switch consent'
            rpc('debug.paneTypeMenu', pane='p1', select='browser', answer='switch')
            assert 'browser' in cli('panes', 'list')[0]['type']
            assert not rpc('config.get')['typeWarning']['suppressed']
            rpc('debug.paneTypeMenu', select='terminal', answer='switch', suppress=True)
            assert 'terminal' in cli('panes', 'list')[0]['type']
            assert rpc('config.get')['typeWarning']['suppressed']
            assert not rpc('config.get')['closeWarning']['suppressed'], 'Type-switch consent must not suppress close warnings'
            rpc('debug.key', chord='cmd+ctrl+2', dispatch=True)
            assert 'browser' in cli('panes', 'list')[0]['type']
            rpc('debug.key', chord='cmd+ctrl+1', dispatch=True)
            assert 'terminal' in cli('panes', 'list')[0]['type']
            # Capture menus after key tests: popup tracking can consume queued key events.
            rpc('debug.menuPreview', pane='p1', path=str(ARTIFACTS / 'pane-type-dropdown.png'))
            for menu, submenu, name in [('Workspace', None, 'workspace-menu'), ('Workspace', 'Split Pane', 'split-menu'),
                                        ('Workspace', 'Focus Pane', 'focus-menu'), ('Pane', None, 'pane-menu')]:
                (ARTIFACTS / (name + '.png')).unlink(missing_ok=True)
                params = dict(menu=menu, path=str(ARTIFACTS / (name + '.png')))
                if submenu:
                    params['submenu'] = submenu
                rpc('debug.menuPreview', **params)
                assert (ARTIFACTS / (name + '.png')).stat().st_size > 1000
            pane = busy_pane()
            (ARTIFACTS / 'close-warning.png').unlink(missing_ok=True)
            rpc('debug.closeConfirmation', pane=pane, answer='cancel', suppress=True,
                screenshot=str(ARTIFACTS / 'close-warning.png'))
            assert (ARTIFACTS / 'close-warning.png').stat().st_size > 1000
            assert pane in [p['id'] for p in cli('panes', 'list')]
            assert not rpc('config.get')['closeWarning']['suppressed'], 'Cancel must not save consent'
            rpc('debug.closeConfirmation', pane=pane, answer='terminate', suppress=True)
            assert pane not in [p['id'] for p in cli('panes', 'list')]
            assert rpc('config.get')['closeWarning']['suppressed']
            stop()
            start(log)
            assert rpc('config.get')['closeWarning']['suppressed'], 'Consent was not persisted'
            assert rpc('config.get')['typeWarning']['suppressed'], 'Type-switch consent was not persisted'
            pane = busy_pane()
            rpc('debug.paneTypeMenu', pane='p1', select='browser', answer='cancel')
            assert 'browser' in next(p for p in cli('panes', 'list') if p['id'] == 'p1')['type'], 'Suppressed header switch still prompted'
            assert 'terminal' in next(p for p in cli('panes', 'list') if p['id'] == pane)['type'], 'Header switched the focused pane instead of its own pane'
            rpc('debug.paneTypeMenu', pane='p1', select='terminal', answer='cancel')
            error = cli('panes', 'close', '--pane', pane, success=False)
            assert '--force' in error, error
            assert rpc('debug.closeConfirmation', quit=True, answer='cancel'), 'Quit still prompted despite consent'
            rpc('debug.closeConfirmation', pane=pane, answer='cancel')
            assert pane not in [p['id'] for p in cli('panes', 'list')], 'Suppressed native close still prompted'
            rpc('debug.resetCloseWarnings')
            pane = busy_pane()
            assert not rpc('debug.closeConfirmation', quit=True, answer='cancel')
            rpc('debug.closeConfirmation', pane=pane, answer='cancel')
            assert pane in [p['id'] for p in cli('panes', 'list')], 'Reset did not restore the warning'
            cli('panes', 'close', '--pane', pane, '--force')
            print('PASS native menu groups/shortcuts, actual key dispatch, removal of switching note, real alert cancellation/consent, restart persistence, reset, quit and unchanged CLI force safeguard')
        finally:
            stop()
