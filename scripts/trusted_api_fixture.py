"""Three trusted clients in the caller's owned app; no extra app or activation."""
import functools
import http.server
import json
import threading
from api_fixture import eventually


def verify_trusted_api(app, service_call):
    assets = app.root / 'parity-panel'
    assets.mkdir()
    (assets / 'index.html').write_text('<!doctype html><title>Parity</title><input id="value" value="before"><iframe src="child.html"></iframe>')
    (assets / 'child.html').write_text('<!doctype html><p>child</p>')
    app.rpc('plugins.register', manifest=dict(id='parity.fixture', title='Parity', scope='global', source=dict(kind='directory', path=str(assets))))
    panel = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=panel, type='parity.fixture', force=True)
    sibling = app.rpc('command.run', id='split.down', pane=panel)['paneId']
    app.rpc('command.run', id='pane.type', pane=sibling, type='parity.fixture', force=True)

    def js(script):
        return app.rpc('debug.pluginEval', pane=panel, script=script)

    def bridge(method, params=None, error=None):
        result = js('await workspace.call(' + json.dumps(method) + ',' + json.dumps(params or {}) + ').then(value=>({value}),e=>({error:{code:e.code,message:e.message,data:e.data}}))')
        if error is not None:
            assert result.get('error', {}).get('code') == error, result
            return result['error']
        assert 'error' not in result, result
        return result.get('value')

    def cli(method, params=None, error=None):
        result = app.cli('rpc', method, '--params', json.dumps(params or {}), error=error is not None)
        if error is not None:
            assert result['code'] == error, result
        return result

    clients = [('cli', cli), ('bridge', bridge), ('service', service_call)]
    eventually('bridge ready', lambda: js('typeof workspace') == 'object')
    for pane in [panel, sibling]:
        eventually('plugin document identity', lambda pane=pane: app.rpc('web.get', pane=pane).get('documentId') is not None)
    expected = app.rpc('api.describe')
    for name, call in clients:
        assert call('api.describe') == expected, name
    assert js('workspace.methods') == expected['methods']
    assert js('Object.keys(workspace.rpc).sort()') == expected['methods']
    assert js("(()=>{try{return typeof document.querySelector('iframe').contentWindow.workspace}catch{return 'blocked'}})()") in ['undefined', 'blocked']
    source_title = 'Source view'
    assert js('await workspace.setTitle(' + json.dumps(source_title) + ')') is None
    instance = app.rpc('pane.inspect', pane=panel)['pluginInstanceId']
    assert app.rpc('pane.inspect', pane=sibling)['pluginInstanceId'] == instance
    target = app.rpc('web.get', pane=sibling)
    guards = dict(expectedViewId=target['viewId'], expectedDocumentId=target['documentId'])
    for name, call in clients:
        managed = 'managed-' + name
        call('plugins.register', {'manifest': dict(id=managed, title=managed,
             commands=[dict(id='test', title='Test', executable='/usr/bin/true')])})
        assert call('plugins.disable', {'id': managed})['enabled'] is False
        assert not next(p for p in cli('plugins.list') if p['id'] == managed)['enabled']
        assert call('plugins.enable', {'id': managed})['enabled'] is True
        call('plugins.unregister', {'id': managed})
        assert call('config.get')['current']
        assert call('window.list')
        call('command.run', {'id': 'config.reload'})
        namespace = call('plugins.settings.get', {'id': 'other'})
        patched = call('plugins.settings.patch', dict(id='other', expectedWriteRevision=namespace['writeRevision'],
            operations=[dict(op='set', path=['parity'], value=name)]))
        assert patched['values']['parity'] == name
        call('storage.set', dict(instanceId=instance, key='parity', value=name))
        assert cli('storage.get', dict(pane=sibling, key='parity')) == name
        call('pane.title', dict(pane=sibling, title=name, **guards))
        assert app.rpc('pane.inspect', pane=sibling)['title'] == name
        assert app.rpc('pane.inspect', pane=panel)['title'] == source_title
        call('pane.title', dict(pane=sibling, title='unguarded'), error=-32602)
        bad = call('plugins.settings.patch', dict(id='other', expectedWriteRevision=patched['writeRevision'],
            operations=[dict(op='invalid-private-marker', path=['value'])]), error=-32602)
        assert 'invalid-private-marker' not in json.dumps(bad)
        # Starting/stopping a service from another trusted client does not transfer its ownership.
        assert call('plugins.service.start', {'id': 'other'})['state'] == 'ready'
        cursor = app.rpc('events.head')['cursor']
        call('events.emit', dict(topic='parity.directed', payload=name, targetInstanceId=instance))
        query = dict(after=cursor, topics=['parity.directed'], recipient='all', scope='global', waitMilliseconds=0)
        observed = call('events.poll', query)['events']
        assert len(observed) == 1 and observed[0]['payload'] == name
        assert observed[0]['source']['kind'] == {'cli': 'client', 'bridge': 'plugin', 'service': 'service'}[name]
        query['recipient'] = {'instanceId': instance}
        assert len(call('events.poll', query)['events']) == 1
    owner = service_call('plugins.service.status', {'id': 'controller'})
    cursor = app.rpc('events.head')['cursor']
    recipient = dict(serviceId=owner['serviceId'], generation=owner['generation'])
    bridge('events.emit', dict(topic='parity.service', targetService=recipient))
    for _, call in clients:
        assert len(call('events.poll', dict(after=cursor, topics=['parity.service'], recipient=recipient, waitMilliseconds=0))['events']) == 1

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=str(assets)))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        browser = app.rpc('command.run', id='split.down', pane='p1')['paneId']
        app.rpc('command.run', id='pane.type', pane=browser, type='browser', force=True)
        bridge('browser.navigate', dict(pane=browser, url=f'http://127.0.0.1:{server.server_port}/index.html'))
        assert bridge('browser.eval', dict(pane=browser, script='typeof workspace')) == 'undefined'
        assert service_call('browser.eval', dict(pane=browser, script="typeof document.querySelector('iframe').contentWindow.workspace")) == 'undefined'
        for name, call in clients:
            web = call('web.get', {'pane': browser})
            call('web.fill', dict(pane=browser, selector='#value', text=name,
                expectedViewId=web['viewId'], expectedDocumentId=web['documentId']))
            assert app.rpc('browser.eval', pane=browser, script="document.querySelector('#value').value") == name
            call('terminal.capture', {'pane': 'p1'})
        # Existing zoom must still withhold hidden document actions without retiring it.
        before = app.rpc('web.get', pane=panel)
        service_call('command.run', dict(id='pane.zoom', pane='p1'))
        assert bridge('web.get')['renderable'] is False
        assert bridge('web.get')['screenshotReady'] is False
        bridge('web.snapshot', {}, error=-32051)
        for name, call in clients:
            call('web.screenshot', dict(pane=panel, path=str(app.root / (name + '-zoom-hidden.png'))), error=-32051)
        service_call('command.run', dict(id='pane.zoom', pane='p1'))
        eventually('unzoom renderable', lambda: app.rpc('web.get', pane=panel)['renderable'])
        assert app.rpc('web.get', pane=panel)['documentId'] == before['documentId']

        # Default targets must resolve before layout guards, even with another key tab.
        tab = app.rpc('pane.inspect', pane=panel)['tabId']
        revision = app.rpc('pane.inspect', pane=panel)['layoutRevision']
        app.rpc('command.run', id='tab.new')
        assert bridge('pane.inspect', {'expectedLayoutRevision': revision})['paneId'] == panel
        before = app.rpc('workspace.get')
        for pane in [panel, browser]:
            eventually('background capture ready', lambda: app.rpc('web.get', pane=pane)['screenshotReady'])
            identity = app.rpc('web.get', pane=pane)
            assert not identity['renderable'] and not app.rpc('pane.inspect', pane=pane)['visible']
            for name, call in clients:
                info = call('api.describe')['webAutomation']
                assert info['screenshotInactiveTabs'] and info['domRequiresVisiblePane']
                path = app.root / f'{name}-{pane}-background.png'
                result = call('web.screenshot', dict(pane=pane, path=str(path),
                    expectedViewId=identity['viewId'], expectedDocumentId=identity['documentId']))
                assert result['path'] == str(path) and result['documentId'] == identity['documentId']
                assert path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
                call('web.snapshot', {'pane': pane}, error=-32051)
                assert app.rpc('workspace.get') == before
        app.rpc('command.run', id='tab.focus', tab=tab)

        # A new document in a shared logical instance must reject an old automatic title.
        app.rpc('plugins.restart', id='parity.fixture')
        eventually('successor document', lambda: app.rpc('web.get', pane=sibling).get('documentId') not in [None, target['documentId']])
        eventually('successor bridge', lambda: js('typeof workspace') == 'object')
        for _, call in clients:
            call('pane.title', dict(pane=sibling, title='stale', **guards), error=-32050)
        assert app.rpc('pane.inspect', pane=sibling)['title'] != 'stale'
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
    print('PASS three-client shared discovery/dispatch, namespace writes, storage, document titles, event recipients, browser/terminal control, inactive-tab capture/guards, DOM visibility, ordinary-page/subframe boundary and zoom')
