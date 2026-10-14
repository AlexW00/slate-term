#!/usr/bin/env python3
"""Owned native app: manifest header contributions, matching, routing and lifetime."""
import json
import os
import pathlib
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / '.derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal'
CLI = APP.parent.parent / 'Helpers/slate-term'
ARTIFACTS = ROOT / 'artifacts'


def eventually(label, check, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.05)
    raise AssertionError(label)


with tempfile.TemporaryDirectory(prefix='slate-header-buttons-', dir='/tmp') as temporary:
    directory = pathlib.Path(temporary)
    ready = directory / 'ready'
    config = directory / 'config.toml'
    config.write_text('[appearance]\ntheme = "light"\n')
    marker = directory / 'target'
    env = {k: v for k, v in os.environ.items() if not k.startswith('SLATE_TERM_')}
    env.update(SLATE_TERM_INTEGRATION='1', SLATE_TERM_STATE_DIR=temporary,
               SLATE_TERM_CONFIG_FILE=str(config), SLATE_TERM_SOCKET_FILE=str(ready))
    ARTIFACTS.mkdir(exist_ok=True)
    with (ARTIFACTS / 'plugin-header-buttons-process.log').open('w') as log:
        app = None
        try:
            def start():
                global app
                ready.unlink(missing_ok=True)
                app = subprocess.Popen([str(APP)], env=env, stdout=log, stderr=log, start_new_session=True)
                eventually('App readiness', lambda: ready.exists() and app.poll() is None)
                env['SLATE_TERM_SOCKET'] = ready.read_text().strip()

            def stop():
                if app is not None and app.poll() is None:
                    app.terminate()
                    try:
                        app.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        app.kill(); app.wait(timeout=5)

            def cli(*args, ok=True):
                result = subprocess.run([str(CLI), *args, '--json'], env=env, capture_output=True, text=True, timeout=30)
                if not ok:
                    assert result.returncode != 0, result.stdout
                    return result.stderr
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)

            def rpc(method, **params):
                return cli('rpc', method, '--params', json.dumps(params))

            def header(pane):
                value = rpc('debug.paneHeader', pane=pane)
                assert value['closeVisible'] and value['actionsBeforeClose'], value
                assert 'copyIDVisible' not in value, value
                return value

            def ids(pane):
                return [a['id'].removeprefix('plugin.header-tools.header.') for a in header(pane)['headerActions']]

            def click(pane, button, tab='t1'):
                marker.unlink(missing_ok=True)
                before = rpc('workspace.get')
                rpc('debug.paneHeader', pane=pane, clickAction='plugin.header-tools.header.' + button)
                eventually('Command receives clicked pane', lambda: marker.exists() and marker.read_text() == f'{tab}/{pane}')
                eventually('Header reflects running state', lambda: all(not a['enabled'] for a in header(pane)['headerActions']))
                count = len(cli('plugins', 'status', 'header-tools'))
                rpc('debug.paneHeader', pane=pane, clickAction='plugin.header-tools.header.' + button)
                assert len(cli('plugins', 'status', 'header-tools')) == count, 'Busy action launched a duplicate'
                eventually('Command completes and buttons re-enable', lambda: all(a['enabled'] for a in header(pane)['headerActions']))
                assert rpc('workspace.get') == before, 'Header callback changed focus or layout before its script requested it'
                assert rpc('debug.commandClipboard') is None, 'Header checks must not touch the clipboard'

            def capture(name):
                rpc('debug.activate', tab='t1')
                time.sleep(1)
                path = ARTIFACTS / name
                rpc('debug.screenshot', path=str(path))
                dimensions = subprocess.run(['sips', '-g', 'pixelWidth', str(path)], check=True, text=True, capture_output=True, timeout=5).stdout
                assert int(dimensions.split('pixelWidth: ')[1].splitlines()[0]) >= 1000, 'Capture caught a desktop/window transition: ' + dimensions

            start()
            buttons = [dict(id='all', title='Inspect Pane', symbol='info.circle', command='capture'),
                       dict(id='terminal', title='Terminal Action', symbol='terminal', command='capture', paneTypes=['terminal']),
                       dict(id='browser', title='Browser Action', symbol='globe', command='capture', paneTypes=['browser']),
                       dict(id='widget', title='Notes Action', symbol='note.text', command='capture', paneTypes=['notes-panel'])]
            for name in ['extra-a', 'extra-b', 'extra-c']:
                buttons.append(dict(id=name, title=name.replace('-', ' ').title(), symbol='bolt', command='capture'))
            manifest = dict(id='header-tools', title='Header Tools', commands=[
                dict(id='capture', title='Capture Pane Context', executable='/bin/sh',
                     arguments=['-c', 'printf "%s/%s" "$SLATE_TERM_TAB_ID" "$SLATE_TERM_PANE_ID" > "$MARKER"; /bin/sleep 1'],
                     environment={'MARKER': str(marker)})], headerButtons=buttons)
            rpc('plugins.register', manifest=manifest)
            assert cli('plugins', 'status', 'header-tools') == [], 'Buttons must not start a hidden service or panel'
            assert ids('p1') == ['all', 'terminal', 'extra-a', 'extra-b', 'extra-c']
            click('p1', 'all')
            click('p1', 'extra-c')  # Actual overflow-menu dispatch.
            p2 = cli('panes', 'split', '--right', '--pane', 'p1')['paneId']
            assert rpc('workspace.get')['tabs'][0]['focusedPane'] == p2
            click('p1', 'terminal')  # Unfocused sibling must still be the target.
            cli('panes', 'type', '--pane', p2, '--type', 'browser', '--force')
            assert ids(p2) == ['all', 'browser', 'extra-a', 'extra-b', 'extra-c']
            click(p2, 'browser')
            capture('plugin-header-buttons-light.png')
            config.write_text('[appearance]\ntheme = "dark"\n')
            rpc('config.reload')
            capture('plugin-header-buttons-dark.png')
            rpc('debug.divider', tab='t1', fraction=.25)
            assert header('p1')['visibleHeaderActions'] == ['overflow']
            click('p1', 'all')
            capture('plugin-header-buttons-narrow.png')
            rpc('debug.divider', tab='t1', fraction=.5)

            # Plugin widget selectors may refer to types registered later.
            panel = directory / 'panel'
            panel.mkdir()
            (panel / 'index.html').write_text('<!doctype html><title>Notes</title><p>Plugin widget fixture</p>')
            rpc('plugins.register', manifest=dict(id='notes-panel', title='Notes', source=dict(kind='directory', path=str(panel))))
            cli('panes', 'type', '--pane', p2, '--type', 'notes-panel', '--force')
            assert ids(p2) == ['all', 'widget', 'extra-a', 'extra-b', 'extra-c']
            click(p2, 'widget')
            other = cli('command', 'run', 'window.new')['tabId']
            click('p1', 'all')  # Another native window is now key.
            cli('tabs', 'close', '--tab', other, '--force')

            # Registrations persist; command-only UI contributions need no live owner view.
            stop()
            start()
            eventually('Restored headers', lambda: ids(p2) == ['all', 'widget', 'extra-a', 'extra-b', 'extra-c'])
            click(p2, 'widget')
            changed = dict(manifest, headerButtons=[dict(buttons[0], paneTypes=['browser'])])
            rpc('plugins.register', manifest=changed, replace=True)
            assert ids('p1') == [] and ids(p2) == [], 'Replaced selectors left stale buttons'
            cli('panes', 'type', '--pane', p2, '--type', 'browser', '--force')
            assert ids(p2) == ['all']
            click(p2, 'all')
            marker.unlink(missing_ok=True)
            rpc('debug.paneHeader', pane=p2, clickAction='plugin.header-tools.header.all')
            eventually('Running before unregister', lambda: marker.exists() and cli('plugins', 'status', 'header-tools')[-1]['state'] == 'running')
            cli('plugins', 'unregister', 'header-tools')
            eventually('Unregister cancels the owned command', lambda: cli('plugins', 'status', 'header-tools')[-1]['state'] == 'cancelled')
            assert header('p1')['headerActions'] == [] and header(p2)['headerActions'] == []
            assert header(p2)['visibleHeaderActions'] == []
            cli('rpc', 'debug.paneHeader', '--params', json.dumps(dict(pane=p2, clickAction='plugin.header-tools.header.all')), ok=False)
            # Failed manifests are atomic and do not leave any UI contributions.
            bad = dict(manifest, headerButtons=[dict(buttons[0], command='missing')])
            cli('rpc', 'plugins.register', '--params', json.dumps(dict(manifest=bad)), ok=False)
            assert header(p2)['headerActions'] == []
            print('PASS plugin header buttons: all/builtin/widget selectors, exact clicked-pane routing, direct/overflow dispatch, busy state, no hidden service, persistence, live replacement/removal, and light/dark/narrow renders')
        finally:
            if app is not None and app.poll() is None:
                app.terminate()
                try:
                    app.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    app.kill(); app.wait(timeout=5)
