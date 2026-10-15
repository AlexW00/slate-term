#!/usr/bin/env python3
"""One owned app; manual services via production CLI/API. No activation, clicks or screenshots."""
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
from api_fixture import AppFixture, CLI, eventually
from trusted_api_fixture import verify_trusted_api


def service_rpc(env, method, params=None, error=None):
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(15)
        peer.connect(env['SLATE_TERM_SOCKET'])
        with peer.makefile('rb') as stream:
            hello = dict(protocolVersion=1)
            peer.sendall(json.dumps(dict(jsonrpc='2.0', id=1, method='hello', params=hello)).encode() + b'\n')
            reply = json.loads(stream.readline())
            assert reply['result']['service'] == dict(appInstanceId=env['SLATE_TERM_INSTANCE_ID'],
                pluginId=env['SLATE_TERM_SERVICE_PLUGIN_ID'], serviceId=env['SLATE_TERM_SERVICE_ID'],
                generation=env['SLATE_TERM_SERVICE_GENERATION']), 'wrong service generation'
            peer.sendall(json.dumps(dict(jsonrpc='2.0', id=2, method=method, params=params or {})).encode() + b'\n')
            data = stream.readline()
            if not data:
                raise ConnectionError('Service endpoint retired')
            reply = json.loads(data)
    if error is not None:
        assert reply.get('error', {}).get('code') == error, reply
        return reply['error']
    assert 'error' not in reply, reply
    return reply['result']


def alive(pid):
    result = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(pid)], text=True, capture_output=True, timeout=2)
    return result.returncode == 0 and result.stdout.strip() and not result.stdout.strip().startswith('Z')


with AppFixture('trusted-api-services', '[terminal]\nshell="/bin/zsh"\n[plugins.controller]\nvalue=1\n[plugins.other]\nvalue="private-other"\n') as app:
    worker = app.root / 'service.py'
    worker.write_text('''import json,os,pathlib,subprocess,time
root=pathlib.Path(os.environ['TEST_ROOT']); name=os.environ['SLATE_TERM_SERVICE_PLUGIN_ID']
def rpc(method,params=None):
 result=subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc',method,'--params',json.dumps(params or {}),'--json'],capture_output=True,text=True,timeout=8)
 if result.returncode: raise RuntimeError(result.stderr)
 return json.loads(result.stdout)
def save(suffix,data):
 path=root/(name+suffix); temporary=path.with_suffix(path.suffix+'.tmp')
 temporary.write_text(json.dumps(data)); temporary.chmod(0o600); temporary.replace(path)
snapshot=rpc('workspace.snapshot')
settings=rpc('plugins.settings.get')
assert 'SLATE_TERM_SERVICE_TOKEN' not in os.environ
starting=rpc('events.emit',{'topic':'fixture.starting'})
save('.context',{k:v for k,v in os.environ.items() if k.startswith('SLATE_TERM_')})
save('.bootstrap',{'cursor':snapshot['eventCursor'],'settings':settings,'pid':os.getpid(),'starting':starting})
while not (root/(name+'.go')).exists(): time.sleep(.02)
rpc('service.ready',{'version':1})
save('.events',rpc('events.poll',{'after':snapshot['eventCursor'],'waitMilliseconds':0}))
print('READY',flush=True)
while True: time.sleep(1)
''')

    def register(name):
        manifest = dict(id=name, title=name, service=dict(executable=sys.executable,
            arguments=[str(worker)], environment={'TEST_ROOT': str(app.root)}, readyTimeoutSeconds=10))
        app.rpc('plugins.register', manifest=manifest)
        return manifest

    def read(name, suffix):
        return json.loads((app.root / (name + suffix)).read_text())

    def status(name):
        return app.rpc('plugins.service.status', id=name)

    describe = app.cli('rpc', 'api.describe')
    assert describe['backgroundServices']['mode'] == 'manual'
    assert not describe['backgroundServices']['automaticStartup']
    assert 'plugins.service.start' in describe['methods']
    first_manifest = register('controller')
    register('other')
    assert all(s['state'] == 'stopped' for s in app.cli('plugins', 'service', 'list'))
    assert not (app.root / 'controller.bootstrap').exists(), 'Registration activated a service'
    first = app.cli('plugins', 'service', 'start', 'controller')
    assert first['generation'] == app.cli('plugins', 'service', 'start', 'controller')['generation']
    app.cli('plugins', 'service', 'start', 'other')
    for name in ['controller', 'other']:
        eventually(name + ' bootstrap', lambda name=name: (app.root / (name + '.bootstrap')).exists())
        assert status(name)['state'] == 'starting'
        current = app.rpc('plugins.settings.get', id=name)
        app.rpc('plugins.settings.patch', id=name, expectedWriteRevision=current['writeRevision'],
                operations=[dict(op='set', path=['value'], value=2 if name == 'controller' else 'new-private-other')])
    for name in ['controller', 'other']:
        (app.root / (name + '.go')).touch()
        eventually(name + ' ready and replay', lambda name=name: status(name)['state'] == 'ready' and (app.root / (name + '.events')).exists())
    context = read('controller', '.context')
    batch = read('controller', '.events')
    directed = [e for e in batch['events'] if e['topic'] == 'host.plugin.settings.changed']
    assert len(directed) == 1 and directed[0]['payload']['pluginId'] == 'controller', 'Settings observer crossed namespace'
    assert directed[0]['targetService']['generation'] == first['generation']
    assert 'private-other' not in json.dumps(batch), 'Foreign settings leaked'
    assert read('controller', '.bootstrap')['settings']['values']['value'] == 1
    assert service_rpc(context, 'plugins.settings.get')['values']['value'] == 2
    assert read('controller', '.bootstrap')['starting']['source']['kind'] == 'service'
    assert 'SLATE_TERM_SERVICE_TOKEN' not in context
    verify_trusted_api(app, lambda method, params=None, error=None: service_rpc(context, method, params, error))
    app.rpc('plugins.register', manifest=dict(id='tools', title='Tools', commands=[
        dict(id='parent', title='Parent', executable=str(CLI), arguments=['rpc','command.run','--params','{"id":"plugin.tools.child"}']),
        dict(id='child', title='Child', executable='/bin/sleep', arguments=['30'])]))
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(service_rpc, context, 'command.run', {'id': 'plugin.tools.parent'})
        eventually('nested service commands', lambda: len([s for s in app.rpc('plugins.status', id='tools') if s['state'] == 'running']) == 2)
        jobs = app.rpc('plugins.status', id='tools')
        stopped = app.cli('plugins', 'service', 'stop', 'controller')
        assert stopped['state'] == 'stopped' and stopped['cleanupConfirmed']
        try:
            pending.result(timeout=5)
            raise AssertionError('Retired service command returned success')
        except (ConnectionError, OSError):
            pass
        assert all(s['state'] == 'cancelled' and not s['cleanupPending'] for s in app.rpc('plugins.status', id='tools'))
        for job in jobs:
            eventually('owned nested process exited', lambda job=job: not alive(job['pid']))
    assert status('other')['state'] == 'ready', 'Stop affected unrelated service'
    try:
        service_rpc(context, 'api.describe')
        raise AssertionError('Retired endpoint remained accessible')
    except (ConnectionError, OSError):
        pass
    second = app.cli('plugins', 'service', 'start', 'controller')
    assert second['generation'] != first['generation']
    eventually('new public generation context', lambda: read('controller', '.context')['SLATE_TERM_SERVICE_GENERATION'] == second['generation'])
    newer = read('controller', '.context')
    assert 'SLATE_TERM_SERVICE_TOKEN' not in newer
    eventually('second ready', lambda: status('controller')['state'] == 'ready')
    stale = dict(newer, SLATE_TERM_SERVICE_GENERATION=context['SLATE_TERM_SERVICE_GENERATION'])
    assert app.cli('rpc', 'api.describe', env=stale, error=True)['code'] == -32059
    eventually('service stdout', lambda: 'READY' in app.cli('plugins', 'service', 'logs', 'controller')['stdout'])
    controller_pid = read('controller', '.bootstrap')['pid']
    app.rpc('plugins.register', manifest=first_manifest, replace=True)
    eventually('replacement retired old process', lambda: not alive(controller_pid))
    assert status('controller')['state'] == 'stopped'
    app.rpc('plugins.unregister', id='controller')
    assert [s['pluginId'] for s in app.cli('plugins', 'service', 'list')] == ['other']
    other_pid = read('other', '.bootstrap')['pid']
    print('PASS one-app manual services: CLI controls, no implicit activation, starting mutation/settings replay, shared API parity, nested ownership, fresh public generations, replacement/unregister')
eventually('app shutdown retired service', lambda: not alive(other_pid))
print('PASS owned app shutdown/parent-death cleanup')
