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
CLI = APP.parent.parent / 'Frameworks/SlateRuntime.framework/Helpers/slate-term'
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

    def press(chord):
        # Other applications can take focus between assertions on an actively used desktop.
        # Reacquire our captured window before one key delivery; never replay a mutation.
        tab = rpc('workspace.get')['keyTabID']
        rpc('debug.activate', tab=tab)
        def owns_focus():
            state = rpc('debug.inspect')
            return state['applicationActive'] and any(w['tabId'] == tab and w['key'] for w in state['windows'])
        eventually('owned keyboard target', owns_focus)
        rpc('debug.key', tab=tab, chord=chord, dispatch=True)

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
            assert set(groups) == {'Tabs', 'Browser', 'Split Pane', 'Focus Pane', 'Layout', 'Appearance', 'Application Font Size'}, groups
            window_menu = next(item for item in tree if item['title'] == 'Window')
            detach = next(item for item in window_menu['children'] if item.get('command') == 'tab.detachCurrent')
            assert detach['key'] == 'n' and detach['modifiers'] == (1 << 20 | 1 << 18), detach
            shortcuts = []

            def check(items):
                for item in items:
                    if item['children']:
                        check(item['children'])
                    else:
                        if item.get('command') in {'layouts.edit', 'layouts.openWindow', 'layouts.captureWindow', 'plugins.reload', 'plugins.panelState.reset',
                                                   'pane.header.show', 'pane.header.hide', 'pane.header.toggle',
                                                   'tab.showAll', 'pane.rename', 'pane.copyID', 'pane.move.chooseDestination', 'tab.rename', 'tab.title.clear', 'appearance.auto', 'appearance.light', 'appearance.dark',
                                                   'notifications.next', 'notifications.open', 'notifications.settings',
                                                   'welcome.read', 'welcome.unread', 'welcome.reset',
                                                   'browser.clearData', 'browser.clearSiteData',
                                                   'terminal.font.increase', 'terminal.font.decrease', 'terminal.font.reset'}:
                            assert item['key'] == '', 'This action intentionally has no default shortcut'
                            continue
                        assert item['key'], item
                        shortcuts.append((item['key'], item['modifiers']))
            check(workspace['children'])
            assert any(item.get('command') == 'pane.copyID' and item['title'] == 'Copy Pane ID' for item in workspace['children'])
            assert len(shortcuts) == len(set(shortcuts)), 'Duplicate workspace shortcuts'
            assert not any(item['title'] == 'Pane' for item in tree), tree
            assert any(item.get('command') == 'pane.rename' for item in workspace['children'])
            zoom = next(item for item in groups['Layout']['children'] if item.get('command') == 'pane.zoom')
            assert zoom['title'] == 'Maximize Pane', zoom
            press('cmd+shift+return')
            zoomed_tree = rpc('debug.menuTree')
            zoomed_workspace = next(item for item in zoomed_tree if item['title'] == 'Workspace')
            zoomed_layout = next(item for item in zoomed_workspace['children'] if item['title'] == 'Layout')
            assert next(item for item in zoomed_layout['children'] if item.get('command') == 'pane.zoom')['title'] == 'Restore Pane Size'
            press('cmd+shift+return')
            press('cmd+alt+d')
            layout = cli('layout', 'get')
            assert layout.get('axis') == 'horizontal' and layout.get('first') == {'kind': 'pane', 'pane': 'p2'}, (layout, rpc('debug.inspect'), rpc('config.get')['current']['keybind'])
            press('cmd+alt+right')
            assert rpc('workspace.get')['tabs'][0]['focusedPane'] == 'p1'
            press('cmd+alt+left')
            assert rpc('workspace.get')['tabs'][0]['focusedPane'] == 'p2'
            press('cmd+alt+shift+d')
            assert len(cli('panes', 'list')) == 3
            press('cmd+alt+down')
            assert rpc('workspace.get')['tabs'][0]['focusedPane'] == 'p2'
            press('cmd+alt+up')
            assert rpc('workspace.get')['tabs'][0]['focusedPane'] == 'p3'
            press('cmd+shift+e')
            assert abs(cli('layout', 'get')['fraction'] - 2 / 3) < 0.001
            press('cmd+shift+r')
            for pane in ['p2', 'p3']:
                cli('panes', 'close', '--pane', pane, '--force')

            detached_tab = cli('tabs', 'new', '--focus-policy', 'new')['tabId']
            press('cmd+ctrl+n')
            assert len(rpc('workspace.get')['groups']) == 2
            assert rpc('workspace.get')['keyTabID'] == detached_tab
            cli('tabs', 'close', '--tab', detached_tab, '--force')
            (directory / 'config.toml').write_text('[keybind]\n"cmd+shift+j" = "pane.copyID"\n"cmd+ctrl+n" = "unbound"\n')
            rpc('config.reload')
            attached_tab = cli('tabs', 'new', '--focus-policy', 'new')['tabId']
            before_unbound = rpc('workspace.get')['groups']
            press('cmd+ctrl+n')
            assert rpc('workspace.get')['groups'] == before_unbound, 'Unbound native detach still consumed the shortcut'
            cli('tabs', 'close', '--tab', attached_tab, '--force')
            before_copy = rpc('workspace.get')
            assert rpc('debug.commandClipboard') is None
            press('cmd+shift+j')
            assert rpc('debug.commandClipboard') == 'p1'
            assert rpc('workspace.get') == before_copy

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
            rpc('debug.paneTypeMenu', pane='p1', select='browser')
            assert 'browser' in cli('panes', 'list')[0]['type']
            rpc('debug.paneTypeMenu', pane='p1', select='terminal')
            assert 'terminal' in cli('panes', 'list')[0]['type']
            # Capture menus after key tests: popup tracking can consume queued key events.
            rpc('debug.menuPreview', pane='p1', path=str(ARTIFACTS / 'pane-type-dropdown.png'))
            for menu, submenu, name in [('Workspace', None, 'workspace-menu'), ('Workspace', 'Split Pane', 'split-menu'),
                                        ('Workspace', 'Focus Pane', 'focus-menu')]:
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
