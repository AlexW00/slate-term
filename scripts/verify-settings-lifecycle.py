#!/usr/bin/env python3
"""Source/apply outcomes and whole-envelope isolation for own-plugin settings."""
import json
from api_fixture import AppFixture, eventually
from plugin_package_fixture import package_fixture

source = '[terminal]\nshell="/bin/zsh"\n[plugins."private.owner"]\ntoken="PRIVATE_OLD"\n'
with AppFixture('settings-lifecycle', source) as app:
    assert app.rpc('api.describe')['settingsLifecycle']['scope'] == 'configurationSourceAndApplied'
    panel = app.root / 'panel'
    panel.mkdir()
    (panel / 'index.html').write_text('<!doctype html><title>Settings lifecycle</title>')
    for name in ['private.owner', 'unrelated.reader']:
        app.rpc('plugins.register', packagePath=package_fixture(dict(id=name, title=name, scope='pane', source=dict(kind='directory', path=str(panel))), app.root))
    app.rpc('command.run', id='pane.type', pane='p1', type='private.owner', force=True)
    p2 = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=p2, type='unrelated.reader', force=True)
    p3 = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=p3, type='private.owner', force=True)

    def js(script, pane='p1'):
        return app.rpc('debug.pluginEval', pane=pane, script=script)

    for pane in ['p1', p2]:
        eventually('bridge', lambda: js('typeof workspace', pane) == 'object')

    def facts(cursor):
        return app.rpc('events.poll', after=cursor, topics=['host.settings.*', 'host.plugin.settings.changed'], waitMilliseconds=0)['events']

    def private_free(events):
        for e in events:
            if not e['topic'].startswith('host.settings.'): continue
            assert not {'tab', 'pane', 'targetInstanceId'} & e.keys(), e
            assert e['source'] == {'kind': 'host'}
            assert not {'origin', 'parentOperationId', 'causalDepth', 'pluginId', 'paneId', 'tabId', 'changedPaths', 'actionKind'} & e['payload'].keys(), e
            text = json.dumps(e)
            assert 'private.owner' not in text and 'PRIVATE_' not in text, e

    cursor = app.rpc('events.head')['cursor']
    app.rpc('command.run', id='pane.title.set', pane='p1', title='PRIVATE_PARENT')
    query = json.dumps(dict(after=cursor, topics=['host.pane.title.changed'], waitMilliseconds=0))
    parent = js('workspace.call("events.poll",' + query + ')')['events'][0]
    result = js('(async()=>{const s=await workspace.pluginSettings.get();return workspace.pluginSettings.patch([{op:"set",path:["token"],value:"PRIVATE_NEW"}],s.writeRevision,{cause:' + json.dumps(parent['deliveryContext']) + '});})()')
    changed = facts(cursor)
    assert sorted(e['topic'] for e in changed) == ['host.plugin.settings.changed', 'host.plugin.settings.changed', 'host.settings.changed', 'host.settings.source.changed'], changed
    assert {e['payload']['operationId'] for e in changed} == {result['operationId']}, changed
    private_free(changed)
    directed = [e for e in changed if e['topic'] == 'host.plugin.settings.changed']
    assert len({e['targetInstanceId'] for e in directed}) == 2
    assert all(e['payload']['changedPaths'] == [['token']] for e in directed) and 'PRIVATE_' not in json.dumps(directed)
    query = json.dumps(dict(after=cursor, topics=['host.settings.*', 'host.plugin.settings.changed'], waitMilliseconds=0))
    foreign = js('workspace.call("events.poll",' + query + ')', p2)['events']
    assert len(foreign) == 2 and all(e['topic'].startswith('host.settings.') for e in foreign), foreign
    private_free(foreign)

    cursor = app.rpc('events.head')['cursor']
    js('(async()=>{const s=await workspace.pluginSettings.get();return workspace.pluginSettings.patch([{op:"set",path:["token"],value:"PRIVATE_NEW"}],s.writeRevision);})()')
    assert not facts(cursor), 'No-op fabricated settings changes'

    before = app.rpc('config.get')
    cursor = app.rpc('events.head')['cursor']
    app.config.write_text(app.config.read_text() + '\n# PRIVATE_COMMENT\n')
    app.rpc('config.reload')
    observed = facts(cursor)
    assert [e['topic'] for e in observed] == ['host.settings.source.changed'], observed
    assert app.rpc('config.get')['appliedRevision'] == before['appliedRevision']
    private_free(observed)

    # Failure before apply, rollback, and an intervening external edit must never
    # produce a successful applied-settings fact or expose diagnostics/values.
    for mode in ['reject', 'externalEdit']:
        original = app.config.read_text()
        fault = dict(mode=mode)
        if mode == 'externalEdit': fault['source'] = original + '\n# PRIVATE_EXTERNAL\n'
        app.rpc('debug.configurationApplyFault', **fault)
        cursor = app.rpc('events.head')['cursor']
        failure = js('(async()=>{const s=await workspace.pluginSettings.get();try{await workspace.pluginSettings.patch([{op:"set",path:["token"],value:"PRIVATE_REJECTED"}],s.writeRevision);return null;}catch(e){return {code:e.code,data:e.data};}})()')
        assert failure['code'] == -32054
        observed = facts(cursor)
        assert [e for e in observed if e['topic'] == 'host.settings.failed'], observed
        assert not any(e['topic'] in ['host.settings.changed', 'host.plugin.settings.changed'] for e in observed), observed
        failed = next(e['payload'] for e in observed if e['topic'] == 'host.settings.failed')
        assert failed['persisted'] is False and failed['sourceValid'] is True
        assert failed['operationId'] == failure['data']['operationId']
        assert failed['beforeAppliedRevision'] == failed['appliedRevision']
        assert app.config.read_text() == (fault['source'] if mode == 'externalEdit' else original)
        private_free(observed)

    # Both path count and actual JSON-encoded bytes are bounded. External writes
    # exercise the same native reload boundary without exceeding patch operation caps.
    baseline = app.config.read_text()
    for keys in [[f'key{i:02}' for i in range(40)], ['key' + '"' * 1000 + str(i) for i in range(4)]]:
        cursor = app.rpc('events.head')['cursor']
        app.config.write_text(baseline + '\n' + '\n'.join(json.dumps(key) + '=true' for key in keys) + '\n')
        app.rpc('config.reload')
        detail = next(e['payload'] for e in facts(cursor) if e['topic'] == 'host.plugin.settings.changed')
        assert detail['changeCount'] == len(keys) and detail['truncated'] is True, detail
        assert len(detail['changedPaths']) <= 32
        assert sum(len(json.dumps(p, ensure_ascii=False, separators=(',', ':')).encode()) for p in detail['changedPaths']) <= 4096
        app.config.write_text(baseline)
        app.rpc('config.reload')

    # A source read failure must still update application status and retain the
    # previous applied configuration, with a correlated, diagnostic-free failure.
    before = app.rpc('config.get')
    cursor = app.rpc('events.head')['cursor']
    app.config.write_bytes(b'\xff')
    failure = app.rpc('config.reload', error=-32020)
    observed = facts(cursor)
    failed = next(e['payload'] for e in observed if e['topic'] == 'host.settings.failed' and e['payload']['operationId'] == failure['data']['operationId'])
    assert failed['sourceRevision'] is None and failed['sourceValid'] is False
    status = app.rpc('config.get')
    assert status['error'] and status['appliedRevision'] == before['appliedRevision'] and status['current'] == before['current']
    private_free(observed)

print('PASS settings lifecycle: correlated source/apply/failure facts, no-op, source-only, rollback/external edit, unreadable status, bounded paths and complete global-envelope privacy')
