#!/usr/bin/env python3
"""Existing directed storage notifications must preserve admitted causal depth."""
import json
from api_fixture import AppFixture, eventually

with AppFixture('storage-causation') as app:
    panel = app.root / 'panel'
    panel.mkdir()
    (panel / 'index.html').write_text('<!doctype html><title>Storage causation</title>')
    app.rpc('plugins.register', manifest={'id': 'storage.fixture', 'title': 'Storage fixture',
                                         'source': {'kind': 'directory', 'path': str(panel)}})
    app.rpc('command.run', id='pane.type', pane='p1', type='storage.fixture', force=True)

    def js(script):
        return app.rpc('debug.pluginEval', pane='p1', script=script)

    eventually('owned bridge', lambda: js('typeof workspace') == 'object')
    cursor = app.rpc('events.head')['cursor']
    js('workspace.storage.set("counter",0)')
    for value in range(1, 10):
        query = json.dumps(dict(after=cursor, topics=['host.plugin.storage.changed'], waitMilliseconds=0))
        batch = js('workspace.call("events.poll",' + query + ')')
        event = batch['events'][-1]
        assert event['targetInstanceId'] == js('workspace.plugin.instanceId')
        cause = json.dumps(event['deliveryContext'])
        result = js('workspace.storage.set("counter",' + str(value) + ',{cause:' + cause + '}).then(()=>0,e=>e.code)')
        assert result == (0 if value <= 8 else -32056), dict(value=value, result=result)
        cursor = batch['cursor']
    assert js('workspace.storage.get("counter")') == 8

print('PASS directed storage notifications preserve causal depth and reject the next write without changing storage')
