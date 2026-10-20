#!/usr/bin/env python3
"""Exercise bundled and custom color-only palettes in the native renderer and UI."""
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


def eventually(label, check):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.05)
    raise AssertionError(label)


with tempfile.TemporaryDirectory(prefix='slate,palettes-"', dir='/tmp') as temporary:
    directory = pathlib.Path(temporary)
    config = directory / 'configuration/config.toml'
    library = config.parent / 'palettes'
    library.mkdir(parents=True)
    light = library / 'My Light.conf'
    dark = library / 'My Dark.conf'
    light.write_text('background = #fff7ed\nforeground = #292524\ncursor-color = #9a3412\npalette = 1=#b91c1c\npalette = 2=#15803d\npalette = 4=#1d4ed8\n')
    dark.write_text('background = #102a2c\nforeground = #dcfce7\ncursor-color = #86efac\npalette = 1=#f87171\n')
    config.write_text('# My palettes\n[appearance]\ntheme = "dark"\n[terminal]\nlight_theme = "My Light"\ndark_theme = "My Dark"\n')
    ready = directory / 'socket'
    userThemes = directory / 'xdg/ghostty/themes'
    userThemes.mkdir(parents=True)
    (userThemes / 'Nord').write_text('not-a-valid-setting = true\n')
    env = dict(os.environ, SLATE_TERM_INTEGRATION='1', SLATE_TERM_STATE_DIR=temporary,
               SLATE_TERM_CONFIG_FILE=str(config), SLATE_TERM_SOCKET_FILE=str(ready), XDG_CONFIG_HOME=str(directory / 'xdg'))
    for key in ['SLATE_TERM_PANE_ID', 'SLATE_TERM_TAB_ID', 'SLATE_TERM_SOCKET']:
        env.pop(key, None)
    ARTIFACTS.mkdir(exist_ok=True)
    app = None
    with (ARTIFACTS / 'palettes-process.log').open('w') as log:
        def start():
            global app
            ready.unlink(missing_ok=True)
            app = subprocess.Popen([str(APP)], env=env, stdout=log, stderr=log, start_new_session=True)
            eventually('app readiness', lambda: app.poll() is None and ready.exists())
            env['SLATE_TERM_SOCKET'] = ready.read_text().strip()

        def stop():
            global app
            if app is not None and app.poll() is None:
                os.killpg(app.pid, signal.SIGTERM)
                try:
                    app.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(app.pid, signal.SIGKILL)
                    app.wait()
            app = None

        def cli(*args, success=True):
            result = subprocess.run([str(CLI), *args, '--json'], env=env, capture_output=True, text=True, timeout=25)
            if not success:
                assert result.returncode != 0, args
                return result.stderr
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)

        def rpc(method, success=True, **params):
            return cli('rpc', method, '--params', json.dumps(params), success=success)

        def capture(name, settings=True):
            time.sleep(0.4)
            rpc('debug.screenshot', settings=settings, path=str(ARTIFACTS / f'palettes-{name}.png'))

        try:
            start()
            assert rpc('config.get')['error'] is None
            assert cli('config', 'validate', '--file', str(config))['valid']
            before = rpc('debug.inspect')['panes'][0]['surface']
            rpc('terminal.send', pane='p1', text="stty -echo; printf '\\033[2J\\033[HCustom palette\\n\\nRegular text  \\033[1mBold text\\033[0m\\n\\033[31mRed \\033[32mGreen \\033[34mBlue\\033[0m\\n'\r")
            eventually('terminal fixture', lambda: 'Custom palette' in rpc('terminal.capture', pane='p1')['text'])
            rpc('debug.activate')
            state = rpc('debug.settings', section='Appearance', width=840, height=620)
            assert state['values']['terminal.dark_theme'] == '"My Dark"'
            assert state['customPalettes'] == ['My Dark', 'My Light']
            capture('custom-settings-dark')
            capture('custom-terminal-dark', settings=False)
            assert rpc('debug.settings', theme='light', apply=True)['error'] is None
            capture('custom-terminal-light', settings=False)
            rpc('debug.settings', width=740, height=520)
            capture('custom-settings-light-compact')
            assert '# My palettes' in config.read_text()
            assert rpc('debug.inspect')['panes'][0]['surface'] == before
            snapshots = directory / 'state/palettes'
            originals = {file: file.read_bytes() for file in snapshots.glob('*.conf')}
            assert len(originals) == 2
            assert all('command' not in data.decode() for data in originals.values())
            # Original file edits load only on an explicit reload; snapshots stay stable.
            dark.write_text('background = #172554\nforeground = #dbeafe\npalette = 1=#f87171\n')
            assert all(file.read_bytes() == data for file, data in originals.items())
            rpc('command.run', id='config.reload')
            assert len(list(snapshots.glob('*.conf'))) == 3
            assert rpc('config.get')['current']['terminal']['dark_theme'] == 'My Dark'
            # Reject non-color options without replacing the live config or snapshots.
            dark.write_text('background = #000000\nforeground = #ffffff\ncommand = /bin/false\n')
            valid = rpc('config.get')['current']
            rpc('command.run', id='config.reload', success=False)
            assert rpc('config.get')['current'] == valid
            assert len(list(snapshots.glob('*.conf'))) == 3
            assert 'Unsupported color setting' in cli('config', 'validate', '--file', str(config), success=False)
            # Settings can replace a now-invalid custom name with a bundled palette.
            state = rpc('debug.settings', darkTheme='Dracula', apply=True)
            assert state['error'] is None, state
            saved = config.read_text()
            state = rpc('debug.settings', lightTheme='Missing Palette', apply=True)
            assert state['error'] and config.read_text() == saved
            capture('missing-file')
            rpc('debug.settings', revert=True)
            # Import creates an available named copy; Apply stores only that name.
            importedSource = directory / 'Ocean.theme'
            importedSource.write_text('background = #112244\nforeground = #eeeeff\n')
            state = rpc('debug.settings', importPalette=str(importedSource))
            assert state['values']['terminal.dark_theme'] == '"Ocean"' and 'Ocean' in state['customPalettes']
            assert config.read_text() == saved, 'Import should not implicitly Apply'
            assert (library / 'Ocean.conf').is_file()
            if os.geteuid() != 0:
                previous = rpc('config.get')['current']
                snapshots.chmod(0o500)
                try:
                    state = rpc('debug.settings', apply=True)
                    assert state['error'] and config.read_text() == saved
                    assert rpc('config.get')['current'] == previous
                finally:
                    snapshots.chmod(0o700)
            assert rpc('debug.settings', apply=True)['error'] is None
            assert rpc('config.get')['current']['terminal']['dark_theme'] == 'Ocean'
            importedSource.write_text('background = #334455\nforeground = #ffffff\n')
            state = rpc('debug.settings', importPalette=str(importedSource))
            assert state['values']['terminal.dark_theme'] == '"Ocean-2"'
            assert (library / 'Ocean.conf').read_text().startswith('background = #112244')
            rpc('debug.settings', apply=True, width=840, height=620)
            importedSource.unlink()
            assert cli('config', 'validate', '--file', str(config))['valid']
            capture('imported-settings')
            invalidSource = directory / 'Unsafe.conf'
            invalidSource.write_text('background = #000000\nforeground = #ffffff\ncommand = /bin/false\n')
            rpc('debug.settings', importPalette=str(invalidSource), success=False)
            state = rpc('debug.settings')
            assert 'Unsafe' not in state['customPalettes'] and state['values']['terminal.dark_theme'] == '"Ocean-2"'
            # Paths are rejected even when they point at a valid palette.
            saved = config.read_text()
            state = rpc('debug.settings', lightTheme=str(light), apply=True)
            assert state['error'] and config.read_text() == saved
            rpc('debug.settings', revert=True)
            # Every exposed built-in name must really load, in either appearance mode.
            palettes = state['palettes']
            assert len(palettes) >= 20 and 'Nord' in palettes and 'TokyoNight' in palettes
            for palette in palettes:
                for mode in ['light', 'dark']:
                    state = rpc('debug.settings', theme=mode, lightTheme=palette, darkTheme=palette, apply=True)
                    assert state['error'] is None, (palette, mode, state)
                    assert rpc('config.get')['error'] is None
            rpc('debug.settings', lightTheme='Ayu Light', darkTheme='TokyoNight', theme='dark', apply=True, width=840, height=620)
            capture('bundled-settings')
            assert rpc('debug.inspect')['panes'][0]['surface'] == before
            assert rpc('config.get')['restartRequired'] == []
            # A bad custom palette on startup reports an error and falls back safely.
            stop()
            config.write_text('[terminal]\ndark_theme = "My Dark"\n')
            start()
            status = rpc('config.get')
            assert status['error'] and status['current']['terminal']['dark_theme'] == 'Builtin Dark', status
            assert any(window['visible'] for window in rpc('debug.inspect')['windows'])
            state = rpc('debug.settings', section='Appearance')
            assert state['values']['terminal.dark_theme'] == '"My Dark"', 'Settings must show the invalid persisted name, not the active fallback'
            assert 'Ocean-2' in state['customPalettes'], 'Imported palettes must survive restart'
            state = rpc('debug.settings', darkTheme='Builtin Dark', apply=True)
            assert state['error'] is None and rpc('config.get')['error'] is None
            assert 'Builtin Dark' in config.read_text()
            print(f'PASS: {len(palettes)} bundled palettes, named custom imports, collision-safe copies, path rejection, snapshot isolation, CLI/UI validation, live reload, and startup fallback')
        finally:
            stop()
