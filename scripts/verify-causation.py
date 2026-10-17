#!/usr/bin/env python3
"""Production socket/CLI/page causation, replay, audience retirement and loop admission."""
import json
import socket
from api_fixture import AppFixture, eventually
from plugin_package_fixture import package_fixture

with AppFixture('causation') as app:
    assert app.rpc('api.describe')['causation']['version'] == 1

    def title(value, cause=None, error=None):
        return app.rpc('command.run', id='pane.title.set', pane='p1', title=value,
                       request_metadata=None if cause is None else dict(version=1, cause=cause), error=error)

    def changes(cursor):
        return app.rpc('events.poll', after=cursor, topics=['host.pane.title.changed'], waitMilliseconds=0)['events']

    cursor = app.rpc('events.head')['cursor']
    root = title('root')
    event = changes(cursor)[0]
    token = event['deliveryContext']
    assert event['payload']['operationId'] == root['operationId']
    assert changes(cursor)[0]['deliveryContext'] == token, 'Replay renewed or replaced a live reference'
    before = app.rpc('workspace.get')
    title('forged', 'not-a-delivery-reference', error=-32055)
    assert app.rpc('workspace.get') == before
    cli = app.cli('panes', 'set-title', '--pane', 'p1', '--title', 'CLI child', '--cause', token)
    sibling = title('socket sibling', token)
    children = changes(event['cursor'])
    assert len(children) == 2
    assert all(e['payload']['causalDepth'] == 1 and e['payload']['parentOperationId'] == root['operationId'] for e in children)
    assert {e['payload']['operationId'] for e in children} == {cli['operationId'], sibling['operationId']}
    parent = children[-1]
    for depth in range(2, 9):
        result = title('depth-' + str(depth), parent['deliveryContext'])
        child = changes(parent['cursor'])[-1]
        assert child['payload']['causalDepth'] == depth and child['payload']['parentOperationId'] == parent['payload']['operationId']
        assert child['payload']['operationId'] == result['operationId']
        parent = child
    before = app.rpc('workspace.get')
    title('too deep', parent['deliveryContext'], error=-32056)
    assert app.rpc('workspace.get') == before

    panel = app.root / 'panel'
    panel.mkdir()
    (panel / 'index.html').write_text('<!doctype html><title>Causation fixture</title><p>Owned plugin</p>')
    app.rpc('plugins.register', packagePath=package_fixture({'id': 'causal.fixture', 'title': 'Causation fixture', 'scope': 'global',
                                         'source': {'kind': 'directory', 'path': str(panel)}}, app.root))
    app.rpc('command.run', id='pane.type', pane='p1', type='causal.fixture', force=True)
    second = app.rpc('command.run', id='split.right', pane='p1')['paneId']
    app.rpc('command.run', id='pane.type', pane=second, type='causal.fixture', force=True)

    def js(code, pane='p1'):
        return app.rpc('debug.pluginEval', pane=pane, script=code)

    for p in ['p1', second]:
        eventually('owned bridge ready', lambda p=p: js('typeof workspace', p) == 'object')
    cursor = app.rpc('events.head')['cursor']
    title('page parent')
    query = json.dumps(dict(after=cursor, topics=['host.pane.title.changed'], waitMilliseconds=0))
    page = js('await workspace.call("events.poll",' + query + ')')['events'][0]
    other = js('await workspace.call("events.poll",' + query + ')', second)['events'][0]
    administrative = changes(cursor)[0]
    assert len({page['deliveryContext'], other['deliveryContext'], administrative['deliveryContext']}) == 3
    assert page['payload']['operationId'] == administrative['payload']['operationId']
    cause = json.dumps(page['deliveryContext'])
    denied = js('workspace.command("pane.title.set",{pane:"p1",title:"foreign"},{cause:' + cause + '}).then(()=>null,e=>e.code)', second)
    assert denied == -32055
    title('foreign admin', page['deliveryContext'], error=-32055)
    result = js('workspace.panes.setTitle("page child",{pane:"p1"},{cause:' + cause + '})')
    child = changes(page['cursor'])[-1]
    assert child['payload']['operationId'] == result['operationId'] and child['payload']['causalDepth'] == 1
    assert child['payload']['origin']['kind'] == 'plugin'

    # Reads and transport cancellation survive a depleted plugin budget; no-op mutations
    # still count. The two global-instance views share the plugin-ID admission bucket.
    outcomes = js('(async()=>Promise.all(Array.from({length:30},()=>workspace.command("pane.title.set",{pane:"p1",title:"budget"}).then(()=>0,e=>e.code))))()')
    assert 0 in outcomes and -32057 in outcomes and set(outcomes) <= {0, -32057}, outcomes
    assert js('await workspace.inspect()')['appInstanceId']
    assert js('(async()=>{const c=new AbortController();const p=workspace.call("events.poll",{waitMilliseconds:25000},{signal:c.signal});c.abort();return p.then(()=>false,e=>e.name==="AbortError");})()')

    # Restart retires document-bound references, not merely an outstanding poll.
    app.rpc('plugins.restart', id='causal.fixture')
    # The previous JS global can survive while navigation is pending. Require an
    # authenticated read from the ready document, not merely an existing SDK object.
    eventually('restarted bridge ready', lambda: js('typeof workspace === "object" ? workspace.self().then(()=>true,()=>false) : false'))
    retired = js('workspace.command("pane.title.set",{pane:"p1",title:"retired"},{cause:' + cause + '}).then(()=>null,e=>e.code)')
    assert retired == -32055, dict(retired=retired)

    # Bounded pipelined bursts avoid measuring subprocess startup instead of admission.
    # Stay below the peer's 64-message queue, and never replay a refused publication.
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(5)
        peer.connect(app.path)
        with peer.makefile('rb') as stream:
            peer.sendall(b'{"jsonrpc":"2.0","id":1,"method":"hello","params":{"protocolVersion":1}}\n')
            assert 'error' not in json.loads(stream.readline())
            throttled = False
            for batch in range(8):
                requests = [dict(jsonrpc='2.0', id=2 + batch * 32 + i, method='events.emit',
                                 params=dict(topic='causal.load', payload={'index': batch * 32 + i})) for i in range(32)]
                peer.sendall(b''.join(json.dumps(r).encode() + b'\n' for r in requests))
                replies = [json.loads(stream.readline()) for _ in requests]
                assert all('result' in r or r['error']['code'] == -32057 for r in replies), replies
                if any('error' in r for r in replies):
                    throttled = True
                    break
            assert throttled, 'Global automation budget was not enforced'
            for i, method in enumerate(['events.head', 'workspace.snapshot', 'api.describe']):
                peer.sendall(json.dumps(dict(jsonrpc='2.0', id=1000 + i, method=method, params={})).encode() + b'\n')
                assert 'result' in json.loads(stream.readline()), method

print('PASS causation: socket/CLI/page lineage, sibling replay, depth refusal, view/admin/document audiences, plugin/global admission and read/cancel recovery')
