#!/usr/bin/env python3
"""Exercise the real native Liquid Glass picker and capture its rendered states."""
import json
import os
import pathlib
import subprocess
import tempfile
import time
from plugin_package_fixture import package_fixture

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = ROOT / '.derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal'
CLI = APP.parent.parent / 'Helpers/slate-term'
ARTIFACTS = ROOT / 'artifacts'


def eventually(label, check, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.05)
    raise AssertionError(label)


with tempfile.TemporaryDirectory(prefix='slate-picker-', dir='/tmp') as temporary:
    directory = pathlib.Path(temporary)
    config = directory / 'config.toml'
    ready = directory / 'ready'
    config.write_text('[appearance]\ntheme = "dark"\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith('SLATE_TERM_')}
    env.update(SLATE_TERM_INTEGRATION='1', SLATE_TERM_STATE_DIR=temporary,
               SLATE_TERM_CONFIG_FILE=str(config), SLATE_TERM_SOCKET_FILE=str(ready))
    ARTIFACTS.mkdir(exist_ok=True)
    with (ARTIFACTS / 'command-picker-process.log').open('w') as log:
        app = subprocess.Popen([str(APP)], env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            eventually('App ready', lambda: ready.exists() and app.poll() is None)
            env['SLATE_TERM_SOCKET'] = ready.read_text().strip()

            def cli(*args):
                result = subprocess.run([str(CLI), *args, '--json'], env=env, capture_output=True, text=True, timeout=35)
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)

            def rpc(method, **params):
                return cli('rpc', method, '--params', json.dumps(params))

            def picker(**params):
                return rpc('debug.commandPicker', **params)

            def key(chord, **params):
                return rpc('debug.key', chord=chord, picker=True, dispatch=True, **params)

            def activate_workspace(tab='t1'):
                rpc('debug.activate', tab=tab)
                def active():
                    state = rpc('debug.inspect')
                    return state['applicationActive'] and any(w['tabId'] == tab and w['key'] for w in state['windows'])
                eventually('Owned workspace activation before input', active)

            def capture(name, context=False):
                # Allow native appearance/material transitions to settle before captures.
                time.sleep(.7)
                try:
                    rpc('debug.screenshot', picker=True, pickerContext=True, pickerCrop=not context, path=str(ARTIFACTS / name))
                except AssertionError:
                    print('PICKER_CAPTURE_STATE', picker(), flush=True)
                    raise

            # A real command fixture, not a fake built-in action.
            marker = directory / 'context.json'
            manifest = directory / 'plugin.json'
            manifest.write_text(json.dumps(dict(id='project-tools', title='Project Tools', commands=[
                dict(id='inspect', title='Inspect Workspace', executable='/bin/sh',
                     arguments=['-c', '"$SLATE_TERM_CLI" context get > "$MARKER"'], environment={'MARKER': str(marker)})])))
            package = package_fixture(manifest, directory)
            cli('plugins', 'register', '--package', package)
            cli('panes', 'send', '--pane', 'p1', '--text', "printf '\\033[36mSlate Terminal\\033[0m  /  workspace\\n\\n  Ready for your next command.\\n'\r")
            activate_workspace()
            rpc('debug.key', chord='cmd+k')
            state = picker()
            assert state['visible'] and state['glass']
            assert state['attachedToSource'] and state['insideSource'] and abs(state['centerOffsetX']) < .5 and abs(state['centerOffsetY']) < .5, state
            assert state['executeLabel'] == 'Execute Command'
            assert all(r['enabled'] for r in state['results'])
            assert not any((r['id'].startswith('browser.') and r['id'] != 'browser.clearData') or r['id'] == 'tab.select8' for r in state['results'])
            assert any(r['id'] == 'browser.clearData' and r['enabled'] for r in state['results'])
            assert any(r['id'] == 'plugin.project-tools.inspect' for r in state['results'])
            assert not any(r['id'] in ['command.picker', 'pane.type', 'pane.focus', 'tab.focus'] for r in state['results'])
            capture('command-picker-dark.png')
            capture('command-picker-dark-context.png', context=True)
            # Idle catalog refreshes must leave a manually scrolled list in place.
            selected = picker()['selected']
            picker(scrollDelta=-480)
            eventually('Native wheel scroll moves the command list', lambda: picker()['scrollY'] > 200)
            scrolled = picker()['scrollY']
            stable_until = time.monotonic() + 2.5
            while time.monotonic() < stable_until:
                state = picker()
                assert abs(state['scrollY'] - scrolled) < 1, ('Idle refresh reset the scroll position', scrolled, state)
                assert state['selected'] == selected
                time.sleep(.05)
            rpc('plugins.register', packagePath=package_fixture(dict(id='scroll-refresh', title='Scroll Refresh', commands=[
                dict(id='check', title='Scroll Refresh Check', executable='/usr/bin/true')]), directory))
            state = picker()
            assert any(r['id'] == 'plugin.scroll-refresh.check' for r in state['results'])
            assert abs(state['scrollY'] - scrolled) < 1, ('Changed catalog reset the scroll position', scrolled, state)
            key('down')
            assert picker()['scrollY'] < scrolled, 'Keyboard navigation must still reveal its selected row'
            picker(scrollDelta=-480)
            eventually('Second native wheel scroll', lambda: picker()['scrollY'] > 200)
            state = picker(query='split')
            assert state['scrollY'] < 1 and state['selected'] == 'split.right', state
            picker(query='')
            state = picker(sourceWidth=500, sourceHeight=400)
            assert state['attachedToSource'] and state['insideSource'] and abs(state['centerOffsetX']) < .5 and abs(state['centerOffsetY']) < .5, state
            capture('command-picker-compact-context.png', context=True)
            picker(sourceWidth=1000, sourceHeight=650)
            # First click selects, a subsequent click executes; editing the query resets it.
            before_copy = rpc('workspace.get')
            picker(query='copy pane id')
            picker(clickRow=0)
            clicked = picker()
            assert clicked['visible'] and clicked['searchFocused'], (clicked, rpc('debug.commandClipboard'))
            assert rpc('debug.commandClipboard') is None
            picker(query='copy pane')
            picker(clickRow=0)
            assert picker()['visible'], 'A new query must reset click-to-execute state'
            picker(clickRow=0, doubleClick=True)
            # The fixture posts mouse-up; AppKit may finish the double-click action
            # after the RPC returns. Observe completion without replaying the click.
            eventually('Second click executes captured copy action',
                       lambda: not picker()['visible'] and rpc('debug.commandClipboard') == 'p1')
            assert rpc('workspace.get') == before_copy
            rpc('debug.key', chord='cmd+k')
            key('s')
            eventually('Search field accepts real typing', lambda: picker()['query'] == 's')
            state = picker(query='split')
            # Exact title matches precede looser fuzzy matches (including the
            # application-font commands added to the shared registry).
            assert [r['id'] for r in state['results'][:4]] == [
                'split.right', 'split.down', 'split.left', 'split.up'], state
            assert state['selected'] == 'split.right'
            key('down')
            assert picker()['selected'] == 'split.down'
            capture('command-picker-search.png')
            before = len(rpc('workspace.get')['panes'])
            key('return')
            assert not picker()['visible']
            assert len(rpc('workspace.get')['panes']) == before + 1

            rpc('debug.key', chord='cmd+k')
            state = picker(query='project')
            assert [r['id'] for r in state['results']] == ['plugin.project-tools.inspect']
            capture('command-picker-plugin.png')
            target = rpc('workspace.get')['tabs'][0]['focusedPane']
            other = cli('tabs', 'new')['tabId']
            # Observe across AppKit's deferred tab updates, not only the RPC turn.
            stable_until = time.monotonic() + 1
            while time.monotonic() < stable_until:
                state = picker()
                assert state['visible'] and state['searchFocused'] and state['keyWindow'], ('Background mutation stole picker input', state)
                time.sleep(.05)
            key('return')
            # Shell redirection creates the marker before the CLI writes JSON.
            eventually('Picker invokes plugin command', lambda: any(run['state'] == 'succeeded' for run in cli('plugins', 'status', 'project-tools')))
            assert json.loads(marker.read_text())['focusedPaneId'] == target
            cli('tabs', 'close', '--tab', other, '--force')
            activate_workspace()
            rpc('debug.key', chord='cmd+k')
            state = picker(query='browser')
            assert [r['id'] for r in state['results']] == ['browser.clearData'], state
            assert state['results'][0]['enabled'], 'App-wide browser data clearing remains available from terminals'
            # Pane-specific browser actions are unavailable, unlike the global profile command.
            state = picker(query='reload page')
            assert state['results'] == [], 'Browser page commands must be hidden for terminals'
            capture('command-picker-unavailable.png')
            key('return')
            assert picker()['visible'], 'Empty results must not execute or close'
            picker(query='split')
            picker(clickRow=0)
            assert picker()['visible'] and picker()['searchFocused']
            key('down')
            key('up')
            picker(clickRow=0)
            assert picker()['visible'], 'Keyboard navigation must reset mouse activation'
            key('s')
            assert picker()['query'] == 'splits'
            picker(query='no-such-command-xyz')
            assert picker()['results'] == []
            capture('command-picker-empty.png')
            key('escape')
            assert not picker()['visible']
            assert any(p['terminalFocus'] for p in rpc('debug.inspect')['panes'])

            rpc('debug.key', chord='cmd+k')
            key('cmd+k')
            assert not picker()['visible'], 'Shortcut should toggle picker from its search field'
            # Configured shortcuts use the captured target and dismiss, even if
            # background mutations change model focus while the picker is open.
            rpc('debug.key', chord='cmd+k')
            other = cli('tabs', 'new')['tabId']
            key('cmd+shift+return')
            assert not picker()['visible']
            assert next(t for t in rpc('workspace.get')['tabs'] if t['id'] == 't1')['zoomedPane'] == target
            cli('tabs', 'close', '--tab', other, '--force')
            activate_workspace()
            rpc('debug.key', chord='cmd+k')
            assert next(r for r in picker()['results'] if r['id'] == 'pane.zoom')['title'] == 'Restore Pane Size'
            key('cmd+shift+return')
            assert not picker()['visible']
            rpc('debug.key', chord='cmd+k')
            assert next(r for r in picker()['results'] if r['id'] == 'pane.zoom')['title'] == 'Maximize Pane'
            key('cmd+alt+up')
            assert not picker()['visible'], 'Directional focus shortcuts must dismiss'
            cli('command', 'run', 'pane.focus', '--pane', target)
            rpc('debug.key', chord='cmd+k')
            picker(query='rename pane')
            assert picker()['selected'] == 'pane.rename'
            key('return')
            assert not picker()['visible'] and rpc('debug.paneHeader', pane=target)['editing']
            rpc('debug.paneHeader', pane=target, finish='cancel')
            # Live catalog changes should neither stale-select nor execute removed commands.
            rpc('debug.key', chord='cmd+k')
            picker(query='project')
            cli('plugins', 'unregister', 'project-tools')
            assert picker()['results'] == []
            cli('plugins', 'register', '--package', package)
            assert picker()['selected'] == 'plugin.project-tools.inspect'
            picker(dismiss=True)

            # Light appearance uses the same native glass, not a separate opaque mock.
            config.write_text('[appearance]\ntheme = "light"\n')
            rpc('config.reload')
            rpc('debug.key', chord='cmd+k')
            picker(query='')
            capture('command-picker-light.png')
            capture('command-picker-light-context.png', context=True)
            picker(query='new tab')
            capture('command-picker-light-search.png')
            key('escape')
            # A closed target becomes unavailable without redirecting the action.
            rpc('debug.key', chord='cmd+k')
            picker(query='split right')
            cli('panes', 'close', '--pane', target, '--force')
            state = picker()
            # Global actions such as Spotlight may fuzzy-match; stale split targets must not.
            assert state['visible'] and not any(r['id'].startswith('split.') for r in state['results']), state
            key('escape')
            # Running plugin commands update availability without reopening the picker.
            rpc('plugins.register', packagePath=package_fixture(dict(id='busy', title='Busy Fixture', commands=[
                dict(id='wait', title='Wait Briefly', executable='/bin/sleep', arguments=['2'])]), directory))
            job = subprocess.Popen([str(CLI), 'command', 'run', 'plugin.busy.wait'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                eventually('Busy command running', lambda: any(r['state'] == 'running' for r in cli('plugins', 'status', 'busy')))
                rpc('debug.key', chord='cmd+k')
                assert picker(query='busy')['results'] == [], 'Running commands must be hidden'
                stdout, stderr = job.communicate(timeout=10)
                assert job.returncode == 0, stderr
                eventually('Completed command reappears', lambda: len(picker()['results']) == 1)
                picker(clickRow=0)
                assert picker()['visible'], 'First mouse click must only select'
                time.sleep(.7)
                picker(clickRow=0)
                eventually('A later second click executes without double-click timing',
                           lambda: not picker()['visible'])
                eventually('Mouse-invoked command finishes', lambda: cli('plugins', 'status', 'busy')[-1]['state'] == 'succeeded')
            finally:
                if job.poll() is None: job.terminate(); job.communicate(timeout=10)
            # App command from picker and configurable shortcut/reset behavior.
            rpc('debug.key', chord='cmd+k')
            picker(query='settings')
            assert picker()['selected'] == 'settings.open'
            key('return')
            assert not picker()['visible']
            assert rpc('debug.settings', inspectOnly=True)['visible']
            before_close = rpc('workspace.get')
            rpc('debug.key', chord='cmd+w', settings=True, dispatch=True)
            assert not rpc('debug.settings', inspectOnly=True)['visible']
            assert rpc('workspace.get') == before_close, 'Closing Settings must not close a pane'
            config.write_text('[appearance]\ntheme = "dark"\n[keybind]\n"cmd+k" = "unbound"\n"cmd+shift+k" = "command.picker"\n"cmd+alt+s" = "settings.open"\n')
            rpc('config.reload')
            cli('command', 'run', 'tab.focus', '--tab', 't1')
            activate_workspace()
            rpc('debug.key', chord='cmd+shift+k')
            assert picker()['visible']
            key('cmd+alt+s')
            state = picker()
            assert not state['visible'], ('Alternative Settings bindings must work outside workspace windows', state)
            # No-window use still offers creation and application commands.
            for tab in rpc('workspace.get')['tabs']:
                cli('tabs', 'close', '--tab', tab['id'], '--force')
            rpc('debug.key', chord='cmd+alt+s', menu=True)
            # Capture of no workspace must remain empty if a background client creates one.
            context_marker = directory / 'empty-context'
            rpc('plugins.register', packagePath=package_fixture(dict(id='context-fixture', title='Context Fixture', commands=[
                dict(id='capture', title='Capture Target', executable='/bin/sh',
                     arguments=['-c', 'printf "%s/%s" "${SLATE_TERM_TAB_ID-unset}" "${SLATE_TERM_PANE_ID-unset}" > "$MARKER"'],
                     environment={'MARKER': str(context_marker)})]), directory))
            cli('command', 'run', 'command.picker')
            picker(query='capture target')
            background_tab = cli('command', 'run', 'window.new')['tabId']
            assert picker()['visible']
            key('return')
            eventually('Windowless command completed', lambda: any(run['state'] == 'succeeded' for run in cli('plugins', 'status', 'context-fixture')))
            assert context_marker.read_text() == 'unset/unset'
            cli('tabs', 'close', '--tab', background_tab, '--force')
            cli('command', 'run', 'command.picker')
            picker(query='new tab')
            cli('command', 'run', 'window.new')
            key('return')
            assert len(rpc('workspace.get')['groups']) == 2, 'Windowless New Tab must not join a newly created background window'
            for tab in rpc('workspace.get')['tabs']:
                cli('tabs', 'close', '--tab', tab['id'], '--force')
            cli('command', 'run', 'command.picker')
            state = picker(query='split right')
            assert state['visible'] and not any(r['id'].startswith('split.') for r in state['results']), state
            picker(query='new window')
            assert picker()['selected'] == 'window.new'
            key('return')
            assert len(rpc('workspace.get')['tabs']) == 1
            # Small owners dismiss instead of overflowing; closing the owner cleans up attachment/observation.
            picker(show=True)
            state = picker(sourceWidth=300, sourceHeight=200)
            assert not state['visible'] and not state['trackingSource'], state
            state = picker(sourceWidth=1000, sourceHeight=650, show=True)
            assert state['visible'] and state['attachedToSource'], state
            owner = rpc('workspace.get')['tabs'][0]['id']
            cli('tabs', 'close', '--tab', owner, '--force')
            state = picker()
            assert not state['visible'] and not state['attachedToSource'] and not state['trackingSource'], state
            print('PASS command picker: native glass, text input, search, keyboard selection/activation, plugin commands, context/busy availability, catalog refresh, themes, editor/frozen-target focus, two-click activation, copy-ID command, centered placement, hidden unavailable actions, shortcut remapping and windowless use.')
        except Exception:
            if ready.exists() and app.poll() is None:
                print('PICKER_FAILURE_STATE', picker(), 'clipboard:', rpc('debug.commandClipboard'), flush=True)
                print('PICKER_FAILURE_WORKSPACE', rpc('debug.inspect'), flush=True)
            raise
        finally:
            app.terminate()
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                app.kill(); app.wait()
