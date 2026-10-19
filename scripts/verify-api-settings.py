#!/usr/bin/env python3
"""Shared appearance writer, conflict protection, pending-editor preservation and bridge parity."""
import json
import os
import shlex
from api_fixture import AppFixture, eventually
from plugin_package_fixture import package_fixture

source = '# preserved comment\n[appearance]\ntheme = "auto" # follow OS\n[terminal]\nshell = "/bin/zsh"\n[plugins.\"acme.tools\".custom]\ncount = 7\n'
with AppFixture('api-settings', source) as app:
    app.capture_contracts()
    # The shared numeric setting applies to retained panes through API, CLI and native Settings.
    dim_key = 'appearance.unfocused_pane_dim'
    sibling = app.rpc('command.run', id='split.right', pane='p1', focus='new')['paneId']
    session_before = app.rpc('context.get', pane='p1', scope='pane')['terminal']['sessionId']
    def shade(pane):
        return app.rpc('debug.paneHeader', pane=pane)
    for amount in [0, 0.35, 1]:
        result = app.rpc('config.patch', values={dim_key: amount}, expectedSourceRevision=app.rpc('config.get')['sourceRevision'])
        assert not result['restartRequired']
        assert shade('p1')['dimAmount'] == amount
        assert shade(sibling)['dimAmount'] == 0
    app.rpc('command.run', id='pane.focus', pane='p1')
    assert shade('p1')['dimAmount'] == 0 and shade(sibling)['dimAmount'] == 1
    before = app.config.read_text()
    for invalid in [-0.1, 1.1, True, '0.5', None]:
        app.rpc('config.patch', values={dim_key: invalid}, expectedSourceRevision=app.rpc('config.get')['sourceRevision'], error=-32602)
        assert app.config.read_text() == before
    app.cli('config', 'set', '--key', dim_key, '--value', '0.2', '--expected-source-revision', app.rpc('config.get')['sourceRevision'])
    assert shade(sibling)['dimAmount'] == 0.2
    app.rpc('debug.settings', unfocusedPaneDim=0.4, apply=True)
    assert shade(sibling)['dimAmount'] == 0.4
    saved_dim = app.config.read_text()
    updated_dim = saved_dim.replace('"unfocused_pane_dim" = 0.4', '"unfocused_pane_dim" = 0.08')
    assert updated_dim != saved_dim
    app.config.write_text(updated_dim)
    eventually('TOML dim reload', lambda: shade(sibling)['dimAmount'] == 0.08)
    assert app.rpc('context.get', pane='p1', scope='pane')['terminal']['sessionId'] == session_before
    app.rpc('command.run', id='pane.close', pane=sibling, force=True)
    # Verify actual shell directories, including a background split target.
    project = app.root / 'project with spaces'
    fallback = app.root / 'default directory'
    project.mkdir()
    fallback.mkdir()

    def prompt(pane):
        eventually('terminal prompt', lambda: app.rpc('context.get', pane=pane, scope='pane')['terminal']['state'] == 'prompt')

    def check_directory(pane, expected):
        prompt(pane)
        output = app.root / 'pwd.txt'
        result = app.rpc('terminal.run', pane=pane, command='pwd -P > ' + shlex.quote(str(output)), timeoutMilliseconds=10000)
        assert result['exitCode'] == 0, result
        assert output.read_text().strip() == os.path.realpath(expected), (pane, output.read_text(), expected)

    def close(pane):
        app.rpc('command.run', id='pane.close', pane=pane, force=True)

    prompt('p1')
    app.rpc('terminal.run', pane='p1', command='cd -- ' + shlex.quote(str(project)), timeoutMilliseconds=10000)
    eventually('changed directory report', lambda: app.rpc('context.get', pane='p1', scope='pane')['terminal']['workingDirectory'] == str(project))
    # The native shortcut uses the same operation as CLI and plugin commands.
    app.rpc('debug.activate')
    app.rpc('debug.key', chord='cmd+d', workspaceOnly=True)
    native = next(p['paneId'] for p in app.rpc('workspace.snapshot')['panes'] if p['paneId'] != 'p1')
    check_directory(native, project)
    app.rpc('terminal.run', pane=native, command='cd -- ' + shlex.quote(str(fallback)), timeoutMilliseconds=10000)
    targeted = app.cli('command', 'run', 'split.down', '--pane', 'p1')['paneId']
    check_directory(targeted, project)
    close(targeted)
    close(native)
    app.cli('config', 'set', '--key', 'terminal.working_directory', '--value', json.dumps(str(fallback)), '--expected-source-revision', app.rpc('config.get')['sourceRevision'])
    app.cli('config', 'set', '--key', 'terminal.inherit_working_directory', '--value', 'false', '--expected-source-revision', app.rpc('config.get')['sourceRevision'])
    disabled = app.rpc('command.run', id='pane.split', pane='p1', direction='right', expectedLayoutRevision=app.rpc('pane.inspect', pane='p1')['layoutRevision'])['paneId']
    check_directory(disabled, fallback)
    close(disabled)
    # Restore defaults before the existing settings conflict tests.
    app.rpc('config.patch', values={'terminal.working_directory': '~', 'terminal.inherit_working_directory': True}, expectedSourceRevision=app.rpc('config.get')['sourceRevision'])
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
    # Agent activity: typed CLI, command.run and config.patch share one writer.
    def agent_activity():
        return app.rpc('config.get')['current']['agents']['show_activity']
    assert agent_activity() is True
    app.cli('agent-activity', 'hide')
    assert agent_activity() is False
    app.rpc('command.run', id='agents.activity.toggle')
    assert agent_activity() is True
    revision = app.rpc('config.get')['sourceRevision']
    app.cli('config', 'set', '--key', 'agents.show_activity', '--value', 'false', '--expected-source-revision', revision)
    assert agent_activity() is False
    app.cli('command', 'run', 'agents.activity.show')
    assert agent_activity() is True
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
    app.rpc('plugins.register', packagePath=package_fixture({'id': 'fixture', 'title': 'Fixture', 'source': {'kind': 'directory', 'path': str(panel)}}, app.root))
    app.rpc('command.run', id='pane.type', pane='p1', type='fixture', force=True)

    def evaluate(script):
        return app.rpc('debug.pluginEval', pane='p1', script=script)

    eventually('plugin document', lambda: evaluate('typeof workspace') == 'object')
    evaluate('await workspace.call("config.patch", {expectedSourceRevision:(await workspace.call("config.get")).sourceRevision,values:{"appearance.unfocused_pane_dim":0.25}})')
    assert app.rpc('config.get')['current']['appearance']['unfocused_pane_dim'] == 0.25
    # Registered pages can configure and create terminal splits through the public API.
    evaluate('await workspace.call("config.patch", {expectedSourceRevision:(await workspace.call("config.get")).sourceRevision,values:{"terminal.working_directory":' + json.dumps(str(fallback)) + ',"terminal.inherit_working_directory":false}})')
    plugin_split = evaluate('await workspace.panes.split({direction:"right",expectedLayoutRevision:(await workspace.panes.inspect()).layoutRevision})')['paneId']
    check_directory(plugin_split, fallback)
    close(plugin_split)
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
