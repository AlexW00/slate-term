#!/usr/bin/env python3
"""Verify TOML/UI appearance settings against the bundled Ghostty renderer."""
import json
import os
import pathlib
import re
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = pathlib.Path(os.environ.get('SLATE_TERM_TEST_APP', ROOT / '.derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal'))
CLI = APP.parent.parent / 'Helpers/slate-term'
ARTIFACTS = ROOT / 'artifacts'


def eventually(label, check):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.05)
    raise AssertionError(label)


with tempfile.TemporaryDirectory(prefix='slate-appearance-', dir='/tmp') as temporary:
    directory = pathlib.Path(temporary)
    config = directory / 'config.toml'
    config.write_text('# Preserve appearance preferences\n[appearance]\ntheme = "auto"\n')
    ready = directory / 'socket'
    env = dict(os.environ, SLATE_TERM_INTEGRATION='1', SLATE_TERM_STATE_DIR=temporary,
               SLATE_TERM_CONFIG_FILE=str(config), SLATE_TERM_SOCKET_FILE=str(ready))
    for key in ['SLATE_TERM_PANE_ID', 'SLATE_TERM_TAB_ID', 'SLATE_TERM_SOCKET']:
        env.pop(key, None)
    ARTIFACTS.mkdir(exist_ok=True)
    with (ARTIFACTS / 'appearance-process.log').open('w') as log:
        app = subprocess.Popen([str(APP)], env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            eventually('app readiness', lambda: app.poll() is None and ready.exists())
            env['SLATE_TERM_SOCKET'] = ready.read_text().strip()

            def rpc(method, **params):
                result = subprocess.run([str(CLI), 'rpc', method, '--params', json.dumps(params), '--json'],
                                        env=env, capture_output=True, text=True, timeout=25)
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)

            def capture(name, settings=True):
                time.sleep(0.4)
                rpc('debug.screenshot', settings=settings, path=str(ARTIFACTS / f'appearance-{name}.png'))

            assert rpc('config.get')['error'] is None
            assert rpc('debug.inspect')['appearanceFollowsSystem']
            before = rpc('debug.inspect')['panes'][0]['surface']
            rpc('terminal.send', pane='p1', text="stty -echo; printf '\\nAPPEARANCE_PID=%s\\n' \"$$\"\r")
            eventually('shell ready', lambda: re.search(r'APPEARANCE_PID=\d+', rpc('terminal.capture', pane='p1')['text']))
            pid = re.search(r'APPEARANCE_PID=(\d+)', rpc('terminal.capture', pane='p1')['text']).group(1)
            rpc('terminal.send', pane='p1', text="printf '\\033[2J\\033[HSlate Terminal appearance\\n\\nRegular text   \\033[1mBold text\\033[0m\\n\\033[31mRed \\033[32mGreen \\033[34mBlue \\033[35mMagenta\\033[0m\\n'\r")

            rpc('debug.activate')
            state = rpc('debug.settings', section='Appearance', theme='dark', lightTheme='Catppuccin Latte',
                        darkTheme='Catppuccin Mocha', fontThicken=True, minimumContrast='3',
                        cursorStyle='underline', cursorBlink='off', paddingX='12', paddingY='8', apply=True)
            assert state['error'] is None and not state['dirty'], state
            assert '# Preserve appearance preferences' in config.read_text()
            current = rpc('config.get')
            expected = {'font_thicken': True, 'minimum_contrast': 3, 'cursor_style': 'underline', 'cursor_blink': 'off',
                        'padding_x': 12, 'padding_y': 8, 'light_theme': 'Catppuccin Latte', 'dark_theme': 'Catppuccin Mocha'}
            assert all(current['current']['terminal'][key] == value for key, value in expected.items()), current
            assert current['restartRequired'] == ['terminal.padding_x', 'terminal.padding_y']
            assert rpc('debug.inspect')['appearance'] == 'dark'
            assert rpc('debug.inspect')['panes'][0]['surface'] == before
            engine = (directory / 'state/terminal.conf').read_text()
            for line in ['font-thicken = true', 'minimum-contrast = 3.0', 'cursor-style = underline',
                         'cursor-style-blink = false', 'window-padding-x = 12', 'window-padding-y = 8',
                         'theme = light:' + json.dumps(str(APP.parent.parent / 'Resources/ghostty/themes/Catppuccin Latte')) +
                         ',dark:' + json.dumps(str(APP.parent.parent / 'Resources/ghostty/themes/Catppuccin Mocha'))]:
                assert line in engine, (line, engine)
            capture('settings-dark')
            capture('terminal-dark', settings=False)
            rpc('debug.settings', section='Terminal', width=840, height=960)
            capture('controls-dark')
            rpc('debug.settings', width=740, height=520)
            capture('controls-compact')
            rpc('debug.settings', section='Appearance', theme='light', apply=True)
            assert rpc('debug.inspect')['appearance'] == 'light'
            capture('settings-light-compact')
            capture('terminal-light', settings=False)
            rpc('debug.settings', minimumContrast='1', apply=True)
            capture('terminal-light-original-colors', settings=False)
            rpc('debug.settings', minimumContrast='3', width=840, height=620, theme='system', apply=True)
            assert rpc('debug.inspect')['appearanceFollowsSystem']
            capture('settings-auto')

            saved = config.read_text()
            state = rpc('debug.settings', minimumContrast='22', apply=True)
            assert state['error'] and config.read_text() == saved, state
            rpc('debug.settings', section='Terminal')
            capture('invalid-contrast')
            rpc('debug.settings', revert=True)
            # An external edit refreshes clean UI fields; invalid edits retain the live configuration.
            config.write_text(saved.replace('"underline"', '"bar"'))
            eventually('external cursor reload', lambda: rpc('config.get')['current']['terminal']['cursor_style'] == 'bar')
            assert rpc('debug.settings')['values']['terminal.cursor_style'] == '"bar"'
            valid = rpc('config.get')['current']
            config.write_text('[terminal]\nminimum_contrast = nan\n')
            eventually('invalid external edit reported', lambda: rpc('config.get')['error'] is not None)
            assert rpc('config.get')['current'] == valid
            config.write_text(saved)
            eventually('valid config recovered', lambda: rpc('config.get')['error'] is None)
            rpc('debug.settings', revert=True)

            # Every exposed palette must actually be bundled and accepted in both conditional modes.
            for palette in ['Builtin Light', 'Builtin Dark', 'Catppuccin Latte', 'Catppuccin Mocha',
                            'iTerm2 Solarized Light', 'iTerm2 Solarized Dark']:
                for mode in ['light', 'dark']:
                    state = rpc('debug.settings', theme=mode, lightTheme=palette, darkTheme=palette, apply=True)
                    assert state['error'] is None, (palette, mode, state)
                    assert rpc('config.get')['error'] is None
            state = rpc('debug.settings', cursorStyle='block_hollow', cursorBlink='on', apply=True)
            assert state['error'] is None, state
            state = rpc('debug.settings', cursorStyle='block', cursorBlink='auto', apply=True)
            assert state['error'] is None, state
            assert 'cursor-style-blink = \n' in (directory / 'state/terminal.conf').read_text()
            assert rpc('debug.inspect')['panes'][0]['surface'] == before
            rpc('terminal.send', pane='p1', text="printf '\\nAFTER_APPEARANCE_PID=%s\\n' \"$$\"\r")
            eventually('same shell after rendering changes', lambda: 'AFTER_APPEARANCE_PID=' + pid in rpc('terminal.capture', pane='p1')['text'])
            # New surfaces accept the configured padding without a process restart.
            rpc('command.run', id='tab.new')
            assert all(pane['surface'] for pane in rpc('debug.inspect')['panes'])
            print('PASS: appearance modes, bundled palettes, rendering options, UI/TOML persistence, invalid-edit retention, and live PTY preservation')
        finally:
            if app.poll() is None:
                os.killpg(app.pid, signal.SIGTERM)
                try:
                    app.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(app.pid, signal.SIGKILL)
                    app.wait()
