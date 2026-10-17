#!/usr/bin/env python3
"""Typed own-namespace writes, TOML/native-writer compatibility, isolation and change hooks."""
import json
from api_fixture import AppFixture, eventually
from plugin_package_fixture import package_fixture

source = '''# keep application comment
[terminal]
shell = "/bin/zsh"
[appearance]
theme = "auto"
[plugins."acme.tools"]
keep = "unchanged" # keep comment
[plugins."acme.tools".prefs]
old = 5
[[plugins."acme.tools".items]]
name = "original" # array comment
[plugins.other]
private = "other namespace"
'''
with AppFixture('plugin-settings-api', source) as app:
    namespace = app.cli('plugins', 'settings', 'get', 'acme.tools')
    assert namespace['values'] == namespace['appliedValues']
    session = app.rpc('pane.inspect', pane='p1')['sessionId']
    operations = [{'op': 'set', 'path': ['prefs'], 'value': {'enabled': True, 'nested': [{'name': 'new'}]}}]
    updated = app.cli('plugins', 'settings', 'patch', 'acme.tools', '--operations', json.dumps(operations), '--expected-write-revision', namespace['writeRevision'])
    assert updated['values']['prefs'] == operations[0]['value']
    assert updated['values']['items'] == [{'name': 'original'}]
    assert '# keep application comment' in app.config.read_text() and '# array comment' in app.config.read_text()
    assert app.cli('plugins', 'settings', 'get', 'other')['values'] == {'private': 'other namespace'}
    app.cli('appearance', 'dark')
    app.rpc('debug.settings', fontSize='14', apply=True)
    assert app.rpc('config.get')['current']['terminal']['font_size'] == 14
    assert app.rpc('pane.inspect', pane='p1')['sessionId'] == session
    assert app.cli('plugins', 'settings', 'get', 'acme.tools')['values'] == updated['values']
    app.rpc('plugins.settings.patch', id='acme.tools', operations=operations, expectedWriteRevision=namespace['writeRevision'], error=-32050)
    for invalid in [[{'op': 'set', 'path': ['prefs'], 'value': None}],
                    [{'op': 'set', 'path': ['prefs'], 'value': {}}, {'op': 'delete', 'path': ['prefs', 'enabled']}]]:
        before = app.config.read_text()
        current = app.rpc('plugins.settings.get', id='acme.tools')
        app.rpc('plugins.settings.patch', id='acme.tools', operations=invalid, expectedWriteRevision=current['writeRevision'], error=-32602)
        assert app.config.read_text() == before

    panel = app.root / 'panel'
    panel.mkdir()
    (panel / 'index.html').write_text('<!doctype html><title>Settings fixture</title><p>Settings fixture</p>')
    for plugin in ['acme.tools', 'other']:
        app.rpc('plugins.register', packagePath=package_fixture({'id': plugin, 'title': plugin, 'source': {'kind': 'directory', 'path': str(panel)}}, app.root))
    app.rpc('command.run', id='pane.type', pane='p1', type='acme.tools', force=True)
    p2 = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=p2, type='other', force=True)

    def evaluate(script, pane='p1'):
        return app.rpc('debug.pluginEval', pane=pane, script=script)

    for pane in ['p1', p2]:
        eventually('plugin ready', lambda pane=pane: evaluate('typeof workspace', pane) == 'object')
    assert evaluate('await workspace.pluginSettings.get()')['id'] == 'acme.tools'
    assert evaluate('await workspace.call("plugins.settings.get",{id:"other"})')['id'] == 'other'
    stale = evaluate('await workspace.call("plugins.settings.patch",{id:"other",operations:[],expectedWriteRevision:"stale"}).then(()=>null,e=>e.code)')
    assert stale == -32050
    cursor = app.rpc('events.head')['cursor']
    result = evaluate('(async()=>{const s=await workspace.pluginSettings.get();return await workspace.pluginSettings.patch([{op:"set",path:["hookValue"],value:42}],s.writeRevision);})()')
    assert result['values']['hookValue'] == 42
    assert evaluate('await workspace.settings()')['hookValue'] == 42
    query = json.dumps({'after': cursor, 'topics': ['host.plugin.settings.changed'], 'waitMilliseconds': 0})
    own = evaluate('await workspace.call("events.poll",' + query + ')')
    other = evaluate('await workspace.call("events.poll",' + query + ')', p2)
    assert len(own['events']) == 1, own
    detail = own['events'][0]['payload']
    assert detail['pluginId'] == 'acme.tools' and detail['operationId'] and detail['changedPaths'], detail
    assert not {'values', 'appliedValues', 'origin', 'parentOperationId'} & detail.keys(), detail
    assert not other['events'], other
    before_failure = app.config.read_text()
    app.root.chmod(0o500)
    try:
        failure = evaluate('(async()=>{const s=await workspace.pluginSettings.get();try{await workspace.pluginSettings.patch([{op:"set",path:["blocked"],value:true}],s.writeRevision);return null;}catch(e){return {code:e.code,data:e.data};}})()')
        assert failure['code'] == -32054 and failure['data']['persisted'] is False, failure
        assert failure['data']['outcome'] == 'unknown'
        assert app.config.read_text() == before_failure
    finally:
        app.root.chmod(0o700)
    app.rpc('debug.configurationApplyFault', mode='reject')
    rollback = evaluate('(async()=>{const s=await workspace.pluginSettings.get();try{await workspace.pluginSettings.patch([{op:"set",path:["postWrite"],value:true}],s.writeRevision);return null;}catch(e){return {code:e.code,message:e.message,data:e.data};}})()')
    assert rollback['code'] == -32054 and rollback['data']['persisted'] is False, rollback
    assert 'Injected' not in rollback['message'] and app.config.read_text() == before_failure
    external = before_failure + '\n# external private marker\n'
    app.rpc('debug.configurationApplyFault', mode='externalEdit', source=external)
    preserved = evaluate('(async()=>{const s=await workspace.pluginSettings.get();try{await workspace.pluginSettings.patch([{op:"set",path:["postWrite"],value:true}],s.writeRevision);return null;}catch(e){return {code:e.code,message:e.message,data:e.data};}})()')
    assert preserved['code'] == -32054 and preserved['data']['persisted'] is False, preserved
    assert 'external edit was preserved' not in preserved['message'] and app.config.read_text() == external
    assert set(preserved['data']) <= {'operationId', 'sourceRevision', 'appliedRevision', 'sourceValid', 'appliedMatchesSource', 'outcome', 'persisted'}
    invalid = before_failure + '\n[plugins.hidden]\npassword = "foreign-private-value" trailing\n'
    app.config.write_text(invalid)
    assert evaluate('await workspace.pluginSettings.get()')['sourceValid'] is False
    private_error = evaluate('(async()=>{const s=await workspace.pluginSettings.get();try{await workspace.pluginSettings.patch([{op:"set",path:["blocked"],value:true}],s.writeRevision);return null;}catch(e){return {code:e.code,message:e.message,data:e.data};}})()')
    assert private_error['code'] == -32602 and 'foreign-private-value' not in json.dumps(private_error), private_error
    assert app.config.read_text() == invalid
    app.config.write_text('[terminal]\nshell="/bin/zsh"\n[plugins.other]\nprivate="other namespace"\n')
    assert app.rpc('plugins.settings.get', id='acme.tools')['values'] == {}, 'Removed source namespace resurrected applied settings'
print('Plugin settings patches, native TOML compatibility, private change hooks and typed failures passed')
