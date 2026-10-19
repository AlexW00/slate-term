#!/usr/bin/env python3
"""Exercise native settings persistence and navigation with an isolated app instance."""
import http.server
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import threading
import time
from plugin_package_fixture import package_fixture

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


class Page(http.server.BaseHTTPRequestHandler):
    requests = 0

    def do_GET(self):
        Page.requests += 1
        body = f'<title>{self.path}</title><h1>Browser navigation fixture</h1>'.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Page) as server:
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='slate-settings-ui-', dir='/tmp') as temporary:
        directory = pathlib.Path(temporary)
        config = directory / 'config.toml'
        config.write_text('# Keep my preferences\n[terminal]\nfont_size = 13 # points\n')
        ready = directory / 'socket'
        env = dict(os.environ, SLATE_TERM_INTEGRATION='1', SLATE_TERM_STATE_DIR=temporary,
                   SLATE_TERM_CONFIG_FILE=str(config), SLATE_TERM_SOCKET_FILE=str(ready))
        for key in ['SLATE_TERM_PANE_ID', 'SLATE_TERM_TAB_ID', 'SLATE_TERM_SOCKET']:
            env.pop(key, None)
        with (ROOT / 'artifacts/settings-window-process.log').open('w') as log:
            app = subprocess.Popen([str(APP)], env=env, stdout=log, stderr=log, start_new_session=True)
            try:
                eventually('app readiness', lambda: app.poll() is None and ready.exists())
                env['SLATE_TERM_SOCKET'] = ready.read_text().strip()

                def rpc(method, **params):
                    result = subprocess.run([str(CLI), 'rpc', method, '--params', json.dumps(params), '--json'],
                                            env=env, capture_output=True, text=True, timeout=25)
                    assert result.returncode == 0, result.stderr
                    return json.loads(result.stdout)

                def command(name, **params):
                    return rpc('command.run', id=name, **params)

                rpc('debug.activate')
                rpc('debug.key', chord='cmd+,')
                state = rpc('debug.settings')
                assert not state['pluginsMenu'] and not state['dirty'], state
                state = rpc('debug.settings', fontSize='17', apply=True)
                assert state['error'] is None and not state['dirty'], state
                assert '# Keep my preferences' in config.read_text() and '# points' in config.read_text()
                assert rpc('config.get')['current']['terminal']['font_size'] == 17
                rpc('debug.settings', section='Appearance', unfocusedPaneDim=0.35)
                assert rpc('config.get')['current']['appearance']['unfocused_pane_dim'] == 0.08
                rpc('debug.settings', revert=True)
                assert rpc('debug.settings')['values']['appearance.unfocused_pane_dim'] == '0.08'
                state = rpc('debug.settings', unfocusedPaneDim=0.35, apply=True)
                assert state['error'] is None and not state['dirty'], state
                assert rpc('config.get')['current']['appearance']['unfocused_pane_dim'] == 0.35
                time.sleep(0.3)
                rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-pane-dimming.png'))
                saved = config.read_text()
                state = rpc('debug.settings', fontSize='0', apply=True)
                assert state['error'] and config.read_text() == saved
                rpc('debug.settings', revert=True)
                rpc('debug.settings', fontSize='18')
                config.write_text(saved.replace('17 # points', '19 # points'))
                eventually('external config reload', lambda: rpc('config.get')['current']['terminal']['font_size'] == 19)
                state = rpc('debug.settings', apply=True)
                assert 'changed outside Settings' in state['error'], state
                rpc('debug.settings', revert=True)
                search = 'https://duckduckgo.com/?q={query}'
                assert rpc('debug.settings', searchURL=search, apply=True)['error'] is None
                assert rpc('config.get')['current']['browser']['search_url'] == search
                state = rpc('debug.settings', workingDirectory='~/Projects', inheritWorkingDirectory=False, apply=True)
                assert state['error'] is None and not state['dirty'], state
                terminal = rpc('config.get')['current']['terminal']
                assert terminal['working_directory'] == '~/Projects' and terminal['inherit_working_directory'] is False
                state = rpc('debug.settings', section='Terminal', inheritWorkingDirectory=True)
                assert not state['showsDefaultDirectory'] and state['workingDirectory'] == '~/Projects'
                time.sleep(0.3)
                rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-terminal-inherited.png'))
                state = rpc('debug.settings', inheritWorkingDirectory=False)
                assert state['showsDefaultDirectory'] and state['workingDirectory'] == '~/Projects'
                time.sleep(0.3)
                rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-terminal-default.png'))
                rpc('debug.settings', workingDirectory='~', inheritWorkingDirectory=True, apply=True)
                for section in ['General', 'Terminal', 'Browser', 'Keyboard Shortcuts', 'Plugins']:
                    rpc('debug.settings', section=section)
                    time.sleep(0.3)
                    rpc('debug.screenshot', settings=True, path=str(ROOT / f'artifacts/settings-{section.lower().replace(" ", "-")}.png'))

                state = rpc('debug.settings', section='Browser')
                assert state['browserSites'] == [] and not state['canClearBrowserSite']
                rpc('debug.settings', width=1000, height=560)
                time.sleep(0.4)
                rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-browser-empty-small.png'))
                rpc('debug.settings', width=1060, height=680)

                command('pane.type', pane='p1', type='browser', force=True)
                site = f'http://127.0.0.1:{server.server_port}/settings'
                rpc('browser.navigate', pane='p1', url=site)
                rpc('browser.eval', pane='p1', script='localStorage.setItem("fixture","stored");true')
                command('pane.type', pane='p1', type='terminal', force=True)
                rpc('debug.settings', section='Browser', refreshBrowserSites=True, width=1060, height=680)
                eventually('stored sites loaded', lambda: '127.0.0.1' in rpc('debug.settings')['browserSites'] and not rpc('debug.settings')['loadingBrowserSites'])
                state = rpc('debug.settings', browserSite='127.0.0.1')
                assert state['canClearBrowserSite'], state
                time.sleep(0.4)
                rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-browser-populated.png'))
                rpc('debug.settings', width=1000, height=560)
                time.sleep(0.4)
                rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-browser-populated-small.png'))

                print('PASS requested settings: directory visibility/value retention and stored sites without browser panes', flush=True)

                state = rpc('debug.settings', section='Keyboard Shortcuts')
                assert not state['hasToolbar'], 'Settings should not install a collapsing navigation toolbar'
                time.sleep(0.4)
                rpc('debug.settings', recordAction='New Tab', recordPrevious='cmd+t')
                rpc('debug.key', settings=True, chord='cmd+alt+t', dispatch=True)
                state = rpc('debug.settings', apply=True)
                assert state['error'] is None and state['shortcuts'].get('cmd+alt+t') == 'tab.new', state
                assert 'cmd+t' not in state['shortcuts'], state
                assert rpc('config.get')['current']['keybind']['cmd+alt+t'] == 'tab.new'
                time.sleep(0.3)
                rpc('debug.settings', recordAction='New Tab', recordPrevious='cmd+alt+t')
                rpc('debug.key', settings=True, chord='cmd+n', dispatch=True)
                state = rpc('debug.settings')
                assert state['error'] and 'already assigned' in state['error'] and state['shortcuts']['cmd+n'] == 'window.new', state
                rpc('debug.settings', revert=True)
                rpc('debug.settings', recordAction='New Tab', recordPrevious='cmd+alt+t')
                rpc('debug.key', settings=True, chord='escape', dispatch=True)
                assert not rpc('debug.settings')['dirty']
                rpc('debug.settings', recordAction='New Tab', recordPrevious='cmd+alt+t')
                rpc('debug.key', settings=True, chord='cmd+q', dispatch=True)
                assert rpc('debug.settings')['shortcuts']['cmd+q'] == 'tab.new', 'Recording must intercept Quit'
                rpc('debug.settings', revert=True)
                state = rpc('debug.settings', resetAction='tab.new', apply=True)
                assert state['shortcuts']['cmd+t'] == 'tab.new' and 'cmd+alt+t' not in state['shortcuts'], state
                assert 'cmd+alt+t' not in rpc('config.get')['current']['keybind']
                rpc('debug.settings', section='General', width=740, height=520)
                time.sleep(0.5)
                rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-general-small.png'))
                rpc('plugins.register', packagePath=package_fixture({'id': 'settings-status-fixture', 'title': 'Status Fixture',
                    'source': {'kind': 'url', 'url': f'http://127.0.0.1:{server.server_port}/plugin'}, 'scope': 'pane'}, directory))
                state = rpc('debug.settings', section='Plugins')
                assert state['pluginStatuses'] == ['Not running'], state
                time.sleep(0.4)
                rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-plugin-status.png'))
                rpc('debug.settings', width=840, height=620)
                rpc('debug.settings', section='General', theme='light', apply=True)
                time.sleep(0.6)
                rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/settings-general-light.png'))
                rpc('debug.activate')
                second = command('tab.new')['tabId']
                rpc('debug.key', chord='cmd+1')
                eventually('first tab selected', lambda: rpc('workspace.get')['keyTabID'] == 't1')
                rpc('debug.key', chord='cmd+shift+]')
                eventually('second tab selected', lambda: rpc('workspace.get')['keyTabID'] == second)
                rpc('debug.key', chord='cmd+shift+[')
                eventually('first tab selected', lambda: rpc('workspace.get')['keyTabID'] == 't1')
                rpc('debug.key', chord='cmd+2')
                eventually('second tab selected', lambda: rpc('workspace.get')['keyTabID'] == second)
                command('tab.select1')
                command('pane.type', type='browser', force=True)
                base = f'http://127.0.0.1:{server.server_port}'
                rpc('browser.navigate', pane='p1', url=base + '/first')
                rpc('browser.navigate', pane='p1', url=base + '/second')
                rpc('debug.key', chord='cmd+[')
                eventually('browser back', lambda: rpc('browser.get', pane='p1')['url'] == base + '/first')
                rpc('debug.key', chord='cmd+]')
                eventually('browser forward', lambda: rpc('browser.get', pane='p1')['url'] == base + '/second')
                count = Page.requests
                rpc('debug.key', chord='cmd+r')
                eventually('browser reload', lambda: Page.requests > count)
                rpc('debug.key', chord='cmd+l')
                panes = rpc('debug.inspect')['panes']
                assert next(p for p in panes if p['paneId'] == 'p1')['browser']['addressFocused']
                eventually('browser finished reloading', lambda: not rpc('browser.get', pane='p1')['loading'])
                right = command('split.right')['paneId']
                eventually('new pane focused', lambda: next(t for t in rpc('workspace.get')['tabs'] if t['id'] == 't1')['focusedPane'] == right)
                rpc('debug.key', chord='ctrl+alt+h')
                eventually('focus left shortcut', lambda: next(t for t in rpc('workspace.get')['tabs'] if t['id'] == 't1')['focusedPane'] == 'p1')
                rpc('debug.key', chord='ctrl+alt+l')
                eventually('right pane focused', lambda: next(t for t in rpc('workspace.get')['tabs'] if t['id'] == 't1')['focusedPane'] == right)
                bottom = command('split.down')['paneId']
                rpc('debug.key', chord='ctrl+alt+k')
                eventually('right pane focused', lambda: next(t for t in rpc('workspace.get')['tabs'] if t['id'] == 't1')['focusedPane'] == right)
                rpc('debug.key', chord='ctrl+alt+j')
                eventually('bottom pane focused', lambda: next(t for t in rpc('workspace.get')['tabs'] if t['id'] == 't1')['focusedPane'] == bottom)
                print('PASS: settings persistence, validation, conflicts, native sections, browser and workspace shortcuts')
            finally:
                if app.poll() is None:
                    os.killpg(app.pid, signal.SIGTERM)
                    try:
                        app.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(app.pid, signal.SIGKILL)
                        app.wait()
    server.shutdown()
