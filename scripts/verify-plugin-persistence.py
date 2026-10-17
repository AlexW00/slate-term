#!/usr/bin/env python3
"""Shared data/panel restoration lifecycle and native controls. Run through verify-vm.py."""
import json
import shutil
import subprocess
import time
import uuid
from api_fixture import AppFixture, APP, ROOT, eventually

subprocess.run(['node', str(ROOT / 'Tests/PluginPersistence/Example.mjs')], check=True, timeout=15)


def assets(app):
    root = app.root / 'panel'
    root.mkdir()
    ui = ROOT / 'skills/slate-terminal/references/ui'
    for name in ['slate.css', 'slate-theme.js']:
        shutil.copy2(ui / name, root / name)
    (root / 'index.html').write_text('''<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="slate.css"><script src="slate-theme.js"></script></head>
<body><main style="padding:12px"><p id="selection">Loading…</p><p id="error" role="status"></p></main>
<script type="module">
const head = await workspace.call('events.head');
const me = await workspace.panelState.get();
let serial = 0;
async function refresh() {
  const read = ++serial, state = await workspace.panelState.get();
  if (read !== serial) return;
  window.selection = state.values.selected ?? null;
  document.querySelector('#selection').textContent = window.selection ?? 'Choose a note';
}
await refresh();
await workspace.subscribe(event => {
  if(event.payload.panelId === me.panelId) return refresh();
}, {after:head.cursor,topics:['host.plugin.panel-state.changed'],onError:e=>{
  document.querySelector('#error').textContent='View updates stopped. Reload to reconnect.';
}});
window.fixtureReady = true;
</script></body></html>''')
    return root


def patch_data(app, plugin, key, value, **extra):
    before = app.rpc('plugins.data.get', id=plugin)
    return app.rpc('plugins.data.patch', id=plugin, expectedDataRevision=before['revision'],
                   operations=[dict(op='set', key=key, value=value)], **extra)


def patch_panel(app, pane, key, value, **extra):
    before = app.rpc('plugins.panelState.get', pane=pane)
    return app.rpc('plugins.panelState.patch', pane=pane, expectedPanelId=before['panelId'],
                   expectedStateRevision=before['revision'], operations=[dict(op='set', key=key, value=value)], **extra)


def restart(app, before_launch=None):
    app.process.terminate()
    app.process.wait(timeout=10)
    app.ready.unlink()
    if before_launch:
        before_launch()
    app.process = subprocess.Popen([str(APP)], env=app.env, stdout=app.log, stderr=app.log, start_new_session=True)
    eventually('restarted owned app', lambda: app.ready.exists() and app.process.poll() is None)
    app.path = app.ready.read_text().strip()
    app.env['SLATE_TERM_SOCKET'] = app.path


with AppFixture('plugin-persistence') as app:
    root = assets(app)
    app.rpc('plugins.register', manifest=dict(id='notes', title='Notes', scope='tab', source=dict(kind='directory', path=str(root)),
        layoutFields=[dict(id='project', label='Project', kind='text', required=True, defaultValue='default-project')]))
    api = app.rpc('api.describe')
    assert api['pluginPersistence']['version'] == 1
    assert all(name not in api['methods'] for name in ['storage.get', 'storage.set', 'storage.delete'])
    assert not app.rpc('plugins.status'), 'Data access must not activate a runtime'
    empty = app.cli('plugins', 'data', 'get', 'notes')
    reset = app.cli('plugins', 'data', 'reset', 'notes', '--expected-data-revision', empty['revision'], '--force')
    assert reset['changed'] and reset['revision'] != empty['revision']
    app.rpc('plugins.data.patch', id='notes', expectedDataRevision=empty['revision'], operations=[dict(op='set', key='queued', value=True)], error=-32050)
    patch_data(app, 'notes', 'note:one', dict(text='Never discard this when a view closes'))
    assert not app.rpc('plugins.status')
    app.rpc('plugins.data.get', id='notes', expectedWorkspaceRevision=app.rpc('workspace.snapshot')['workspaceRevision'], error=-32602)
    app.rpc('plugins.data.get', id='../escape', error=-32602)
    app.rpc('plugins.panelState.get', error=-32602)
    app.rpc('plugins.panelState.get', pane='p1', error=-32051)

    recipe = dict(version=1, id=str(uuid.uuid4()), name='Notes workspace', tabs=[dict(name='Notes',
        layout=dict(kind='pane', pane='p1'), panes=[dict(id='p1', type='notes', configuration=dict(project='template-project'))])])
    app.rpc('layouts.create', definition=recipe)
    first = app.rpc('layouts.open', id=recipe['id'])
    second = app.rpc('layouts.open', id=recipe['id'])
    a, b = first['paneIds'][0], second['paneIds'][0]
    def js(pane, source):
        return app.rpc('debug.pluginEval', pane=pane, script=source)
    for pane in [a, b]:
        eventually('cooperating panel ready', lambda pane=pane: js(pane, 'window.fixtureReady===true'))
    identity = app.rpc('plugins.panelState.get', pane=a)
    assert identity['panelId'] != app.rpc('plugins.panelState.get', pane=b)['panelId']
    patch_panel(app, a, 'selected', 'one')
    patch_panel(app, b, 'selected', 'two')
    eventually('independent views', lambda: js(a, 'window.selection') == 'one' and js(b, 'window.selection') == 'two')
    # Broadcast data invalidation crosses independent tab-scoped instances with default recipients/filters.
    cursor = app.rpc('events.head')['cursor']
    patch_data(app, 'notes', 'shared', 42)
    for pane in [a, b]:
        batch = js(pane, 'await workspace.call("events.poll",' + json.dumps(dict(after=cursor, topics=['host.plugin.data.changed'], waitMilliseconds=0)) + ')')
        assert len(batch['events']) == 1 and batch['events'][0]['payload']['pluginId'] == 'notes'
    assert js(a, 'await workspace.pluginData.get().then(s=>s.values.shared)') == 42
    assert 'Never discard' not in json.dumps(app.rpc('workspace.get'))
    assert 'template-project' not in json.dumps(app.rpc('panes.list'))

    # Journal rejection and disk failures do not partially commit data/cache/events.
    stored = app.rpc('plugins.data.get', id='notes')
    data_file = app.root / 'state/plugin-data-v2/notes.json'
    data_bytes = data_file.read_bytes()
    app.rpc('debug.pluginPersistence', rejectPublication=True)
    patch_data(app, 'notes', 'rejected', True, error=-32051)
    assert app.rpc('plugins.data.get', id='notes') == stored and data_file.read_bytes() == data_bytes
    data_file.parent.chmod(0o500)
    try:
        patch_data(app, 'notes', 'failed', True, error=-32054)
        assert app.rpc('plugins.data.get', id='notes') == stored and data_file.read_bytes() == data_bytes
    finally:
        data_file.parent.chmod(0o700)
    state_file = app.root / 'state/workspace.json'
    before_bytes = state_file.read_bytes()
    state_file.parent.chmod(0o500)
    try:
        failed_save = patch_panel(app, a, 'selected', 'accepted-live')
        assert failed_save['workspacePersistence'] == 'failed'
        assert state_file.read_bytes() == before_bytes
    finally:
        state_file.parent.chmod(0o700)
    cursor = app.rpc('events.head')['cursor']
    recovered = patch_panel(app, a, 'selected', 'accepted-live')
    assert recovered['outcome'] == 'unchanged' and recovered['workspacePersistence'] == 'saved'
    assert recovered['workspaceRevision'] == failed_save['workspaceRevision']
    assert not app.rpc('events.poll', after=cursor, topics=['host.plugin.panel-state.changed'], waitMilliseconds=0)['events']

    # Native confirmation freezes content/revision, never follows another focused panel.
    saved = app.rpc('plugins.panelState.get', pane=a)
    app.rpc('debug.activate', tab=app.rpc('pane.inspect', pane=a)['tabId'])
    cancelled = app.rpc('debug.pluginPersistence', pane=a, confirm=False)
    assert cancelled['prompts'] == ['Reset Plugin Panel View?']
    assert app.rpc('plugins.panelState.get', pane=a) == saved
    stale = app.rpc('debug.pluginPersistence', pane=a, confirm=True, changeWhileConfirming=True)
    assert stale['failures'] == [-32050]
    confirmed = app.rpc('debug.pluginPersistence', pane=a, confirm=True, focusPane=b,
                        screenshot=str(ROOT / 'artifacts/plugin-persistence-reset.png'))
    assert not confirmed['failures']
    eventually('reset rehydrates live view', lambda: js(a, 'window.selection') is None)
    assert app.rpc('plugins.panelState.get', pane=b)['values']['selected'] == 'two'
    assert app.rpc('layout.configuration', pane=a) == {'project': 'template-project'}
    app.rpc('command.run', id='pane.focus', pane=a)
    picker = app.rpc('debug.commandPicker', show=True, query='Reset Plugin Panel View')
    assert any(row['id'] == 'plugins.panelState.reset' and not row.get('unavailable') for row in picker['results']), picker
    app.rpc('debug.screenshot', picker=True, pickerContext=True, path=str(ROOT / 'artifacts/plugin-persistence-picker.png'))
    app.rpc('debug.commandPicker', dismiss=True)
    app.rpc('debug.menuPreview', pane=a, path=str(ROOT / 'artifacts/plugin-persistence-menu.png'))
    old = app.rpc('plugins.panelState.get', pane=a)
    presence_cursor = app.rpc('events.head')['cursor']
    app.rpc('command.run', id='plugins.panelState.reset', pane=a, expectedPanelId=old['panelId'], expectedStateRevision=old['revision'],
            request_metadata=dict(version=1, actor=dict(name='persistence-test')))
    presence_events = app.rpc('events.poll', after=presence_cursor, topics=['host.presence.changed'], waitMilliseconds=0)['events']
    assert any(event.get('pane') == a and event['payload']['phase'] == 'began' for event in presence_events), presence_events
    app.rpc('plugins.panelState.patch', pane=a, expectedPanelId=old['panelId'], expectedStateRevision=old['revision'], operations=[dict(op='set', key='queued', value=True)], error=-32050)
    patch_panel(app, a, 'selected', 'one')
    old = app.rpc('plugins.panelState.get', pane=a)
    web = app.rpc('web.get', pane=a)
    app.rpc('command.run', id='plugins.reload', pane=a)
    eventually('reloaded document', lambda: app.rpc('web.get', pane=a)['documentId'] not in [None, web['documentId']])
    eventually('reloaded selection', lambda: js(a, 'window.selection') == 'one')
    assert app.rpc('plugins.panelState.get', pane=a) == old

    def change_defaults():
        catalog_file = app.root / 'state/plugins.json'
        catalog = json.loads(catalog_file.read_text())
        catalog['registrations'][0]['layoutFields'][0]['defaultValue'] = 'changed-default'
        catalog_file.write_text(json.dumps(catalog))
    restart(app, change_defaults)
    eventually('restored panel', lambda: js(a, 'window.fixtureReady===true'))
    assert app.rpc('plugins.panelState.get', pane=a) == old
    assert app.rpc('layout.configuration', pane=a) == {'project': 'template-project'}
    assert app.rpc('web.get', pane=a)['viewId'] != web['viewId']
    source = next(w['id'] for w in app.rpc('layouts.windows') if app.rpc('pane.inspect', pane=a)['tabId'] in w['tabs'])
    captured = app.rpc('layouts.capture', window=source, name='After restart')['definition']
    assert captured['tabs'][0]['panes'][0]['configuration'] == {'project': 'template-project'}
    assert 'selected' not in json.dumps(captured) and 'Never discard' not in json.dumps(captured)
    app.rpc('command.run', id='tab.close', tab=app.rpc('pane.inspect', pane=a)['tabId'], force=True)
    reopened = app.rpc('layouts.open', id=recipe['id'])['paneIds'][0]
    assert app.rpc('plugins.panelState.get', pane=reopened)['values'] == {}
    assert app.rpc('plugins.panelState.get', pane=reopened)['panelId'] != old['panelId']
    assert app.rpc('plugins.data.get', id='notes')['values']['note:one']['text'].startswith('Never discard')

    app.rpc('debug.settings', section='Plugins')
    time.sleep(.3)
    app.rpc('debug.screenshot', settings=True, path=str(ROOT / 'artifacts/plugin-persistence-settings.png'))
    before = app.rpc('plugins.data.get', id='notes')
    app.rpc('debug.pluginPersistence', pluginId='notes', confirm=False)
    assert app.rpc('plugins.data.get', id='notes') == before
    stale = app.rpc('debug.pluginPersistence', pluginId='notes', confirm=True, changeWhileConfirming=True)
    assert stale['settingsError']
    assert app.rpc('plugins.data.get', id='notes')['values']['during-confirmation'] is True
    app.rpc('debug.pluginPersistence', pluginId='notes', confirm=True,
            screenshot=str(ROOT / 'artifacts/plugin-persistence-delete-data.png'))
    assert app.rpc('plugins.data.get', id='notes')['values'] == {}
    assert app.rpc('plugins.panelState.get', pane=b)['values']['selected'] == 'two'
    patch_data(app, 'notes', 'retained', 'after removal')
    app.rpc('plugins.unregister', id='notes', force=True)
    assert app.rpc('plugins.data.get', id='notes')['values']['retained'] == 'after removal'
    app.rpc('plugins.panelState.get', pane=b, error=-32051)
    assert not app.rpc('plugins.status')
    # Required fields without defaults reject plain opening before changing the old pane.
    app.rpc('plugins.register', manifest=dict(id='required', title='Required', source=dict(kind='directory', path=str(root)),
        layoutFields=[dict(id='project', label='Project', kind='text', required=True)]))
    before = app.rpc('workspace.get')
    app.rpc('command.run', id='pane.type', pane='p1', type='required', force=True, error=-32602)
    assert app.rpc('workspace.get') == before and not app.rpc('plugins.status')

for mode in ['disabled', 'suspended']:
    config = '[layout]\nrestore_workspace = false\n' if mode == 'disabled' else ''
    with AppFixture('plugin-persistence-' + mode, configuration=config, workspace_source='preserve old snapshot') as app:
        root = assets(app)
        app.rpc('plugins.register', manifest=dict(id='notes', title='Notes', source=dict(kind='directory', path=str(root))))
        app.rpc('command.run', id='pane.type', pane='p1', type='notes', force=True)
        assert patch_panel(app, 'p1', 'selected', 'one')['workspacePersistence'] == mode
        assert patch_data(app, 'notes', 'durable', True)['persisted'] is True
        assert (app.root / 'state/workspace.json').read_text() == 'preserve old snapshot'
        assert json.loads((app.root / 'state/plugin-data-v2/notes.json').read_text())['values']['durable'] is True

print('PASS shared data, independent panels, restart/configuration, template boundaries, reset/CAS, failure recovery, native controls and disabled/suspended restoration')
