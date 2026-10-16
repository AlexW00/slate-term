#!/usr/bin/env python3
"""Saved recipes: real native UI/CLI/bridge, isolated files and owned app process only."""
import contextlib
import copy
import errno
import json
import os
import pathlib
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP = pathlib.Path(os.environ.get('SLATE_TERM_TEST_APP', ROOT / '.derived/Build/Products/Debug/Slate Terminal.app/Contents/MacOS/Slate Terminal'))
CLI = APP.parent.parent / 'Helpers/slate-term'


def eventually(label, check):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.08)
    raise AssertionError(label)


@contextlib.contextmanager
def fixture_directory():
    directory = tempfile.TemporaryDirectory(prefix='slate-layouts-', dir='/tmp')
    try:
        yield directory.name
    finally:
        # An owned zsh can publish its final history just after the app exits.
        # Retry only this fixture's ENOTEMPTY cleanup race, never test operations.
        for attempt in range(20):
            try:
                directory.cleanup()
                break
            except OSError as error:
                if error.errno != errno.ENOTEMPTY or attempt == 19:
                    raise
                time.sleep(.05)


with fixture_directory() as temporary:
    base = pathlib.Path(temporary)
    ready = base / 'socket'
    config = base / 'config.toml'
    config.write_text('[appearance]\ntheme = "dark"\n')
    env = dict(os.environ, SLATE_TERM_INTEGRATION='1', SLATE_TERM_STATE_DIR=temporary,
               SLATE_TERM_CONFIG_FILE=str(config), SLATE_TERM_SOCKET_FILE=str(ready),
               SLATE_TERM_TEST_REAL_SHELL='1', ZDOTDIR=str(base / 'shell'))
    (base / 'shell').mkdir()
    for key in list(env):
        if key.startswith('SLATE_TERM_') and key not in ['SLATE_TERM_INTEGRATION', 'SLATE_TERM_STATE_DIR', 'SLATE_TERM_CONFIG_FILE', 'SLATE_TERM_SOCKET_FILE', 'SLATE_TERM_TEST_REAL_SHELL']:
            env.pop(key)
    with (ROOT / 'artifacts/saved-layouts-process.log').open('w') as log:
        app = subprocess.Popen([str(APP)], env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            eventually('app readiness', lambda: app.poll() is None and ready.exists())
            env['SLATE_TERM_SOCKET'] = ready.read_text().strip()

            def rpc(method, fail=False, client_env=None, **params):
                result = subprocess.run([str(CLI), 'rpc', method, '--params', json.dumps(params), '--json'], env=client_env or env, capture_output=True, text=True, timeout=35)
                if fail:
                    assert result.returncode != 0, result.stdout
                    return result.stderr
                assert result.returncode == 0, (method, result.stderr)
                return json.loads(result.stdout)

            def cli(*args):
                result = subprocess.run([str(CLI), 'layouts', *args, '--json'], env=env, capture_output=True, text=True, timeout=35)
                assert result.returncode == 0, result.stderr
                return json.loads(result.stdout)

            def command(id, **params):
                return rpc('command.run', id=id, **params)

            def activate_owned():
                rpc('debug.activate', tab='t1')
                eventually('owned app active for capture', lambda: rpc('debug.inspect')['applicationActive'])

            def screenshot(name):
                activate_owned()
                frame = rpc('debug.savedLayouts')
                time.sleep(.7)  # Render settling only, never an operation-success condition.
                expected = (1000, 560) if name == 'final-narrow' else (1060, 680)
                assert (frame['width'], frame['height']) == expected, (name, frame)
                rpc('debug.screenshot', layouts=True, path=str(ROOT / f'artifacts/layouts-{name}.png'))

            def agent_screenshot(theme):
                activate_owned()
                rpc('debug.settings', section='AI Agents', theme=theme, apply=True)
                time.sleep(.7)
                rpc('debug.screenshot', settings=True, path=str(ROOT / f'artifacts/notes-agents-{theme}.png'))

            # Activate only the owned fixture for genuine native input and untransformed captures.
            rpc('debug.activate', tab='t1')
            # Repairing a broken library after opening Settings reattaches the editor.
            (base / 'layouts').write_text('not a directory')
            command('settings.open')
            assert not rpc('debug.settings', inspectOnly=True)['layoutsAvailable']
            (base / 'layouts').unlink()
            command('settings.open')
            assert rpc('debug.settings', inspectOnly=True)['layoutsAvailable']
            assert cli('list') == []
            sources = cli('windows')
            assert len(sources) == 1
            source = sources[0]['id']
            assert 'required' in rpc('layouts.capture', fail=True, name='Unsafe')
            rpc('command.run', id='layouts.edit')
            frame = rpc('debug.savedLayouts', width=1060, height=680)
            assert (frame['width'], frame['height']) == (1060, 680), frame
            assert frame['settingsSection'] == 'Layouts'
            assert rpc('debug.settings', inspectOnly=True)['visible']
            screenshot('empty-dark')
            captured = cli('capture', '--window', source, '--name', 'Development')
            original = captured['definition']
            layout_id = original['id']
            file = captured['file']
            assert original['tabs'][0]['panes'][0]['configuration'].get('command') is None
            if '--render-only' in sys.argv:
                rpc('debug.savedLayouts', file=file, split='right')
                rpc('debug.savedLayouts', type='browser', title='Documentation', configuration={'url': 'https://example.com'})
                rpc('debug.savedLayouts', addTab=True)
                rpc('debug.savedLayouts', addTab=True)
                screenshot('tabs-dark')
                rpc('debug.savedLayouts', selectTab=0)
                screenshot('final-dark')
                rpc('debug.settings', theme='light', apply=True)
                screenshot('final-light')
                rpc('debug.savedLayouts', width=1000, height=560)
                screenshot('final-narrow')
                agent_screenshot('dark')
                agent_screenshot('light')
                activate_owned()
                rpc('debug.savedLayouts')
                rpc('debug.commandPicker', show=True, query='Development')
                time.sleep(.7)
                rpc('debug.screenshot', picker=True, path=str(ROOT / 'artifacts/layouts-template-picker.png'))
                print('Focused native layout/settings/palette render captures passed.')
                raise SystemExit(0)
            assert {t['id'] for t in cli('fields')} == {'terminal', 'browser', 'private-browser'}
            assert cli('fields', '--type', 'terminal')[0]['id'] == 'terminal'
            assert 'default' in rpc('command.run', fail=True, id='layouts.launcher')
            assert 'default' in rpc('layouts.launcher', fail=True, id=layout_id, path=str(base / 'Unsupported.app'))
            # Tabs preserve selected content, normalize numbers and share drag/menu operations.
            first = rpc('debug.savedLayouts', file=file)['definition']['tabs'][0]
            rpc('debug.savedLayouts', addTab=True)
            state = rpc('debug.savedLayouts', addTab=True)
            assert state['selectedTab'] == 2
            drag_id = state['tabDragID']
            state = rpc('debug.savedLayouts', dropTab=drag_id, toTab=0)
            assert state['selectedTab'] == 0 and state['definition']['tabs'][1] == dict(first, name='Tab 2')
            state = rpc('debug.savedLayouts', removeTab=1)
            assert [t['name'] for t in state['definition']['tabs']] == ['Tab 1', 'Tab 2']
            state = rpc('debug.savedLayouts', addTab=True)
            assert [t['name'] for t in state['definition']['tabs']] == ['Tab 1', 'Tab 2', 'Tab 3']
            state = rpc('debug.savedLayouts', moveTab=2, toTab=1)
            assert state['selectedTab'] == 1
            assert rpc('debug.savedLayouts', dropTab='foreign-layout', toTab=0)['definition'] == state['definition']
            rpc('debug.savedLayouts', revert=True)
            state = rpc('debug.savedLayouts', file=file, split='right')
            assert state['dirty'] and len(state['definition']['tabs'][0]['panes']) == 2
            state = rpc('debug.savedLayouts', type='browser', title='Documentation', configuration={'url': 'https://example.com'})
            rpc('debug.savedLayouts', split='below')
            state = rpc('debug.savedLayouts', title='Build Output')
            screenshot('editor-dark')
            state = rpc('debug.savedLayouts', remove=True)
            assert len(state['definition']['tabs'][0]['panes']) == 2
            assert state['definition']['tabs'][0]['layout']['kind'] == 'split'
            rpc('debug.key', layouts=True, chord='cmd+s')
            state = rpc('debug.savedLayouts')
            assert not state['dirty'] and not state['error'], state
            saved = cli('get', '--id', layout_id)
            assert saved['definition'] == state['definition']
            # Capture the new tab strip with multiple tabs, then keep the fixture recipe unchanged.
            rpc('debug.savedLayouts', addTab=True)
            rpc('debug.savedLayouts', addTab=True)
            screenshot('tabs-dark')
            rpc('debug.savedLayouts', revert=True)
            rpc('debug.savedLayouts', name='Retained draft')
            second = cli('capture', '--window', source, '--name', 'Writing')
            rpc('debug.savedLayouts', file=second['file'])
            state = rpc('debug.savedLayouts', file=file)
            assert state['dirty'] and state['definition']['name'] == 'Retained draft'

            # An external writer wins; stale editor/API updates never overwrite it.
            path = base / 'layouts' / file
            external = copy.deepcopy(saved['definition']); external['name'] = 'Edited Externally'
            path.write_text(json.dumps(external))
            state = rpc('debug.savedLayouts', save=True)
            assert state['error'] and state['dirty'] and json.loads(path.read_text()) == external
            conflict = json.loads(rpc('layouts.update', fail=True, definition=saved['definition'], expectedSavedLayoutRevision=saved['revision']))['error']
            assert conflict['code'] == -32050 and 'changed externally' in conflict['message']
            state = rpc('debug.savedLayouts', revert=True)
            assert not state['dirty'] and state['definition']['name'] == 'Edited Externally'
            rpc('debug.savedLayouts', name='Development', save=True)

            # Removing the last pane is rejected without mutating its draft.
            rpc('debug.savedLayouts', file=second['file'], remove=True)
            state = rpc('debug.savedLayouts')
            assert not state['dirty'] and len(state['definition']['tabs'][0]['panes']) == 1

            # Broken JSON and missing plugin dependencies stay visible and untouched.
            (base / 'layouts/broken.json').write_text('{"version":1,')
            state = rpc('debug.savedLayouts', file='broken.json')
            assert state['definition'] is None
            screenshot('invalid-dark')
            missing = copy.deepcopy(original); missing['id'] = str(uuid.uuid4()); missing['name'] = 'Missing Plugin'
            missing['tabs'][0]['panes'][0].update(type='notes', configuration={'folder': '/tmp', 'future': {'retained': True}})
            missing_file = 'missing.json'
            (base / 'layouts' / missing_file).write_text(json.dumps(missing))
            before = rpc('workspace.get')
            assert 'Missing plugin' in rpc('layouts.open', fail=True, id=missing['id'])
            assert rpc('workspace.get') == before
            rpc('debug.savedLayouts', file=missing_file)
            screenshot('missing-dark')
            rpc('debug.savedLayouts', title='Still Notes', save=True)
            assert json.loads((base / 'layouts' / missing_file).read_text())['tabs'][0]['panes'][0]['configuration'] == missing['tabs'][0]['panes'][0]['configuration']
            assert any(item['file'] == 'broken.json' and item['diagnostics'] for item in cli('list'))

            # Plugin schema flows into native inspector and fresh bridge configuration.
            plugin = base / 'plugin'; plugin.mkdir(); (plugin / 'index.html').write_text('<title>Dashboard</title><h1>Layout fixture</h1>')
            rpc('plugins.register', manifest={'id': 'dashboard', 'title': 'Dashboard', 'source': {'kind': 'directory', 'path': str(plugin)},
                'layoutFields': [{'id': 'folder', 'label': 'Project Folder', 'kind': 'directory', 'required': True},
                                 {'id': 'view', 'label': 'View', 'kind': 'choice', 'options': ['board', 'list'], 'defaultValue': 'board'},
                                 {'id': 'completed', 'label': 'Show Completed', 'kind': 'boolean', 'defaultValue': False}]})
            recipe = copy.deepcopy(original); recipe['id'] = str(uuid.uuid4()); recipe['name'] = 'Dashboard'
            recipe['tabs'][0]['panes'][0].update(type='dashboard', title='Project', configuration={'folder': temporary, 'view': 'list', 'completed': True})
            entry = rpc('layouts.create', definition=recipe)
            rpc('debug.savedLayouts', file=entry['file'])
            screenshot('plugin-dark')
            opened = cli('open', '--id', recipe['id'])
            plugin_pane = opened['paneIds'][0]
            def bridge(script):
                return rpc('debug.pluginEval', pane=plugin_pane, script=script)
            eventually('plugin bridge ready', lambda: bridge("typeof window.workspace === 'object'"))
            assert bridge('await workspace.layoutConfiguration()') == recipe['tabs'][0]['panes'][0]['configuration']
            assert len(bridge('await workspace.layouts.list()')) == len(cli('list'))
            cross_capture = bridge(f"await workspace.layouts.capture({{window:{json.dumps(source)},name:'Cross-window Copy'}})")
            assert cross_capture['definition']['tabs'][0]['panes'][0]['type'] == 'terminal'
            assert bridge('await workspace.layouts.windows()') == cli('windows')
            assert cli('configuration', '--pane', plugin_pane) == bridge('await workspace.layoutConfiguration()')
            assert any(item['id'] == 'layouts.edit' for item in bridge("await workspace.call('command.list')"))
            assert bridge("await workspace.command('layouts.edit')") == {}
            assert 'plugins.reload' in {c['id'] for c in bridge("await workspace.call('command.list')")}
            # Reload the explicit plugin only, with fresh document identity and no footer.
            before_web = rpc('web.get', pane=plugin_pane)
            assert command('plugins.reload', pane=plugin_pane)['reloading']
            eventually('reload document', lambda: rpc('web.get', pane=plugin_pane)['documentId'] not in [None, before_web['documentId']])
            eventually('reloaded bridge', lambda: bridge("typeof workspace === 'object'"))
            assert 'not a plugin' in rpc('command.run', fail=True, id='plugins.reload', pane='p1')
            rpc('debug.screenshot', pane=plugin_pane, path=str(ROOT / 'artifacts/layouts-plugin-footer.png'))
            rpc('debug.commandPicker', show=True, pane=plugin_pane, query='Reload Plugin')
            assert any(r['id'] == 'plugins.reload' for r in rpc('debug.commandPicker')['results'])
            rpc('debug.commandPicker', dismiss=True)

            # A managed service uses the same catalog and writer, with no page-only context.
            worker = base / 'service.py'
            context_file = base / 'service-context.json'
            worker.write_text('''import json,os,pathlib,subprocess,time
subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc','service.ready','--params','{"version":1}'],check=True)
keys=['SLATE_TERM_SOCKET','SLATE_TERM_INSTANCE_ID','SLATE_TERM_SERVICE_PLUGIN_ID','SLATE_TERM_SERVICE_ID','SLATE_TERM_SERVICE_GENERATION']
path=pathlib.Path(os.environ['TEST_CONTEXT']); temporary=path.with_suffix('.tmp')
temporary.write_text(json.dumps({k:os.environ[k] for k in keys})); temporary.replace(path)
while True: time.sleep(1)
''')
            rpc('plugins.register', manifest={'id': 'layoutworker', 'title': 'Layout Worker', 'service': {
                'executable': sys.executable, 'arguments': [str(worker)], 'environment': {'TEST_CONTEXT': str(context_file)}}})
            rpc('plugins.service.start', id='layoutworker')
            eventually('service ready', lambda: context_file.exists())
            service_env = dict(env, **json.loads(context_file.read_text()))
            def service(method, **params):
                return rpc(method, client_env=service_env, **params)
            # The same focused reload command is available to service and registered pages.
            old_document = rpc('web.get', pane=plugin_pane)['documentId']
            assert service('command.run', id='plugins.reload', pane=plugin_pane)['paneId'] == plugin_pane
            eventually('service reload document', lambda: rpc('web.get', pane=plugin_pane)['documentId'] not in [None, old_document])
            eventually('service reloaded bridge', lambda: bridge("typeof workspace === 'object'"))
            old_document = rpc('web.get', pane=plugin_pane)['documentId']
            assert bridge("(()=>{setTimeout(()=>workspace.command('plugins.reload').catch(()=>{}),0);return 'scheduled';})()") == 'scheduled'
            eventually('page reload document', lambda: rpc('web.get', pane=plugin_pane)['documentId'] not in [None, old_document])
            eventually('page reloaded bridge', lambda: bridge("typeof workspace === 'object'"))
            old_document = rpc('web.get', pane=plugin_pane)['documentId']
            assert rpc('command.run', fail=True, id='plugins.reload', pane='p999999')
            assert rpc('web.get', pane=plugin_pane)['documentId'] == old_document
            describe = rpc('api.describe')
            assert bridge("await workspace.call('api.describe')") == service('api.describe') == describe
            assert bridge('workspace.methods') == describe['methods']
            assert service('layouts.windows') == cli('windows')
            assert service('layout.configuration', pane=plugin_pane) == recipe['tabs'][0]['panes'][0]['configuration']
            assert service('layouts.startupStatus') == cli('startup-status')
            service_entry = service('layouts.capture', window=source, name='Service Copy')
            service_recipe = service_entry['definition']; service_recipe['name'] = 'Service Edit'
            service('layouts.update', definition=service_recipe, expectedSavedLayoutRevision=service_entry['revision'])
            assert cli('get', '--id', service_recipe['id'])['definition']['name'] == 'Service Edit'
            page_entry = bridge(f"await workspace.layouts.get({json.dumps(service_recipe['id'])})")
            service_recipe['name'] = 'Page Edit'
            bridge(f"await workspace.layouts.update({json.dumps(service_recipe)}, {json.dumps(page_entry['revision'])})")
            assert service('layouts.get', id=service_recipe['id'])['definition']['name'] == 'Page Edit'
            assert service('layouts.fields', type='dashboard') == cli('fields', '--type', 'dashboard')
            assert service('layouts.validate', definition=service_recipe)['valid']
            assert json.loads(rpc('layouts.list', fail=True, expectedInstanceId='retired'))['error']['code'] == -32050
            assert json.loads(rpc('layouts.list', fail=True, expectedWorkspaceRevision='unsupported'))['error']['code'] == -32602
            assert json.loads(rpc('layouts.update', fail=True, definition=service_recipe, expectedRevision='old-contract'))['error']['code'] == -32053
            own_capture = bridge(f"await workspace.layouts.capture({{window:{json.dumps(opened['window'])},name:'Plugin Copy'}})")
            assert own_capture['definition']['tabs'][0]['panes'][0]['configuration']['view'] == 'list'

            # Openings allocate fresh runtime IDs and preserve every existing window.
            cursor = rpc('events.head')['cursor']
            running = cli('open', '--id', layout_id)
            assert running['outcome'] == 'committed' and running['workspacePersistence'] == 'saved'
            facts = rpc('events.poll', after=cursor, waitMilliseconds=0)['events']
            facts = [e for e in facts if e['payload'].get('operationId') == running['operationId']]
            assert facts and all(e['payload']['origin']['kind'] == 'administrative' and e['payload']['actionKind'] == 'layouts.open' for e in facts)
            assert all(e['payload']['workspaceRevision'] == running['workspaceRevision'] for e in facts)
            assert set(running['windowIds']) <= {w['windowId'] for w in rpc('window.list')['windows']}
            assert not set(running['paneIds']) & set(before_pane['id'] for before_pane in before['panes'])
            windows_before = cli('windows')
            assert 'Unknown parameter' in rpc('layouts.open', fail=True, id=layout_id, replaceWindow=running['window'])
            assert 'Unknown parameter' in rpc('layouts.open', fail=True, id=layout_id, force=True)
            assert rpc('layouts.open', fail=True, id=layout_id, expectedWorkspaceRevision='stale')
            another = cli('open', '--id', second['definition']['id'])
            windows_after = cli('windows')
            assert len(windows_after) == len(windows_before) + 1
            assert {w['id'] for w in windows_before} <= {w['id'] for w in windows_after}

            # Capacity rejection happens before opening or changing any window.
            crowded = copy.deepcopy(original); crowded['id'] = str(uuid.uuid4()); crowded['name'] = 'Too Many Startup Commands'; crowded['tabs'] = []
            def tree(ids):
                if len(ids) == 1:
                    return {'kind': 'pane', 'pane': ids[0]}
                middle = len(ids) // 2
                return {'kind': 'split', 'axis': 'horizontal', 'fraction': .5, 'first': tree(ids[:middle]), 'second': tree(ids[middle:])}
            for start in range(1, 34, 8):
                ids = [f'p{i}' for i in range(start, min(start + 8, 34))]
                crowded['tabs'].append({'name': f'Tab {start}', 'layout': tree(ids), 'panes': [{'id': id, 'type': 'terminal', 'title': '', 'configuration': {'command': 'sleep 60'}} for id in ids]})
            rpc('layouts.create', definition=crowded)
            before_capacity = rpc('workspace.get')
            assert '32' in rpc('layouts.open', fail=True, id=crowded['id'])
            assert rpc('workspace.get') == before_capacity

            # Startup folder and command are applied once to a new, authenticated shell.
            startup = copy.deepcopy(original); startup['id'] = str(uuid.uuid4()); startup['name'] = 'Startup'
            marker = base / 'started'
            startup['tabs'][0]['panes'][0]['configuration'] = {'directory': temporary, 'command': f"printf once >> '{marker}'"}
            rpc('layouts.create', definition=startup)
            # Reject after reservations/resources are prepared: no model/event change, no startup replay.
            for fault in ['debug.rejectNextTerminalPreparation', 'debug.rejectNextWorkspacePublication']:
                before_failure = rpc('workspace.get')
                previous_session = rpc('pane.inspect', pane='p1')['sessionId']
                revision = cli('windows')[0]['workspaceRevision']
                cursor = rpc('events.head')['cursor']
                rpc(fault)
                failure = json.loads(rpc('layouts.open', fail=True, id=startup['id'], expectedWorkspaceRevision=revision))['error']
                assert failure['code'] == -32051, failure
                assert rpc('workspace.get') == before_failure
                assert rpc('pane.inspect', pane='p1')['sessionId'] == previous_session
                assert not marker.exists()
                assert not [e for e in rpc('events.poll', after=cursor, waitMilliseconds=0)['events'] if e['payload'].get('actionKind') == 'layouts.open']
            cursor = rpc('events.head')['cursor']
            started = service('layouts.open', id=startup['id'])
            service_facts = [e for e in rpc('events.poll', after=cursor, waitMilliseconds=0)['events'] if e['payload'].get('operationId') == started['operationId']]
            assert service_facts and all(e['payload']['origin']['kind'] == 'service' for e in service_facts)
            rpc('plugins.service.stop', id='layoutworker')
            eventually('startup execution', lambda: marker.exists() and marker.read_text() == 'once')
            eventually('startup completion', lambda: any(item['paneId'] == started['paneIds'][0] and item['state'] == 'finished' for item in cli('startup-status')))
            assert rpc('context.get', pane=started['paneIds'][0])['terminal']['workingDirectory'] == temporary
            assert marker.read_text() == 'once'
            configured = cli('capture', '--window', started['window'], '--name', 'Configured Capture', '--include-commands')
            assert configured['definition']['tabs'][0]['panes'][0]['configuration']['command'] == startup['tabs'][0]['panes'][0]['configuration']['command']

            # Page opening has plugin attribution and never removes its initiating view.
            cursor = rpc('events.head')['cursor']
            page_open = bridge(f"await workspace.layouts.open({json.dumps(second['definition']['id'])})")
            page_facts = [e for e in rpc('events.poll', after=cursor, waitMilliseconds=0)['events'] if e['payload'].get('operationId') == page_open['operationId']]
            assert page_facts and all(e['payload']['origin']['kind'] == 'plugin' for e in page_facts)
            assert opened['window'] in [w['id'] for w in cli('windows')]

            # CLI definitions and revision-guarded edits use exactly the same file writer.
            saved = cli('get', '--id', layout_id)
            changed = saved['definition']; changed['name'] = 'CLI Edit'
            definition_file = base / 'definition.json'; definition_file.write_text(json.dumps(changed))
            assert cli('validate', '--file', str(definition_file))['valid']
            cli('update', '--file', str(definition_file), '--expected-saved-layout-revision', saved['revision'])
            assert json.loads(path.read_text())['name'] == 'CLI Edit'
            rpc('debug.savedLayouts', file=file, name='Development', save=True)
            # Package launcher in the temporary test directory, never user Applications.
            launcher = base / 'Development.app'
            rpc('debug.savedLayouts', launcherPath=str(launcher))
            info = plistlib.loads((launcher / 'Contents/Info.plist').read_bytes())
            assert info['SlateLayoutID'] == layout_id
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(launcher)], check=True, capture_output=True)
            rpc('debug.savedLayouts', launcherPath=str(launcher), fail=True)
            assert info == plistlib.loads((launcher / 'Contents/Info.plist').read_bytes())

            # Light, narrow, dirty and selected terminal inspector rendering.
            rpc('debug.savedLayouts', file=file, pane=original['tabs'][0]['panes'][0]['id'])
            screenshot('final-dark')
            rpc('debug.settings', theme='light', apply=True)
            rpc('debug.savedLayouts', name='Development Draft')
            screenshot('final-light')
            rpc('debug.savedLayouts', width=1000, height=560)
            screenshot('final-narrow')
            rpc('debug.savedLayouts', revert=True)
            # Settings close accounts for dirty drafts in other library selections too.
            rpc('debug.savedLayouts', name='Close Draft')
            rpc('debug.savedLayouts', file=second['file'])
            assert rpc('debug.closeConfirmation', quit=True, answer='cancel') is True
            assert rpc('debug.closeConfirmation', settings=True, answer='cancel')['visible']
            assert rpc('debug.savedLayouts', file=file)['dirty']
            external = json.loads(path.read_text()); external['name'] = 'External Close Conflict'
            path.write_text(json.dumps(external))
            rpc('debug.savedLayouts', file=second['file'])
            assert rpc('debug.closeConfirmation', settings=True, answer='save')['visible']
            assert json.loads(path.read_text()) == external
            rpc('debug.savedLayouts', file=file, revert=True)
            rpc('debug.savedLayouts', name='Development')
            rpc('debug.savedLayouts', file=second['file'])
            assert not rpc('debug.closeConfirmation', settings=True, answer='save')['visible']
            assert not rpc('debug.savedLayouts', file=file)['dirty']
            agent_screenshot('dark')
            agent_screenshot('light')
            rpc('debug.commandPicker', show=True, query='')
            picker = rpc('debug.commandPicker')
            ids = {r['id'] for r in picker['results']}
            assert picker['visible'] and 'layout-template.' + layout_id in ids
            assert not ids & {'layouts.openWindow', 'layouts.launcher', 'layouts.folder', 'layouts.replaceWindow'}
            assert not describe['savedLayouts']['replacementSupported']
            assert describe['savedLayouts']['openMode'] == 'newWindow'
            rpc('debug.commandPicker', query='Development')
            rpc('debug.screenshot', picker=True, path=str(ROOT / 'artifacts/layouts-template-picker.png'))
            # External edits refresh template labels while the picker remains open.
            rpc('debug.commandPicker', query='')
            palette_saved = cli('get', '--id', layout_id)
            palette_recipe = copy.deepcopy(palette_saved['definition']); palette_recipe['name'] = 'Palette Renamed'
            path.write_text(json.dumps(palette_recipe))
            eventually('external template rename', lambda: any(r['title'] == 'Open Palette Renamed in New Window' for r in rpc('debug.commandPicker')['results']))
            rpc('debug.commandPicker', query='Palette Renamed')
            before_open = len(cli('windows'))
            rpc('debug.key', picker=True, chord='return', dispatch=True)
            eventually('template palette opens window', lambda: len(cli('windows')) == before_open + 1)
            print('Saved layout UI, CLI, bridge, conflict, capture, open, startup and launcher packaging checks passed.')
        finally:
            os.killpg(app.pid, signal.SIGTERM)
            try:
                app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(app.pid, signal.SIGKILL); app.wait()
