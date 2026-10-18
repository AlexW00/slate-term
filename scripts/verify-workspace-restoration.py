#!/usr/bin/env python3
"""VM-only starting locations/geometry, privacy, and no terminal replay."""
import json
from pathlib import Path
import shlex
import tempfile
from api_fixture import AppFixture, eventually

with tempfile.TemporaryDirectory(prefix='slate-restoration-', dir='/tmp') as temporary:
    directory = Path(temporary) / 'working folder 日本語'
    directory.mkdir()
    page = Path(temporary) / 'normal.html'
    page.write_text('<!doctype html><title>Restored normal page</title><p>Normal browser</p><script>window.addEventListener("load", () => history.replaceState(null,"","#settled"))</script>')
    page_url = page.as_uri() + '#settled'
    secret = Path(temporary) / 'private-location-must-not-persist.html'
    secret.write_text('<!doctype html><title>Private page</title>')
    marker = Path(temporary) / 'executions.txt'
    with AppFixture('workspace-restoration-save') as app:
        eventually('original authenticated shell', lambda: app.rpc('context.get')['terminal']['state'] == 'prompt')
        app.rpc('command.run', id='welcome.read')
        original_session = app.rpc('pane.inspect', pane='p1')['sessionId']
        app.rpc('terminal.run', pane='p1', command=f'cd -- {shlex.quote(str(directory))}; printf once >> {shlex.quote(str(marker))}; printf "RESTORATION_OUTPUT_SENTINEL\\n"')
        normal = app.rpc('command.run', id='split.right', pane='p1')['paneId']
        app.rpc('command.run', id='pane.type', pane=normal, type='browser', force=True)
        app.rpc('browser.navigate', pane=normal, url=page.as_uri())
        private = app.rpc('command.run', id='split.down', pane='p1')['paneId']
        app.rpc('command.run', id='pane.type', pane=private, type='private-browser', force=True)
        app.rpc('browser.navigate', pane=private, url=secret.as_uri())
        app.rpc('debug.windowGeometry', width=760, height=450)
        window = app.rpc('window.list')['windows'][0]
        group = window['groupId']
        frame = window['frame']
        snapshot = app.root / 'state/workspace.json'
        def saved():
            return json.loads(snapshot.read_text()).get('restoration', {})
        eventually('coalesced runtime autosave', lambda: saved().get('directories', {}).get('p1') == str(directory)
                   and saved().get('browserURLs', {}).get(normal) == page_url
                   and abs(saved().get('windowFrames', {}).get(group, {}).get('width', 0) - frame['width']) < 1)
        app.rpc('debug.windowFullscreen')
        eventually('native fullscreen entered', lambda: app.rpc('window.list')['windows'][0]['fullscreen'])
        app.rpc('command.run', id='pane.title.set', pane='p1', title='Restoration fixture')
        assert abs(saved()['windowFrames'][group]['width'] - frame['width']) < 1, 'Fullscreen replaced the saved windowed frame'
        source = snapshot.read_text()
        assert private not in saved()['browserURLs']
        for forbidden in ['private-location-must-not-persist', 'RESTORATION_OUTPUT_SENTINEL', 'printf once', original_session]:
            assert forbidden not in source, forbidden
        descriptor = app.rpc('api.describe')['workspaceRestoration']
        assert descriptor['privateBrowserURLs'] is False and descriptor['replaysCommands'] is False
        assert descriptor == app.cli('rpc', 'api.describe')['workspaceRestoration']

    with AppFixture('workspace-restoration-load', workspace_source=source) as app:
        def context():
            return app.rpc('context.get', pane='p1', scope='pane')['terminal']
        eventually('restored cwd in a fresh authenticated shell', lambda: context()['state'] == 'prompt' and context()['workingDirectory'] == str(directory))
        assert app.rpc('pane.inspect', pane='p1')['sessionId'] != original_session
        assert marker.read_text() == 'once', 'A command was replayed'
        assert 'RESTORATION_OUTPUT_SENTINEL' not in app.rpc('terminal.history', pane='p1')['text']
        eventually('normal browser starting location', lambda: app.rpc('browser.get', pane=normal)['url'] == page_url)
        assert app.rpc('browser.get', pane=private)['url'] == 'about:blank'
        restored_frame = app.rpc('window.list')['windows'][0]['frame']
        for dimension in ['width', 'height']:
            assert abs(restored_frame[dimension] - frame[dimension]) < 2, (frame, restored_frame)
        app.rpc('command.run', id='pane.type', pane=normal, type='terminal', force=True)
        assert normal not in json.loads((app.root / 'state/workspace.json').read_text())['restoration']['browserURLs']

    missing = json.loads(source)
    missing['restoration']['directories']['p1'] = str(Path(temporary) / 'no-longer-exists')
    with AppFixture('workspace-restoration-missing', workspace_source=json.dumps(missing)) as app:
        def context():
            return app.rpc('context.get', pane='p1', scope='pane')['terminal']
        eventually('missing directory falls back to home', lambda: context()['state'] == 'prompt' and context()['workingDirectory'] == str(Path.home()))
        assert app.rpc('config.get')['workspace']['savingSuspended'] is False

print('PASS restoration: fresh shells/cwd, normal browser URLs, private-location exclusion, window geometry, no replay/transcripts, replacement and missing-directory fallback')
