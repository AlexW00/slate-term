#!/usr/bin/env python3
"""VM-only lifecycle checks for two owned layout apps and their isolated parent."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

import api_fixture
from api_fixture import AppFixture, ROOT, eventually
from contract_capture import ContractCapture
from plugin_package_fixture import package_fixture

# The prepared runner may supply a release executable. Never search installed apps.
if os.environ.get('SLATE_TERM_TEST_APP'):
    api_fixture.APP = Path(os.environ['SLATE_TERM_TEST_APP'])
api_fixture.CLI = api_fixture.APP.parent.parent / 'Frameworks/SlateRuntime.framework/Helpers/slate-term'


def require_vm():
    model = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip()
    assert model.startswith('VirtualMac'), 'Layout-app lifecycle checks run only in the test VM'


LAUNCH = r'''
ObjC.import('AppKit');
function run(args) {
    const url = $.NSURL.fileURLWithPath(args[0]);
    const configuration = $.NSWorkspaceOpenConfiguration.configuration;
    configuration.environment = $(JSON.parse(args[1]));
    configuration.arguments = $(JSON.parse(args[2] || "[]"));
    configuration.activates = false;
    let finished = false, answer = null;
    $.NSWorkspace.sharedWorkspace.openApplicationAtURLConfigurationCompletionHandler(url, configuration,
        function(app, error) {
            if (error && !error.isNil()) answer = {error: ObjC.unwrap(error.localizedDescription)};
            else if (!app || app.isNil()) answer = {error: "Launch Services returned no application"};
            else answer = {pid: Number(app.processIdentifier), bundleID: ObjC.unwrap(app.bundleIdentifier),
                path: ObjC.unwrap(app.bundleURL.path)};
            finished = true;
        });
    const deadline = Date.now() + 30000;
    while (!finished && Date.now() < deadline)
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.05));
    if (!finished) throw Error('Launch Services completion timed out');
    return JSON.stringify(answer);
}
'''
TERMINATE = r'''
ObjC.import('AppKit');
function run(args) {
    const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(args[0]));
    if (!app || app.isNil() || app.isTerminated) return 'stopped';
    if (ObjC.unwrap(app.bundleURL.URLByResolvingSymlinksInPath.path) !== ObjC.unwrap($.NSURL.fileURLWithPath(args[1]).URLByResolvingSymlinksInPath.path)) throw Error('Owned process changed bundle');
    if (!app.terminate) throw Error('Owned app refused termination');
    return 'requested';
}
'''


def jxa(script, *args):
    result = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script, *map(str, args)],
                            capture_output=True, text=True, timeout=40)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'<!doctype html><title>Layout App Fixture</title><p>Private browser data fixture</p>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class InstalledApps:
    """Use a normal installation location so LaunchServices retains registrations."""
    def __enter__(self):
        directory = Path.home() / 'Applications'
        directory.mkdir(exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix='SlateLayoutFixture-', dir=directory))
        print('Owned application fixtures: ' + str(self.root), flush=True)
        return self

    def __exit__(self, kind, error, traceback):
        if kind is not None:
            print('Preserved owned application fixtures: ' + str(self.root), flush=True)
            return
        for app in self.root.glob('*.app'):
            subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-u', str(app)], check=True)
        shutil.rmtree(self.root)


class LayoutApp:
    rpc = AppFixture.rpc
    cli = AppFixture.cli

    def __init__(self, parent, record, number):
        self.parent, self.record = parent, record
        self.root = parent.root / 'LayoutApps' / record['layoutAppID'].lower()
        self.bundle = Path(record['path'])
        info = plistlib.loads((self.bundle / 'Contents/Info.plist').read_bytes())
        self.executable = self.bundle / 'Contents/MacOS' / info['CFBundleExecutable']
        self.bundle_id = info['CFBundleIdentifier']
        self.pid = None
        self.path = None
        self.contract_capture = None
        self.number = number
        self.env = {k: v for k, v in parent.env.items() if not k.startswith('SLATE_TERM_')}
        self.env.update(SLATE_TERM_INTEGRATION='1', SLATE_TERM_TEST_REAL_SHELL='1',
                        SLATE_TERM_STATE_DIR=str(parent.root), SLATE_TERM_CONFIG_FILE=str(parent.config))

    def start(self, arguments=()):
        launch_environment = {key: value for key, value in self.env.items() if key != 'SLATE_TERM_SOCKET'}
        launched = json.loads(jxa(LAUNCH, self.bundle, json.dumps(launch_environment), json.dumps(list(arguments))))
        assert 'error' not in launched, launched
        old_pid, self.pid = self.pid, launched.get('pid')
        assert self.pid is not None and self.pid > 0, launched
        assert launched.get('path') and Path(launched['path']).resolve() == self.bundle.resolve(), launched
        assert launched.get('bundleID') == self.bundle_id, launched
        assert self.pid != self.parent.process.pid
        if old_pid is not None:
            assert self.pid == old_pid, 'Warm Launch Services activation created a second process'
        sockets = []
        def ready():
            sockets[:] = list((self.root / 'control').glob('*.sock'))
            if len(sockets) != 1:
                return False
            self.path = str(sockets[0])
            try:
                return self.rpc('api.describe')['layoutAppID'] == self.record['layoutAppID']
            except (OSError, ValueError):
                return False
        eventually('generated app control socket', ready, timeout=40)
        self.env['SLATE_TERM_SOCKET'] = self.path
        eventually('generated workspace published', lambda: bool(self.rpc('workspace.get')['panes']) and bool(self.rpc('window.list')['windows']), timeout=40)
        description = self.rpc('api.describe')
        assert description['mode'] == 'layoutApp', description
        self.instance = description['appInstanceId']
        if self.contract_capture is None:
            self.contract_capture = ContractCapture(ROOT / f'artifacts/layout-apps-{self.number}-contracts.jsonl', description)
        return self

    def stop(self):
        if self.pid is None:
            # A failed completion readback may still have launched this exact owned app.
            lookup = r"""ObjC.import('AppKit'); function run(args) {
                var apps=$.NSRunningApplication.runningApplicationsWithBundleIdentifier(args[0]), ids=[];
                for(var i=0;i<apps.count;i++){var app=apps.objectAtIndex(i);
                    if(ObjC.unwrap(app.bundleURL.URLByResolvingSymlinksInPath.path)===ObjC.unwrap($.NSURL.fileURLWithPath(args[1]).URLByResolvingSymlinksInPath.path)) ids.push(Number(app.processIdentifier));}
                return JSON.stringify(ids);
            }"""
            matches = json.loads(jxa(lookup, self.bundle_id, self.bundle.resolve()))
            assert len(matches) <= 1, ('Ambiguous owned app processes', matches)
            if not matches:
                return
            self.pid = matches[0]
        jxa(TERMINATE, self.pid, self.bundle.resolve())
        def stopped():
            try:
                os.kill(self.pid, 0)
                return False
            except ProcessLookupError:
                return True
        eventually('owned layout app quit', stopped, timeout=20)
        self.pid = None

    def move(self, destination):
        assert self.pid is None, 'Stop the owned app before moving it'
        self.bundle.rename(destination)
        self.bundle = destination
        self.executable = destination / 'Contents/MacOS/SlateLayoutApp'
        subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister', '-f', str(destination)], check=True)

    def cleanup(self):
        self.stop()
        if (self.root / 'state/browser-profile.json').exists():
            environment = dict(self.env)
            environment.pop('SLATE_TERM_SOCKET', None)
            result = subprocess.run([str(self.executable), '--remove-test-browser-profile'], env=environment,
                                    capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, ('layout browser profile cleanup', result.stderr)

    def panes(self):
        return self.rpc('workspace.get')['panes']

    def pane(self, kind):
        return next(row['id'] for row in self.panes() if kind in row['type'])


def management_clients(app, shared_root, register=False):
    """Use the registered-page and service patterns from trusted_api_fixture."""
    if register:
        assets = shared_root / 'layout-control-panel'
        assets.mkdir()
        (assets / 'index.html').write_text('<!doctype html><title>Layout control</title><p>Owned management fixture</p>')
        worker = shared_root / 'layout-control-service.py'
        worker.write_text("""import json,os,pathlib,subprocess,time
keys=['SLATE_TERM_SOCKET','SLATE_TERM_INSTANCE_ID','SLATE_TERM_SERVICE_PLUGIN_ID','SLATE_TERM_SERVICE_ID','SLATE_TERM_SERVICE_GENERATION']
context={key:os.environ[key] for key in keys}
path=pathlib.Path(os.environ['TEST_ROOT'])/('service-'+context['SLATE_TERM_INSTANCE_ID']+'.json')
path.write_text(json.dumps(context)); path.chmod(0o600)
result=subprocess.run([os.environ['SLATE_TERM_CLI'],'rpc','service.ready','--params','{\"version\":1}','--json'],capture_output=True,text=True,timeout=15)
if result.returncode: raise RuntimeError(result.stderr)
while True: time.sleep(1)
""")
        manifest = dict(id='layout-control', title='Layout Control', scope='global',
                        source=dict(kind='directory', path=str(assets)),
                        service=dict(executable=sys.executable, arguments=[str(worker)],
                                     environment={'TEST_ROOT': str(shared_root)}, readyTimeoutSeconds=15))
        app.rpc('plugins.register', packagePath=package_fixture(manifest, shared_root))
    terminal = next(row['id'] for row in app.rpc('workspace.get')['panes'] if 'terminal' in row['type'])
    panel = app.rpc('command.run', id='split.right', pane=terminal)['paneId']
    app.rpc('command.run', id='pane.type', pane=panel, type='layout-control', force=True)
    eventually('management bridge ready', lambda: app.rpc('debug.pluginEval', pane=panel, script='typeof workspace') == 'object')
    service = app.rpc('plugins.service.start', id='layout-control')
    context_file = shared_root / ('service-' + app.rpc('api.describe')['appInstanceId'] + '.json')
    def ready():
        status = app.rpc('plugins.service.status', id='layout-control')
        if status['state'] == 'failed':
            raise AssertionError({'service': status, 'logs': app.rpc('plugins.service.logs', id='layout-control')})
        return status['state'] == 'ready' and context_file.exists()
    try:
        eventually('management service ready', ready, timeout=20)
    except BaseException:
        diagnostic = {'service': app.rpc('plugins.service.status', id='layout-control'),
                      'logs': app.rpc('plugins.service.logs', id='layout-control'),
                      'contextFileExists': context_file.exists()}
        (ROOT / 'artifacts/layout-apps-management-service.json').write_text(json.dumps(diagnostic, indent=2))
        raise
    context = json.loads(context_file.read_text())
    assert context['SLATE_TERM_SERVICE_GENERATION'] == service['generation']

    def finish(response, method, params, client, error):
        if error is not None:
            assert response.get('error', {}).get('code') == error, response
            result = response['error']
        else:
            assert 'error' not in response, response
            result = response['result']
        app.contract_capture.record(method, params, result, error=error is not None, client=client)
        return result

    def bridge(method, params=None, error=None):
        params = params or {}
        script = 'await workspace.call(' + json.dumps(method) + ',' + json.dumps(params) + ').then(result=>({result}),error=>({error:{code:error.code,message:error.message}}))'
        result = app.rpc('debug.pluginEval', pane=panel, script=script)
        return finish(result, method, params, 'bridge', error)

    def managed_service(method, params=None, error=None):
        params = params or {}
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(40)
            peer.connect(context['SLATE_TERM_SOCKET'])
            with peer.makefile('rb') as stream:
                peer.sendall(json.dumps(dict(jsonrpc='2.0', id=1, method='hello', params={'protocolVersion': 1})).encode() + b'\n')
                hello = json.loads(stream.readline(2**20))['result']['service']
                assert hello == dict(appInstanceId=context['SLATE_TERM_INSTANCE_ID'], pluginId='layout-control',
                                     serviceId=context['SLATE_TERM_SERVICE_ID'], generation=context['SLATE_TERM_SERVICE_GENERATION'])
                peer.sendall(json.dumps(dict(jsonrpc='2.0', id=2, method=method, params=params)).encode() + b'\n')
                result = json.loads(stream.readline(2**20))
        return finish(result, method, params, 'service', error)

    def close():
        app.rpc('plugins.service.stop', id='layout-control')
        app.rpc('command.run', id='pane.close', pane=panel, force=True)

    return {'bridge': bridge, 'service': managed_service}, close


def patch_data(app, value):
    current = app.rpc('plugins.data.get', id='layout-fixture')
    app.rpc('plugins.data.patch', id='layout-fixture', expectedDataRevision=current['revision'],
            operations=[{'op': 'set', 'key': 'owner', 'value': value}])



def assert_creation_report(parent, created, *, copied):
    signed = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', created['path']],
                            capture_output=True, check=True, timeout=20)
    entitlements = plistlib.loads(signed.stdout)
    assert entitlements.get('com.apple.security.automation.apple-events') is True, entitlements
    assert set(created['syncedPluginIDs']) == {'layout-fixture', 'layout-control'}, created
    assert created['unavailablePlugins'] == [], created
    assert created['copiedPluginDataIDs'] == (['layout-fixture'] if copied else []), created
    assert created['launchServicesRegistered'] and created['launchServicesStatus'] == 0, created
    root = parent.root / 'LayoutApps' / created['layoutAppID'].lower()
    registry = json.loads((root / 'plugins/registry.json').read_text())
    source = json.loads((parent.root / 'plugins/registry.json').read_text())
    source_records = {row['id']: row for row in source['plugins']}
    assert set(row['id'] for row in registry['plugins']) == set(created['syncedPluginIDs'])
    for row in registry['plugins']:
        assert row['installationID'] != source_records[row['id']]['installationID']
        assert row['archiveSHA256'] == source_records[row['id']]['archiveSHA256']
        package = root / 'plugins/packages' / row['id'] / row['installationID'].lower() / 'package.zip'
        assert hashlib.sha256(package.read_bytes()).hexdigest() == row['archiveSHA256']
    data = root / 'state/plugin-data-v2/layout-fixture.json'
    if copied:
        assert json.loads(data.read_text()) == json.loads((parent.root / 'state/plugin-data-v2/layout-fixture.json').read_text())
    else:
        assert not data.exists()



def assert_creation_cancellation(parent, installed, definition):
    """Pause prepared work so stale recipes and disconnects cannot publish."""
    recipe = json.loads(json.dumps(definition))
    recipe['id'] = str(uuid.uuid4())
    recipe['name'] = 'Creation cancellation fixture'
    parent.rpc('layouts.create', definition=recipe)
    baseline = parent.rpc('layoutApps.list')
    evidence = []
    for reason in ['recipe-change', 'disconnect']:
        destination = installed.root / ('Cancelled-' + reason + '.app')
        competing = installed.root / ('Competing-' + reason + '.app')
        cursor = parent.rpc('events.head')['cursor']
        peer = socket.socket(socket.AF_UNIX)
        peer.settimeout(40)
        stream = None
        try:
            assert parent.rpc('debug.layoutAppPreparation', action='arm')['phase'] == 'armed'
            peer.connect(parent.path)
            stream = peer.makefile('rb')
            peer.sendall(json.dumps(dict(jsonrpc='2.0', id=1, method='hello',
                params={'protocolVersion': 1})).encode() + b'\n')
            hello = json.loads(stream.readline(2**20))
            assert 'error' not in hello, hello
            peer.sendall(json.dumps(dict(jsonrpc='2.0', id=2, method='layouts.launcher',
                params={'id': recipe['id'], 'path': str(destination), 'copyPluginData': True})).encode() + b'\n')
            paused = {}
            def prepared():
                paused.update(parent.rpc('debug.layoutAppPreparation', action='status'))
                return paused['phase'] == 'paused'
            eventually('creation prepared before publication', prepared, timeout=60)
            stage, base = Path(paused['stage']), Path(paused['base'])
            assert stage.parent.resolve() == installed.root.resolve(), paused
            assert stage.name.startswith('.slate-layout-') and stage.suffix == '.app', paused
            assert base.parent.resolve() == (parent.root / 'LayoutApps').resolve(), paused
            assert stage.is_dir() and base.is_dir(), paused
            assert Path(paused['destination']) == destination and not destination.exists(), paused
            # A separate connection must progress while the first request is suspended.
            assert parent.rpc('workspace.snapshot')
            parent.rpc('layouts.launcher', id=recipe['id'], path=str(competing), error=-32050)
            assert not competing.exists()
            assert parent.rpc('layoutApps.list') == baseline
            if reason == 'recipe-change':
                current = parent.rpc('layouts.get', id=recipe['id'])
                recipe['name'] = 'Changed during creation'
                parent.rpc('layouts.update', definition=recipe, expectedSavedLayoutRevision=current['revision'])
            else:
                # Server EOF proves it handled disconnect and cancelled the pending task.
                peer.shutdown(socket.SHUT_WR)
                assert stream.readline(2**20) == b'', 'Disconnected creation returned a response before release'
            assert parent.rpc('debug.layoutAppPreparation', action='release')['phase'] == 'idle'
            if reason == 'recipe-change':
                response = json.loads(stream.readline(2**20))
                assert response.get('error', {}).get('code') == -32050, response
            eventually('cancelled creation removes owned preparation',
                       lambda: not stage.exists() and not base.exists(), timeout=30)
            assert not destination.exists() and not competing.exists()
            assert parent.rpc('layoutApps.list') == baseline
            events = parent.rpc('events.poll', after=cursor, topics=['host.layoutapp.created'],
                                recipient='all', scope='global', waitMilliseconds=0)['events']
            assert events == [], events
            evidence.append({'reason': reason, 'preparation': paused, 'cleanup': True,
                             'published': False, 'secondClientResponsive': True, 'concurrentMutationRefused': True})
        finally:
            try:
                parent.rpc('debug.layoutAppPreparation', action='release')
            finally:
                if stream is not None:
                    stream.close()
                peer.close()
    (ROOT / 'artifacts/layout-app-creation-cancellation.json').write_text(json.dumps(evidence, indent=2) + '\n')


def main():
    require_vm()
    with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Page) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with AppFixture('layout-apps', startup_timeout=30) as parent, InstalledApps() as installed:
                parent.capture_contracts()
                assert parent.rpc('api.describe')['mode'] == 'standard'
                assert parent.rpc('api.describe')['layoutAppID'] is None
                marker = parent.root / 'startup-runs'
                layout_id = str(uuid.uuid4())
                definition = {'version': 1, 'id': layout_id, 'name': 'Owned Layout App', 'tabs': [{
                    'name': 'Tab 1', 'layout': {'kind': 'split', 'axis': 'horizontal', 'fraction': 0.5,
                        'first': {'kind': 'pane', 'pane': 'p1'}, 'second': {'kind': 'pane', 'pane': 'p2'}},
                    'panes': [{'id': 'p1', 'type': 'terminal', 'configuration': {'directory': str(parent.root),
                        'command': 'printf "%s\\n" "$SLATE_TERM_INSTANCE_ID" >> ' + shlex.quote(str(marker))}},
                        {'id': 'p2', 'type': 'browser', 'configuration': {'url': f'http://127.0.0.1:{server.server_port}/'}}]}]}
                parent.rpc('layouts.create', definition=definition)
                package = package_fixture({'id': 'layout-fixture', 'title': 'Layout Fixture',
                    'commands': [{'id': 'noop', 'title': 'No-op', 'executable': '/usr/bin/true'}]}, parent.root)
                parent.rpc('plugins.register', packagePath=str(package))
                patch_data(parent, 'parent')
                clients, close_parent_clients = management_clients(parent, parent.root, register=True)
                assert_creation_cancellation(parent, installed, definition)
                expected_description = parent.rpc('api.describe')
                assert not expected_description['runtimeAvailability']['config.resetOverrides']
                assert expected_description['runtimeAvailability']['updates.download']
                for name, call in clients.items():
                    assert call('api.describe') == expected_description, name
                    call('layoutApps.list', {'ignored': True}, error=-32602)
                    call('layoutApps.list', {'expectedBundleRevision': 'unsupported'}, error=-32602)
                    call('layoutApps.list', {'expectedInstanceId': str(uuid.uuid4())}, error=-32050)
                    cursor = parent.rpc('events.head')['cursor']
                    created = call('layouts.launcher', {'id': layout_id, 'path': str(installed.root / (name + '.app')), 'copyPluginData': False})
                    assert_creation_report(parent, created, copied=False)
                    events = parent.rpc('events.poll', after=cursor, topics=['host.layoutapp.created'], recipient='all', scope='global', waitMilliseconds=0)['events']
                    assert len(events) == 1 and events[0]['source'] == {'kind': 'host'}, events
                    payload = events[0]['payload']
                    assert set(payload) == {'layoutAppID', 'runtimeBuild', 'runtimeVersion', 'revision', 'operationId', 'origin', 'causalDepth'}, payload
                    assert payload['layoutAppID'] == created['layoutAppID']
                    assert payload['origin']['kind'] == {'bridge': 'plugin', 'service': 'service'}[name], payload
                    assert payload['origin']['pluginId'] == 'layout-control' and payload['causalDepth'] == 0
                    record = next(row for row in call('layoutApps.list') if row['layoutAppID'] == created['layoutAppID'])
                    assert set(record) == {'layoutAppID', 'layoutID', 'name', 'path', 'runtimeVersion', 'runtimeBuild', 'revision', 'running', 'available', 'updateReady', 'shellCodeHash'}
                    call('layoutApps.refresh', {'layoutAppID': created['layoutAppID'], 'expectedBundleRevision': record['revision'], 'ignored': True}, error=-32602)
                    call('layoutApps.refresh', {'layoutAppID': created['layoutAppID'], 'expectedBundleRevision': 'stale'}, error=-32050)
                    cursor = parent.rpc('events.head')['cursor']
                    refreshed = call('layoutApps.refresh', {'layoutAppID': created['layoutAppID'], 'expectedBundleRevision': record['revision']})
                    assert refreshed['layoutAppID'] == created['layoutAppID'] and refreshed['available'] and not refreshed['running']
                    assert parent.rpc('events.poll', after=cursor, topics=['host.layoutapp.refreshed'], recipient='all', scope='global', waitMilliseconds=0)['events'] == []
                first = parent.cli('layouts', 'launcher', '--id', layout_id, '--path', str(installed.root / 'First.app'), '--name', 'First')
                second = parent.rpc('layouts.launcher', id=layout_id, path=str(installed.root / 'Second.app'), name='Second', copyPluginData=False)
                assert_creation_report(parent, first, copied=True)
                assert_creation_report(parent, second, copied=False)
                assert first['layoutAppID'] != second['layoutAppID']
                assert first['id'].lower() == second['id'].lower() == layout_id.lower()
                apps = [LayoutApp(parent, first, 1), LayoutApp(parent, second, 2)]
                try:
                    for app in apps:
                        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app.bundle)], check=True, capture_output=True)
                        app.start()
                        assert len(app.panes()) == 2
                        description = app.rpc('api.describe')
                        availability = description['runtimeAvailability']
                        assert availability['config.resetOverrides'] and availability['plugins.validate']
                        assert not availability['updates.download'] and not availability['updates.cancel']
                        eventually('local update status settled', lambda: app.rpc('updates.get')['phase'] == 'current')
                        update_before = app.rpc('updates.get')
                        update_cursor = app.rpc('events.head')['cursor']
                        app.rpc('updates.cancel', updateId=update_before['updateId'], error=-32051)
                        assert app.rpc('updates.get') == update_before
                        assert not app.rpc('events.poll', after=update_cursor, topics=['host.updates.changed'],
                                           scope='global', waitMilliseconds=0)['events']
                        assert description['savedLayouts']['libraryScope'] == 'currentApplication'
                        assert description['savedLayouts']['layoutAppLibrary'] == 'private'
                        assert description['savedLayouts']['layoutAppFreshOpeningSource'] == 'parentSourceRecipe'
                        assert app.rpc('layouts.list') == []
                        app.rpc('workspace.snapshot', expectedShellCodeHash='unsupported', error=-32602)
                        for method in ['layouts.launcher', 'layoutApps.list', 'layoutApps.refresh', 'plugins.register', 'plugins.unregister', 'plugins.enable', 'plugins.disable', 'skills.install', 'skills.uninstall', 'palette.import']:
                            assert not availability[method], method
                        assert len(app.rpc('window.list')['windows']) == 1
                        pane = app.pane('terminal')
                        eventually('layout terminal ready', lambda: app.rpc('context.get', pane=pane, scope='pane')['terminal']['isAtPrompt'], timeout=40)
                        eventually('configured startup finished', lambda: any(row['state'] == 'finished' for row in app.rpc('layouts.startupStatus')), timeout=40)
                        exported = parent.root / f'context-{app.number}.json'
                        app.rpc('terminal.run', pane=pane,
                            command='"$SLATE_TERM_CLI" rpc context.get --params \'{"scope":"global"}\' --json > ' + shlex.quote(str(exported)))
                        eventually('own embedded CLI context', lambda: exported.exists() and exported.stat().st_size > 0)
                        assert json.loads(exported.read_text())['layoutAppID'] == app.record['layoutAppID']
                        app.rpc('context.get', error=-32050, expectedInstanceId=parent.rpc('api.describe')['appInstanceId'])
                        for method, params in [('layoutApps.list', {}), ('layoutApps.refresh', {
                            'layoutAppID': app.record['layoutAppID'], 'expectedBundleRevision': 'revision'}),
                            ('layouts.launcher', {'id': layout_id, 'path': str(parent.root / 'Forbidden.app')})]:
                            failure = app.rpc(method, error=-32060, **params)
                            assert failure['message'] == 'Manage layout apps from Slate Terminal', failure
                    # Ordinary library writes belong to this app, not its parent source recipe.
                    parent_layouts = parent.rpc('layouts.list')
                    local_definition = {'version': 1, 'id': str(uuid.uuid4()), 'name': 'Private child recipe', 'tabs': [{
                        'name': 'Private tab', 'layout': {'kind': 'pane', 'pane': 'p1'},
                        'panes': [{'id': 'p1', 'type': 'terminal'}]}]}
                    local_entry = apps[0].rpc('layouts.create', definition=local_definition)
                    local_id = local_entry['definition']['id']
                    assert [row['id'] for row in apps[0].rpc('layouts.list')] == [local_id]
                    assert apps[0].rpc('layouts.get', id=local_id) == local_entry
                    assert apps[1].rpc('layouts.list') == []
                    assert parent.rpc('layouts.list') == parent_layouts
                    assert apps[0].pid != apps[1].pid
                    assert len({parent.path, apps[0].path, apps[1].path}) == 3
                    eventually('one recipe startup per created app', lambda: marker.exists() and len(marker.read_text().splitlines()) == 2, timeout=40)
                    assert apps[0].rpc('plugins.data.get', id='layout-fixture')['values'] == {'owner': 'parent'}
                    assert apps[1].rpc('plugins.data.get', id='layout-fixture')['values'] == {}
                    patch_data(apps[0], 'first')
                    patch_data(apps[1], 'second')
                    assert parent.rpc('plugins.data.get', id='layout-fixture')['values'] == {'owner': 'parent'}
                    parent_revision = parent.rpc('config.get')['sourceRevision']
                    parent.rpc('config.patch', values={'terminal.font_size': 19}, expectedSourceRevision=parent_revision)
                    eventually('parent settings inherited in both apps', lambda: all(app.rpc('config.get')['current']['terminal']['font_size'] == 19 for app in apps))
                    parent_source = parent.config.read_bytes()
                    local = apps[0].rpc('config.get')
                    apps[0].rpc('config.patch', values={'terminal.font_size': 23}, expectedSourceRevision=local['sourceRevision'])
                    assert parent.config.read_bytes() == parent_source
                    assert apps[1].rpc('config.get')['current']['terminal']['font_size'] == 19
                    parent.rpc('config.patch', values={'terminal.font_size': 21}, expectedSourceRevision=parent.rpc('config.get')['sourceRevision'])
                    eventually('local override wins over new parent settings', lambda: apps[0].rpc('config.get')['current']['terminal']['font_size'] == 23 and apps[1].rpc('config.get')['current']['terminal']['font_size'] == 21)
                    apps[0].rpc('config.resetOverrides', error=-32050, keys=['terminal.font_size'], expectedSourceRevision=local['sourceRevision'])
                    apps[0].cli('config', 'reset-overrides', '--key', 'terminal.font_size', '--expected-source-revision', apps[0].rpc('config.get')['sourceRevision'])
                    assert apps[0].rpc('config.get')['current']['terminal']['font_size'] == 21
                    assert 'terminal.font_size' not in apps[0].rpc('config.get')['overriddenKeys']
                    for app in apps:
                        browser = app.pane('browser')
                        app.rpc('browser.eval', pane=browser, script=f'localStorage.setItem("owner", "app-{app.number}"); true')
                    for app in apps:
                        assert app.rpc('browser.eval', pane=app.pane('browser'), script='localStorage.getItem("owner")') == f'app-{app.number}'
                    before = [pane['id'] for pane in apps[0].panes()]
                    apps[0].start()
                    assert [pane['id'] for pane in apps[0].panes()] == before
                    assert len(apps[0].rpc('window.list')['windows']) == 1
                    assert len(marker.read_text().splitlines()) == 2
                    records = parent.cli('layout-apps', 'list')
                    selected = next(row for row in records if row['layoutAppID'] == first['layoutAppID'])
                    assert selected['running'] and selected['available']
                    parent.rpc('layoutApps.refresh', error=-32051, layoutAppID=selected['layoutAppID'], expectedBundleRevision=selected['revision'])
                    # A same-build refresh proves refusal/identity behavior, not a version migration.
                    apps[0].stop()
                    assert apps[1].rpc('api.describe')['layoutAppID'] == second['layoutAppID']
                    assert parent.process.poll() is None
                    selected = next(row for row in parent.rpc('layoutApps.list') if row['layoutAppID'] == first['layoutAppID'])
                    assert not selected['running']
                    parent.rpc('layoutApps.refresh', error=-32050, layoutAppID=selected['layoutAppID'], expectedBundleRevision='stale')
                    executable_hash = hashlib.sha256(apps[0].executable.read_bytes()).hexdigest()
                    requirement = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(apps[0].bundle)], capture_output=True, text=True, check=True).stdout
                    assert 'designated =>' in requirement, requirement
                    refreshed = parent.cli('layout-apps', 'refresh', '--layout-app-id', selected['layoutAppID'], '--expected-bundle-revision', selected['revision'])
                    assert refreshed['layoutAppID'] == selected['layoutAppID']
                    assert hashlib.sha256(apps[0].executable.read_bytes()).hexdigest() == executable_hash
                    assert subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(apps[0].bundle)], capture_output=True, text=True, check=True).stdout == requirement
                    apps[0].start()
                    assert apps[0].rpc('plugins.data.get', id='layout-fixture')['values'] == {'owner': 'first'}
                    assert len(apps[0].panes()) == 2
                    def restored_browser_ready():
                        status = apps[0].rpc('browser.get', pane=apps[0].pane('browser'))
                        return not status['loading'] and status['title'] == 'Layout App Fixture'
                    eventually('restored browser document ready', restored_browser_ready)
                    assert apps[0].rpc('browser.eval', pane=apps[0].pane('browser'), script='localStorage.getItem("owner")') == 'app-1'
                    assert apps[0].rpc('layouts.startupStatus') == [], 'Restoration scheduled a recipe startup command'
                    assert len(marker.read_text().splitlines()) == 2, 'Restoration replayed a recipe startup command'
                    current = parent.rpc('layouts.get', id=layout_id)
                    definition['tabs'][0]['panes'][0]['title'] = 'Fresh recipe'
                    parent.rpc('layouts.update', definition=definition, expectedSavedLayoutRevision=current['revision'])
                    for tab in apps[0].rpc('workspace.get')['tabs']:
                        apps[0].rpc('command.run', id='tab.close', tab=tab['id'], force=True)
                    assert apps[0].rpc('window.list')['windows'] == []
                    apps[0].start()
                    assert len(apps[0].panes()) == 2 and len(apps[0].rpc('window.list')['windows']) == 1
                    eventually('empty-window reopen executes latest recipe once', lambda: len(marker.read_text().splitlines()) == 3, timeout=40)
                    assert next(row for row in apps[0].panes() if 'terminal' in row['type'])['manualTitle'] == 'Fresh recipe'
                    for app in apps:
                        child_clients, close_child_clients = management_clients(app, parent.root)
                        try:
                            for name, call in child_clients.items():
                                description = call('api.describe')
                                assert description['mode'] == 'layoutApp' and description['layoutAppID'] == app.record['layoutAppID']
                                for method, params in [('layoutApps.list', {}), ('layoutApps.refresh', {'layoutAppID': app.record['layoutAppID'], 'expectedBundleRevision': 'revision'}),
                                    ('layouts.launcher', {'id': layout_id, 'path': str(parent.root / ('forbidden-' + name + '.app'))})]:
                                    assert call(method, params, error=-32060)['message'] == 'Manage layout apps from Slate Terminal'
                        finally:
                            close_child_clients()
                    apps[0].stop()
                    original_path = apps[0].bundle
                    moved_path = original_path.with_name('Moved First.app')
                    apps[0].move(moved_path)
                    parent.rpc('layouts.launcher', id=layout_id, path=str(original_path), name='Replacement')
                    def moved_available():
                        moved = next(row for row in parent.rpc('layoutApps.list') if row['layoutAppID'] == first['layoutAppID'])
                        return moved['available'] and Path(moved['path']).resolve() == moved_path.resolve()
                    try:
                        eventually('moved app discovered after old path reuse', moved_available, timeout=20)
                    except Exception:
                        parent.preserve_for_children = True
                        (ROOT / 'artifacts/layout-apps-moved-diagnostic.json').write_text(json.dumps({
                            'root': str(parent.root), 'movedPath': str(moved_path), 'originalPath': str(original_path),
                            'bundleID': apps[0].bundle_id, 'records': parent.rpc('layoutApps.list')}, indent=2))
                        raise
                    close_parent_clients()
                    print('PASS registered-page and managed-service creation/list/refresh, shared discovery and child-runtime denials', flush=True)
                    print('PASS independent layout-app processes, sockets, CLI routing, data/browser isolation, warm reuse, restoration and guarded same-build refresh', flush=True)
                finally:
                    failures = []
                    for app in apps:
                        try:
                            app.cleanup()
                        except BaseException as error:
                            failures.append(str(error))
                    if failures:
                        parent.preserve_for_children = True
                        (ROOT / 'artifacts/layout-apps-cleanup.json').write_text(json.dumps({'root': str(parent.root), 'errors': failures,
                            'apps': [{'path': str(app.bundle), 'pid': app.pid, 'layoutAppID': app.record['layoutAppID']} for app in apps]}, indent=2))
                        raise AssertionError('Owned layout-app cleanup failed: ' + '; '.join(failures))
        finally:
            server.shutdown()


if __name__ == '__main__':
    main()
