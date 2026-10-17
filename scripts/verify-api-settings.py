#!/usr/bin/env python3
"""Shared appearance writer, conflict protection, pending-editor preservation and bridge parity."""
import json
from api_fixture import AppFixture, eventually

source = '# preserved comment\n[appearance]\ntheme = "auto" # follow OS\n[terminal]\nshell = "/bin/zsh"\n[plugins.\"acme.tools\".custom]\ncount = 7\n'
with AppFixture('api-settings', source) as app:
    initial = app.rpc('config.get')
    assert initial['sourceRevision'] and initial['appliedRevision'] and initial['appliedMatchesSource']
    session = app.rpc('context.get', pane='p1', scope='pane')['terminal']['sessionId']
    app.rpc('debug.settings', theme='light')
    app.cli('appearance', 'dark')
    changed = app.rpc('config.get')
    assert changed['current']['appearance']['theme'] == 'dark' and changed['appliedMatchesSource'], changed
    assert changed['sourceRevision'] != initial['sourceRevision']
    assert app.rpc('context.get', pane='p1', scope='pane')['terminal']['sessionId'] == session
    text = app.config.read_text()
    assert '# preserved comment' in text and '# follow OS' in text and '[plugins."acme.tools".custom]\ncount = 7' in text
    dirty = app.rpc('debug.settings')
    assert dirty['dirty'] and dirty['values']['appearance.theme'] == '"light"', dirty
    rejected = app.rpc('debug.settings', apply=True)
    assert rejected['error'] and app.rpc('config.get')['current']['appearance']['theme'] == 'dark'
    app.rpc('debug.settings', revert=True)
    app.rpc('config.patch', values={'appearance.theme': 'light'}, expectedSourceRevision=initial['sourceRevision'], error=-32050)
    app.rpc('config.reload', expectedSourceRevision=initial['sourceRevision'], error=-32050)
    app.rpc('command.run', id='config.reload', expectedSourceRevision=initial['sourceRevision'], error=-32050)
    assert app.cli('config', 'reload', '--expected-source-revision', initial['sourceRevision'], error=True)['code'] == -32050
    assert app.cli('config', 'get', '--expected-source-revision', initial['sourceRevision'], error=True)['code'] == -32602
    app.cli('appearance', 'dark')
    assert app.rpc('config.get')['sourceRevision'] == changed['sourceRevision'], 'No-op invalidated source token'
    app.cli('config', 'set', '--key', 'terminal.font_size', '--value', '15', '--expected-source-revision', changed['sourceRevision'])
    assert app.rpc('config.get')['current']['terminal']['font_size'] == 15
    app.cli('command', 'run', 'terminal.font.reset')
    assert app.rpc('config.get')['current']['terminal']['font_size'] == 13
    assert app.cli('palette', 'list')
    # Fail after the new config reaches disk: rollback must restore the original source.
    before_apply_failure = app.config.read_text()
    app.rpc('debug.configurationApplyFault', mode='reject')
    rollback = app.cli('appearance', 'light', error=True)
    assert rollback['code'] == -32054 and rollback['data']['persisted'] is False, rollback
    assert app.config.read_text() == before_apply_failure
    assert app.rpc('config.get')['current']['appearance']['theme'] == 'dark'
    assert app.rpc('pane.inspect', pane='p1')['sessionId'] == session
    # A non-cooperating edit between write and apply failure must win over rollback.
    external = before_apply_failure + '\n# edit during apply\n'
    app.rpc('debug.configurationApplyFault', mode='externalEdit', source=external)
    conflict = app.cli('appearance', 'light', error=True)
    assert conflict['code'] == -32054 and 'external edit was preserved' in conflict['message'], conflict
    assert app.config.read_text() == external
    app.rpc('config.reload')
    before_failure = app.config.read_text()
    app.root.chmod(0o500)
    try:
        failed = app.cli('appearance', 'light', error=True)
        assert failed['code'] == -32054 and failed['outcome'] == 'unknown', failed
        assert failed['data']['persisted'] is False, failed
        assert app.config.read_text() == before_failure
    finally:
        app.root.chmod(0o700)
    previous = app.config.read_text()
    revision = app.rpc('config.get')['sourceRevision']
    app.config.write_text(previous + '\n# external editor\n')
    app.rpc('config.patch', values={'appearance.theme': 'light'}, expectedSourceRevision=revision, error=-32050)
    assert '# external editor' in app.config.read_text()
    app.config.write_text('this is not TOML')
    app.cli('appearance', 'light', error=True)
    assert app.config.read_text() == 'this is not TOML', 'Invalid source was overwritten'
    app.config.write_text(previous)
    app.rpc('config.reload')

    # Native manifests share command metadata; parameterized entries are not one-click actions.
    commands = {c['id']: c for c in app.rpc('command.list')}
    assert commands['appearance.dark']['contract']['workspaceIndependent']
    assert 'pluginAccessible' not in commands['appearance.dark']['contract']
    assert commands['appearance.set']['contract']['requiresArguments']
    panel = app.root / 'panel'
    panel.mkdir()
    (panel / 'index.html').write_text('<!doctype html><title>Fixture</title><button>Fixture</button>')
    app.rpc('plugins.register', manifest={'id': 'fixture', 'title': 'Fixture', 'source': {'kind': 'directory', 'path': str(panel)}})
    app.rpc('command.run', id='pane.type', pane='p1', type='fixture', force=True)

    def evaluate(script):
        return app.rpc('debug.pluginEval', pane='p1', script=script)

    eventually('plugin document', lambda: evaluate('typeof workspace') == 'object')
    assert evaluate('await workspace.self()')['caller']['identitySource'] == 'bridgeBound'
    assert evaluate('await workspace.panes.inspect()')['paneId'] == 'p1'
    stale = evaluate('await workspace.panes.inspect({expectedWorkspaceRevision:"stale"}).then(()=>null,e=>e.code)')
    assert stale == -32050, stale
    mismatch = evaluate('await workspace.panes.inspect({pane:"p1",tab:"t999"}).then(()=>null,e=>e.code)')
    assert mismatch == -32602, mismatch
    for method, params in [('pane.title', {'title': 'Must Not Apply'}), ('plugins.panelState.patch', {'operations': [{'op': 'set', 'key': 'guarded', 'value': 'Must Not Apply'}]}), ('context.get', {})]:
        for guard, code in [('expectedWorkspaceRevision', -32050), ('expectedSourceRevision', -32602)]:
            result = evaluate('await workspace.call(' + json.dumps(method) + ',' + json.dumps(params | {guard: 'stale'}) + ').then(()=>null,e=>e.code)')
            assert result == code, (method, guard, result)
    assert evaluate('await workspace.panelState.get().then(s=>s.values.guarded??null)') is None
    assert app.rpc('pane.inspect', pane='p1')['title'] == 'Fixture'
    for value in [None, False, {'ok': False, 'value': 7, 'error': {'code': 123}}]:
        assert evaluate('(async()=>{const s=await workspace.pluginData.get();await workspace.pluginData.patch([{op:"set",key:"envelope",value:' + json.dumps(value) + '}],s.revision);return (await workspace.pluginData.get()).values.envelope;})()') == value
    # Existing reload convenience remains compatible with the shared API.
    assert isinstance(evaluate('await workspace.command("config.reload")'), dict)
    discovery = evaluate('await workspace.api()')
    assert discovery == app.rpc('api.describe')
    assert 'config.patch' in discovery['methods']
    assert any(c['id'].startswith('appearance.') for c in discovery['commands'])
    evaluate('await workspace.command("appearance.light")')
    assert app.rpc('config.get')['current']['appearance']['theme'] == 'light'
    revision = app.rpc('config.get')['sourceRevision']
    evaluate('await workspace.call("config.patch",' + json.dumps(dict(values={'appearance.theme': 'dark'}, expectedSourceRevision=revision)) + ')')
    assert app.rpc('config.get')['current']['appearance']['theme'] == 'dark'
print('Application settings, appearance commands, conflicts and bridge capability parity passed')
